import Foundation

// Display-independent projections of the monitor graph and native process snapshot.
// Everything here is a pure value computation so it can run off the main actor and be
// tested without AppKit, XPC, or Endpoint Security.

enum AgentRunState: String, Hashable, Sendable {
    case running, exited, unknown
}

/// One relationship between a process and an Agent session. A process can carry several.
struct ServiceAttribution: Hashable, Sendable {
    /// `nil` for a relationship inferred only from the current native snapshot.
    var sessionID: String?
    var agentID: String
    var agentName: String
    var sessionEnded: Bool
    var evidence: EvidenceKind
    var project: ProjectRecord?
}

struct AgentRow: Hashable, Sendable, Identifiable {
    var id: String
    /// Persisted history session; `nil` when the Agent is known only from a native snapshot.
    var sessionID: String?
    var agentID: String
    var agentName: String
    var project: ProjectRecord?
    var state: AgentRunState
    var startedAt: Date
    var endedAt: Date?
    var endReason: String?
    var root: ExecutionIdentity
    var command: String
    var descendantCount: Int
    var runningDescendantCount: Int
    var endpointCount: Int
    var evidence: EvidenceKind
}

struct PortRow: Hashable, Sendable, Identifiable {
    var id: String
    var endpoint: ListeningEndpoint
    var execution: ExecutionRecord?
    /// A live Endpoint Security identity the extension may issue a fresh token for.
    var controlTarget: ExecutionIdentity?
    var project: ProjectRecord?
    var runtime: RuntimeKind
    var attributions: [ServiceAttribution]
    var observedNatively: Bool
}

struct LeftoverRow: Hashable, Sendable, Identifiable {
    var id: String
    var execution: ExecutionRecord
    var controlTarget: ExecutionIdentity?
    var attributions: [ServiceAttribution]
    var endpoints: [ListeningEndpoint]
    var project: ProjectRecord?
    var agentEndedAt: Date?
    /// Associated with more than one Agent session.
    var isShared: Bool
    /// At least one relationship is inferred, snapshot-derived, or responsible-process evidence.
    var isUncertain: Bool
}

struct LaunchChainNode: Hashable, Sendable {
    var identity: ExecutionIdentity
    var execution: ExecutionRecord?
    /// How this node was linked to the previous (older) node; `nil` for the oldest node.
    var link: EdgeKind?
    var linkEvidence: EvidenceKind?
    var agentName: String?
}

struct ProjectionInput: Sendable {
    var graph = GraphSnapshot()
    var monitorEndpoints: [ListeningEndpoint] = []
    var liveExecutions: [ExecutionRecord] = []
    var native: NativeProcessSnapshot?
    var definitions: [AgentDefinition] = AgentDefinition.defaults
    var historyAvailable = false
}

/// Lookup tables shared by row projection and inspector queries.
struct GraphIndex: Sendable {
    var executions: [ExecutionIdentity: ExecutionRecord] = [:]
    var graphLatestByProcess: [ProcessIdentity: ExecutionRecord] = [:]
    var liveByProcess: [ProcessIdentity: ExecutionRecord] = [:]
    var liveIdentities: Set<ExecutionIdentity> = []
    var nativeByProcess: [ProcessIdentity: ExecutionRecord] = [:]
    var nativeChildren: [ProcessIdentity: [ProcessIdentity]] = [:]
    var parentEdges: [ExecutionIdentity: [ExecutionEdge]] = [:]
    var sessions: [String: AgentSession] = [:]
    var sessionsByProcess: [ProcessIdentity: [String: EvidenceKind]] = [:]
    var processesBySession: [String: Set<ProcessIdentity>] = [:]
    var snapshotAgents: [ProcessIdentity: AgentDefinition] = [:]
    var hasFreshObservation = false

    init() {}

    init(_ input: ProjectionInput) {
        for record in input.graph.executions {
            executions[record.identity] = record
            Self.keepLatest(record, in: &graphLatestByProcess)
        }
        for record in input.liveExecutions {
            liveIdentities.insert(record.identity)
            Self.keepLatest(record, in: &liveByProcess)
            if executions[record.identity] == nil { executions[record.identity] = record }
        }
        if let native = input.native {
            for record in native.executions {
                nativeByProcess[record.identity.process] = record
                if let parent = record.parent?.process {
                    nativeChildren[parent, default: []].append(record.identity.process)
                }
            }
        }
        hasFreshObservation = input.native != nil || input.historyAvailable
        for edge in input.graph.edges {
            parentEdges[edge.child, default: []].append(edge)
        }
        for session in input.graph.sessions {
            sessions[session.id] = session
        }
        for association in input.graph.associations where sessions[association.sessionID] != nil {
            let process = association.execution.process
            var entries = sessionsByProcess[process] ?? [:]
            entries[association.sessionID] = Self.strongest(entries[association.sessionID], association.evidence)
            sessionsByProcess[process] = entries
            processesBySession[association.sessionID, default: []].insert(process)
        }
        for session in input.graph.sessions {
            processesBySession[session.id, default: []].insert(session.root.process)
        }
        if let native = input.native {
            let rootProcesses = Set(input.graph.sessions.filter { $0.endedAt == nil }.map(\.root.process))
            for record in native.executions where !rootProcesses.contains(record.identity.process) {
                if let agent = AgentRecognizer.recognize(record, definitions: input.definitions) {
                    snapshotAgents[record.identity.process] = agent
                }
            }
        }
    }

    // MARK: Liveness

    /// Running only when a current observation supports it; persisted state alone is not proof.
    func isAlive(_ process: ProcessIdentity) -> Bool {
        liveByProcess[process] != nil || nativeByProcess[process] != nil
    }

    func runState(of record: ExecutionRecord) -> AgentRunState {
        if record.state == .exited { return .exited }
        guard isLatestImage(record.identity) else { return .exited }
        return isAlive(record.identity.process) ? .running : .unknown
    }

    /// False when a later exec image of the same process is known.
    func isLatestImage(_ identity: ExecutionIdentity) -> Bool {
        guard identity.version != 0 else { return true }
        let latest = [graphLatestByProcess[identity.process], liveByProcess[identity.process]]
            .compactMap { $0?.identity.version }
            .max() ?? identity.version
        return identity.version >= latest
    }

    // MARK: Lookup

    func record(for identity: ExecutionIdentity) -> ExecutionRecord? {
        if let record = executions[identity] { return record }
        if identity.version == 0 { return nativeByProcess[identity.process] }
        return nil
    }

    /// Best current metadata for a process: live ES identity, native observation, then history.
    func currentRecord(for process: ProcessIdentity) -> ExecutionRecord? {
        liveByProcess[process] ?? nativeByProcess[process] ?? graphLatestByProcess[process]
    }

    /// The live ES execution identity for a process. Native version-0 records never qualify.
    func controlTarget(for process: ProcessIdentity) -> ExecutionIdentity? {
        guard let live = liveByProcess[process], live.identity.version != 0 else { return nil }
        return live.identity
    }

    /// History identity used to query activity for a process (ES identities only).
    func historyIdentity(for process: ProcessIdentity) -> ExecutionIdentity? {
        if let live = liveByProcess[process], live.identity.version != 0 { return live.identity }
        if let graph = graphLatestByProcess[process] { return graph.identity }
        return nil
    }

    func attributions(for process: ProcessIdentity) -> [ServiceAttribution] {
        var result: [ServiceAttribution] = []
        for (sessionID, evidence) in sessionsByProcess[process] ?? [:] {
            guard let session = sessions[sessionID] else { continue }
            result.append(ServiceAttribution(
                sessionID: sessionID,
                agentID: session.agent.id,
                agentName: session.agent.name,
                sessionEnded: session.endedAt != nil,
                evidence: evidence,
                project: session.project
            ))
        }
        if result.isEmpty, let agent = snapshotAncestorAgent(for: process) {
            result.append(ServiceAttribution(
                sessionID: nil,
                agentID: agent.agentID,
                agentName: agent.agentName,
                sessionEnded: false,
                evidence: .snapshot,
                project: nil
            ))
        }
        return result.sorted {
            if $0.agentName != $1.agentName { return $0.agentName < $1.agentName }
            return ($0.sessionID ?? "") < ($1.sessionID ?? "")
        }
    }

    /// A recognized Agent found by walking current native parent links (inferred, not recorded).
    func snapshotAncestorAgent(for process: ProcessIdentity) -> (agentID: String, agentName: String, root: ProcessIdentity)? {
        var current: ProcessIdentity? = process
        var visited: Set<ProcessIdentity> = []
        while let candidate = current, visited.insert(candidate).inserted, visited.count <= 64 {
            if let agent = snapshotAgents[candidate] {
                return (agent.id, agent.name, candidate)
            }
            current = nativeByProcess[candidate]?.parent?.process
        }
        return nil
    }

    // MARK: Launch chain

    /// Oldest-first chain of recorded fork/exec edges ending at `identity`. Where no recorded
    /// edge exists, the execution's own parent field is used and labeled with its evidence.
    /// Responsible-process edges are supplementary and never treated as direct launches.
    func launchChain(for identity: ExecutionIdentity, limit: Int = 64) -> [LaunchChainNode] {
        var nodes: [LaunchChainNode] = []
        var visited: Set<ExecutionIdentity> = []
        var current: ExecutionIdentity? = identity
        var pendingLink: (EdgeKind, EvidenceKind)?

        while let node = current, visited.insert(node).inserted, nodes.count < limit {
            let record = record(for: node)
            nodes.append(LaunchChainNode(
                identity: node,
                execution: record,
                link: nil,
                linkEvidence: nil,
                agentName: agentName(rootedAt: node)
            ))
            if let link = pendingLink, nodes.count >= 2 {
                nodes[nodes.count - 2].link = link.0
                nodes[nodes.count - 2].linkEvidence = link.1
            }
            pendingLink = nil

            let edges = (parentEdges[node] ?? []).filter { $0.kind != .responsible && $0.parent != node }
            if let edge = edges.min(by: { Self.rank($0.evidence) < Self.rank($1.evidence) }) {
                current = edge.parent
                pendingLink = (edge.kind, edge.evidence)
            } else if let parent = record?.parent, parent != node {
                current = parent
                let evidence: EvidenceKind = record?.evidence == .snapshot ? .snapshot : .inferred
                pendingLink = (parent.process == node.process ? .exec : .fork, evidence)
            } else {
                current = nil
            }
        }
        return nodes.reversed()
    }

    func agentName(rootedAt identity: ExecutionIdentity) -> String? {
        if let session = sessions.values.first(where: { $0.root == identity }) {
            return session.agent.name
        }
        if identity.version == 0, let agent = snapshotAgents[identity.process] {
            return agent.name
        }
        return nil
    }

    // MARK: Helpers

    private static func keepLatest(_ record: ExecutionRecord, in table: inout [ProcessIdentity: ExecutionRecord]) {
        let process = record.identity.process
        if let existing = table[process], existing.identity.version >= record.identity.version { return }
        table[process] = record
    }

    static func rank(_ evidence: EvidenceKind) -> Int {
        switch evidence {
        case .observed: return 0
        case .inferred: return 1
        case .snapshot: return 2
        case .responsible: return 3
        }
    }

    static func strongest(_ lhs: EvidenceKind?, _ rhs: EvidenceKind) -> EvidenceKind {
        guard let lhs else { return rhs }
        return rank(lhs) <= rank(rhs) ? lhs : rhs
    }
}

struct ActivityProjection: Sendable {
    var agents: [AgentRow] = []
    var ports: [PortRow] = []
    var leftovers: [LeftoverRow] = []
    var index = GraphIndex()

    static let empty = ActivityProjection()

    /// `resolveProject` may touch the filesystem; call `make` off the main actor.
    static func make(
        _ input: ProjectionInput,
        resolveProject: (String?) -> ProjectRecord? = ProjectResolver.resolve
    ) -> ActivityProjection {
        let index = GraphIndex(input)
        var projectCache: [String: ProjectRecord?] = [:]
        /// Agents get their launch directory as a project; other services only a Git project.
        func project(forDirectory directory: String?, requireGit: Bool = false) -> ProjectRecord? {
            guard let directory else { return nil }
            let resolved: ProjectRecord?
            if let cached = projectCache[directory] {
                resolved = cached
            } else {
                resolved = resolveProject(directory)
                projectCache[directory] = resolved
            }
            guard let resolved, isMeaningfulProject(resolved) else { return nil }
            if requireGit, resolved.gitDirectory == nil { return nil }
            return resolved
        }

        let endpoints = currentEndpoints(input)
        var endpointsByProcess: [ProcessIdentity: [ListeningEndpoint]] = [:]
        for endpoint in endpoints {
            endpointsByProcess[endpoint.execution.process, default: []].append(endpoint)
        }

        // Agents recorded in history.
        var agents: [AgentRow] = []
        for session in input.graph.sessions {
            let processes = index.processesBySession[session.id] ?? [session.root.process]
            let descendants = processes.subtracting([session.root.process])
            let rootRecord = index.record(for: session.root)
            let state: AgentRunState
            if session.endedAt != nil {
                state = .exited
            } else if let rootRecord {
                state = index.runState(of: rootRecord) == .running ? .running : .unknown
            } else {
                state = index.isAlive(session.root.process) ? .running : .unknown
            }
            agents.append(AgentRow(
                id: session.id,
                sessionID: session.id,
                agentID: session.agent.id,
                agentName: session.agent.name,
                project: session.project,
                state: state,
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                endReason: session.endReason,
                root: session.root,
                command: rootRecord?.command ?? "",
                descendantCount: descendants.count,
                runningDescendantCount: descendants.filter(index.isAlive).count,
                endpointCount: processes.reduce(0) { $0 + (endpointsByProcess[$1]?.count ?? 0) },
                evidence: session.evidence
            ))
        }

        // Agents seen only in the current native snapshot (no recorded history).
        for (process, agent) in index.snapshotAgents {
            guard let record = index.nativeByProcess[process] else { continue }
            var descendants: Set<ProcessIdentity> = []
            var queue = index.nativeChildren[process] ?? []
            while let next = queue.popLast() {
                guard descendants.insert(next).inserted else { continue }
                queue.append(contentsOf: index.nativeChildren[next] ?? [])
            }
            let all = descendants.union([process])
            agents.append(AgentRow(
                id: "snapshot:" + process.stableID,
                sessionID: nil,
                agentID: agent.id,
                agentName: agent.name,
                project: project(forDirectory: record.workingDirectory),
                state: .running,
                startedAt: record.startedAt,
                endedAt: nil,
                endReason: nil,
                root: record.identity,
                command: record.command,
                descendantCount: descendants.count,
                runningDescendantCount: descendants.count,
                endpointCount: all.reduce(0) { $0 + (endpointsByProcess[$1]?.count ?? 0) },
                evidence: .snapshot
            ))
        }
        agents.sort {
            if ($0.state == .running) != ($1.state == .running) { return $0.state == .running }
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id < $1.id
        }

        // Ports and services.
        let nativeKeys = Set((input.native?.endpoints ?? []).map(endpointKey))
        var ports: [PortRow] = []
        for endpoint in endpoints {
            let process = endpoint.execution.process
            let record = index.currentRecord(for: process)
            let attributions = index.attributions(for: process)
            ports.append(PortRow(
                id: endpointKey(endpoint),
                endpoint: endpoint,
                execution: record,
                controlTarget: index.controlTarget(for: process),
                project: sharedProject(attributions) ?? project(forDirectory: record?.workingDirectory, requireGit: true),
                runtime: record.map { RuntimeDetector.runtime(forExecutable: $0.executable) } ?? .unknown,
                attributions: attributions,
                observedNatively: nativeKeys.contains(endpointKey(endpoint))
            ))
        }
        ports.sort {
            if $0.endpoint.port != $1.endpoint.port { return $0.endpoint.port < $1.endpoint.port }
            return $0.id < $1.id
        }

        // Leftovers: a confirmed Agent exit plus a related process that is still observed alive.
        var leftovers: [LeftoverRow] = []
        if input.historyAvailable {
            var seenProcesses: Set<ProcessIdentity> = []
            for (process, entries) in index.sessionsByProcess {
                let sessions = entries.keys.compactMap { index.sessions[$0] }
                guard !sessions.isEmpty,
                      sessions.allSatisfy({ $0.endedAt != nil }),
                      !sessions.contains(where: { $0.root.process == process }),
                      index.isAlive(process),
                      let record = index.liveByProcess[process] ?? index.graphLatestByProcess[process],
                      record.state != .exited,
                      seenProcesses.insert(process).inserted else { continue }
                let attributions = index.attributions(for: process)
                let current = index.currentRecord(for: process) ?? record
                leftovers.append(LeftoverRow(
                    id: process.stableID,
                    execution: current,
                    controlTarget: index.controlTarget(for: process),
                    attributions: attributions,
                    endpoints: endpointsByProcess[process] ?? [],
                    project: sharedProject(attributions) ?? project(forDirectory: current.workingDirectory, requireGit: true),
                    agentEndedAt: sessions.compactMap(\.endedAt).max(),
                    isShared: Set(sessions.map(\.id)).count > 1,
                    isUncertain: attributions.contains { $0.evidence != .observed }
                ))
            }
            leftovers.sort {
                if ($0.agentEndedAt ?? .distantPast) != ($1.agentEndedAt ?? .distantPast) {
                    return ($0.agentEndedAt ?? .distantPast) > ($1.agentEndedAt ?? .distantPast)
                }
                return $0.id < $1.id
            }
        }

        return ActivityProjection(agents: agents, ports: ports, leftovers: leftovers, index: index)
    }

    /// Native observations are current. Monitor endpoints are added only when the native scan
    /// could not establish the holder's sockets, so a completed scan's absence means closed.
    static func currentEndpoints(_ input: ProjectionInput) -> [ListeningEndpoint] {
        var result: [ListeningEndpoint] = []
        var keys: Set<String> = []
        let native = input.native
        for endpoint in native?.endpoints ?? [] where keys.insert(endpointKey(endpoint)).inserted {
            result.append(endpoint)
        }
        let inspected = native?.socketInspectedProcesses ?? []
        for endpoint in input.monitorEndpoints where endpoint.endedAt == nil {
            guard !inspected.contains(endpoint.execution.process) else { continue }
            if keys.insert(endpointKey(endpoint)).inserted { result.append(endpoint) }
        }
        return result
    }

    /// Endpoint identity independent of the exec version, so native version-0 and ES
    /// observations of the same socket holder merge while distinct holders stay distinct.
    static func endpointKey(_ endpoint: ListeningEndpoint) -> String {
        "\(endpoint.execution.process.stableID)|\(endpoint.transport.rawValue)|\(endpoint.addressFamily)|\(endpoint.address)|\(endpoint.scopeID)|\(endpoint.port)"
    }

    /// The filesystem root and the home folder are launch locations, not projects.
    static func isMeaningfulProject(_ project: ProjectRecord) -> Bool {
        let root = project.root
        guard root != "/" else { return false }
        if project.gitDirectory != nil { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return root != home && root != "/Users" && root != NSTemporaryDirectory()
    }

    private static func sharedProject(_ attributions: [ServiceAttribution]) -> ProjectRecord? {
        let roots = Set(attributions.compactMap { $0.project?.root })
        guard roots.count == 1 else { return nil }
        return attributions.compactMap(\.project).first
    }
}

// MARK: - Filtering

enum ProjectionSearch {
    /// Case-insensitive literal matching. A numeric query also matches ports exactly.
    static func matches(_ query: String, fields: [String?], port: UInt16? = nil) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if let port, let number = UInt16(trimmed), number == port { return true }
        return fields.contains { field in
            guard let field else { return false }
            return field.range(of: trimmed, options: [.caseInsensitive, .literal]) != nil
        }
    }

    static func filter(_ rows: [AgentRow], _ query: String) -> [AgentRow] {
        rows.filter { matches(query, fields: [$0.agentName, $0.project?.root, $0.command]) }
    }

    static func filter(_ rows: [PortRow], _ query: String) -> [PortRow] {
        rows.filter { row in
            matches(query, fields: [
                row.endpoint.address, row.execution?.command, row.execution?.executable,
                row.project?.root, String(row.endpoint.execution.process.pid)
            ] + row.attributions.map(\.agentName), port: row.endpoint.port)
        }
    }

    static func filter(_ rows: [LeftoverRow], _ query: String) -> [LeftoverRow] {
        rows.filter { row in
            matches(query, fields: [
                row.execution.command, row.execution.executable, row.project?.root,
                String(row.execution.identity.process.pid)
            ] + row.attributions.map(\.agentName), port: nil)
                || row.endpoints.contains { matches(query, fields: [], port: $0.port) }
        }
    }
}
