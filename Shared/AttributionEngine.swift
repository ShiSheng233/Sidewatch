import Foundation

/// Maintains the in-memory execution graph, agent sessions and associations.
///
/// This type is intentionally not `Sendable`. All calls are confined by the caller to one
/// serial context. The Endpoint Security client creates it on its callback synchronization
/// queue, so `observe` must stay free of database, network and other blocking I/O.
/// Project resolution is injected for the same reason: the authorization path may install a
/// memory-only lookup, while a background worker populates a disk-backed cache.
final class AttributionEngine {
    private struct EdgeKey: Hashable {
        let parent: ExecutionIdentity
        let child: ExecutionIdentity
        let kind: EdgeKind
    }

    private var executions: [ExecutionIdentity: ExecutionRecord] = [:]
    private var edges: [ExecutionEdge] = []
    private var edgeKeys: Set<EdgeKey> = []
    private var sessions: [String: AgentSession] = [:]
    private var associations: [ExecutionIdentity: [String: EvidenceKind]] = [:]
    // Process instances survive exec; the latest execution version anchors the next exec edge.
    private var latestByProcess: [ProcessIdentity: ExecutionIdentity] = [:]
    private let projectResolver: (String?) -> ProjectRecord?
    private var definitions: [AgentDefinition]

    init(projectResolver: @escaping (String?) -> ProjectRecord? = ProjectResolver.resolve,
         definitions: [AgentDefinition] = AgentDefinition.defaults) {
        self.projectResolver = projectResolver
        self.definitions = definitions
    }

    func configure(definitions: [AgentDefinition]) {
        self.definitions = definitions
        // A process can have both its native snapshot placeholder and its observed execution
        // in memory during startup reconciliation. Recognize only the observed identity so a
        // definition refresh cannot create a second active root for the same process.
        let liveProcesses = Set(
            executions.values
                .filter { $0.state == .running && $0.evidence != .snapshot }
                .map(\.identity.process)
        )
        for execution in executions.values where execution.state == .running {
            if execution.evidence == .snapshot,
               liveProcesses.contains(execution.identity.process) {
                continue
            }
            if let agent = AgentRecognizer.recognize(execution, definitions: definitions) {
                let evidence = recognitionEvidence(for: execution)
                if let existing = liveSessionID(for: execution.identity, agentID: agent.id) {
                    addAssociation(identity: execution.identity, sessionID: existing, evidence: evidence)
                } else {
                    let root = session(for: agent, root: execution, evidence: evidence)
                    addAssociation(identity: execution.identity, sessionID: root.id, evidence: evidence)
                }
            }
        }
    }

    // MARK: - Observation

    func observe(_ execution: ExecutionRecord, kind: EdgeKind? = nil, at: Date = Date()) {
        let identity = execution.identity
        // Capture the predecessor before recording this version, so exec links the two.
        let previous = latestByProcess[identity.process]

        var record = execution
        if let existing = executions[identity] {
            if record.arguments.isEmpty { record.arguments = existing.arguments }
            if record.workingDirectory == nil { record.workingDirectory = existing.workingDirectory }
            if record.signingID == nil { record.signingID = existing.signingID }
            if record.teamID == nil { record.teamID = existing.teamID }
            record.startedAt = existing.startedAt
            // An execution identity is terminal. A late duplicate observation cannot revive it.
            if existing.state == .exited {
                record.state = .exited
                record.endedAt = existing.endedAt ?? record.endedAt
                record.auditToken = nil
            }
        }
        executions[identity] = record

        var inherited: [String: EvidenceKind] = [:]
        switch kind {
        case .exec:
            if let previous, previous != identity, executions[previous] != nil {
                addEdge(
                    parent: previous,
                    child: identity,
                    kind: .exec,
                    evidence: execution.evidence == .observed ? .observed : .inferred,
                    at: at
                )
                inheritSessions(from: previous, evidence: nil, into: &inherited)
                var predecessor = executions[previous]!
                predecessor.state = .exited
                predecessor.endedAt = at
                predecessor.auditToken = nil
                executions[previous] = predecessor
                endSessions(root: previous, at: at, reason: "execReplaced")
                // A native snapshot root for the same process is the predecessor execution.
                // Its session must not remain a second active root after the exec.
                let snapshotRoots = executions.filter {
                    $0.key.process == identity.process
                        && $0.key != previous
                        && $0.key != identity
                        && $0.value.evidence == .snapshot
                }.map(\.key)
                for root in snapshotRoots {
                    if var placeholder = executions[root], placeholder.state != .exited {
                        placeholder.state = .exited
                        placeholder.endedAt = at
                        placeholder.auditToken = nil
                        executions[root] = placeholder
                    }
                    endSessions(root: root, at: at, reason: "execReplaced")
                }
            }
        case .responsible:
            // Responsible-token evidence is auxiliary and never replaces the startup chain.
            if let responsible = execution.responsible, executions[responsible] != nil {
                addEdge(parent: responsible, child: identity, kind: .responsible, evidence: .inferred, at: at)
            }
        case .fork:
            if let parent = execution.parent, let parentRecord = executions[parent],
               parentRecord.state == .running, parent.process.bootID == identity.process.bootID {
                let evidence: EvidenceKind = execution.evidence == .observed ? .observed : .inferred
                addEdge(parent: parent, child: identity, kind: .fork, evidence: evidence, at: at)
                inheritSessions(from: parent, evidence: evidence == .observed ? nil : .inferred, into: &inherited)
            } else if let parent = inferredParent(for: execution) {
                addEdge(parent: parent, child: identity, kind: .fork, evidence: .inferred, at: at)
                inheritSessions(from: parent, evidence: .inferred, into: &inherited)
            }
        case nil:
            if let parent = inferredParent(for: execution) {
                addEdge(parent: parent, child: identity, kind: .fork, evidence: .inferred, at: at)
                inheritSessions(from: parent, evidence: .inferred, into: &inherited)
            }
        }

        for (sessionID, evidence) in inherited {
            addAssociation(identity: identity, sessionID: sessionID, evidence: evidence)
        }

        if let agent = AgentRecognizer.recognize(record, definitions: definitions) {
            let evidence = recognitionEvidence(for: record)
            if let existing = liveSessionID(for: identity, agentID: agent.id) {
                // The process already has a live root for this agent (startup snapshot
                // reconciliation). Link this execution to it instead of creating a duplicate.
                addAssociation(identity: identity, sessionID: existing, evidence: evidence)
            } else {
                let session = session(for: agent, root: record, evidence: evidence)
                addAssociation(identity: identity, sessionID: session.id, evidence: evidence)
            }
        }

        updateLatest(record)
    }

    func exit(_ identity: ExecutionIdentity, at: Date) {
        guard var record = executions[identity] else { return }
        if record.state != .exited {
            record.state = .exited
            record.endedAt = record.endedAt ?? at
            record.auditToken = nil
            executions[identity] = record
        }
        endSessions(root: identity, at: at, reason: "processExited")

        // A native snapshot placeholder for the same process represents the same execution.
        // Retire it with the observed exit so a persisted snapshot root cannot stay live
        // forever, and so sessions rooted at the synthetic version-0 identity end too.
        let snapshotRoots = executions.filter {
            $0.key.process == identity.process
                && $0.key != identity
                && $0.value.evidence == .snapshot
        }.map(\.key)
        for root in snapshotRoots {
            guard var placeholder = executions[root] else { continue }
            if placeholder.state != .exited {
                placeholder.state = .exited
                placeholder.endedAt = at
                placeholder.auditToken = nil
                executions[root] = placeholder
            }
            endSessions(root: root, at: at, reason: "processExited")
        }
    }

    private func endSessions(root: ExecutionIdentity, at: Date, reason: String) {
        for sessionID in Array(sessions.keys) {
            guard var session = sessions[sessionID], session.root == root, session.endedAt == nil else { continue }
            session.endedAt = at
            session.endReason = reason
            sessions[sessionID] = session
        }
    }

    /// Marks the capture as interrupted. States become unknown rather than exited, so no
    /// session is ended and no process is reported as a confirmed orphan.
    func markUnknown() {
        for identity in Array(executions.keys) {
            guard var record = executions[identity], record.state == .running else { continue }
            record.state = .unknown
            record.auditToken = nil
            executions[identity] = record
        }
    }

    // MARK: - Restore and snapshot

    /// Restores a persisted graph. Tokens are always discarded and running executions become
    /// unknown, because disk history is not proof of a live process. Sessions are keyed by
    /// their root execution identity, so duplicate persisted sessions cannot multiply.
    func restore(_ graph: GraphSnapshot) {
        executions.removeAll()
        edges.removeAll()
        edgeKeys.removeAll()
        sessions.removeAll()
        associations.removeAll()
        latestByProcess.removeAll()

        for original in graph.executions {
            var record = original
            record.auditToken = nil
            if record.state == .running { record.state = .unknown }
            if let existing = executions[record.identity], existing.state == .exited {
                record.state = .exited
                record.endedAt = existing.endedAt ?? record.endedAt
            }
            executions[record.identity] = record
        }

        for edge in graph.edges where executions[edge.parent] != nil && executions[edge.child] != nil {
            addEdge(parent: edge.parent, child: edge.child, kind: edge.kind, evidence: edge.evidence, at: edge.observedAt)
        }

        var sessionIDMap: [String: String] = [:]
        for original in graph.sessions {
            guard let root = executions[original.root] else { continue }
            let stableID = sessionID(for: original.root)
            sessionIDMap[original.id] = stableID
            var session = original
            session.id = stableID
            if session.endedAt == nil, root.state == .exited {
                session.endedAt = root.endedAt ?? session.startedAt
                session.endReason = session.endReason ?? "processExited"
            }
            if var existing = sessions[stableID] {
                if existing.endedAt == nil, let endedAt = session.endedAt {
                    existing.endedAt = endedAt
                    existing.endReason = existing.endReason ?? session.endReason
                }
                if existing.project == nil { existing.project = session.project }
                sessions[stableID] = existing
            } else {
                sessions[stableID] = session
            }
        }

        for association in graph.associations {
            guard executions[association.execution] != nil else { continue }
            guard let sessionID = sessionIDMap[association.sessionID] ?? (sessions[association.sessionID] != nil ? association.sessionID : nil) else { continue }
            addAssociation(identity: association.execution, sessionID: sessionID, evidence: association.evidence)
        }

        for record in executions.values {
            updateLatest(record)
        }
    }

    /// Reconciles the first exact live Endpoint Security observation of a process that native
    /// polling reported with a synthetic version-0 identity. The snapshot record stays the
    /// canonical session root (so its persisted session id remains stable across restarts),
    /// while the observed record carries the live token and copies the snapshot attribution.
    /// This is not an exec: no exec/exit edge or session end is produced.
    @discardableResult
    func adoptObserved(_ execution: ExecutionRecord) -> Bool {
        let process = execution.identity.process
        let snapshots = executions.filter {
            $0.key.process == process
                && $0.key != execution.identity
                && $0.value.evidence == .snapshot
        }
        guard !snapshots.isEmpty else { return false }

        let snapshotIdentity: ExecutionIdentity
        if let latest = latestByProcess[process], snapshots[latest] != nil {
            snapshotIdentity = latest
        } else {
            snapshotIdentity = snapshots.keys.max {
                if $0.version != $1.version { return $0.version < $1.version }
                return $0.stableID < $1.stableID
            }!
        }
        guard let snapshot = executions[snapshotIdentity] else { return false }

        var record = execution
        if record.arguments.isEmpty { record.arguments = snapshot.arguments }
        if record.workingDirectory == nil { record.workingDirectory = snapshot.workingDirectory }
        if record.parent == nil { record.parent = snapshot.parent }
        if record.responsible == nil { record.responsible = snapshot.responsible }
        if record.signingID == nil { record.signingID = snapshot.signingID }
        if record.teamID == nil { record.teamID = snapshot.teamID }
        record.startedAt = snapshot.startedAt
        if let existing = executions[record.identity], existing.state == .exited {
            record.state = .exited
            record.endedAt = existing.endedAt
            record.auditToken = nil
        }
        executions[record.identity] = record

        // Copy the snapshot's recognized session links to the live identity. The links keep
        // their original evidence; a fresh observation does not upgrade snapshot attribution.
        var inherited: [String: EvidenceKind] = [:]
        for identity in snapshots.keys {
            for (sessionID, evidence) in sessions(for: identity) {
                inherited[sessionID] = inherited[sessionID].map {
                    strongestEvidence($0, evidence)
                } ?? evidence
            }
        }
        for (sessionID, evidence) in inherited {
            addAssociation(identity: record.identity, sessionID: sessionID, evidence: evidence)
        }

        updateLatest(record)
        return true
    }

    /// Removes memory history that storage no longer retains while preserving everything the
    /// live capture still depends on. Called by the broker on a live engine after its SQL
    /// retention pass; `retained` is the graph that survived, and observations at or after
    /// `boundary` may have arrived while that pass ran. This never restores a graph, so live
    /// tokens, session ends, and current metadata are unchanged.
    func retain(_ retained: GraphSnapshot, since boundary: Date) {
        let retainedExecutions = Set(retained.executions.map(\.identity))
        let retainedEdges = Set(retained.edges)
        let retainedSessions = Set(retained.sessions.map(\.id))
        let retainedAssociations = Set(
            retained.associations.map { $0.execution.stableID + "|" + $0.sessionID }
        )

        func isActive(_ record: ExecutionRecord) -> Bool {
            if record.state != .exited { return true }
            if record.startedAt >= boundary { return true }
            if let endedAt = record.endedAt, endedAt >= boundary { return true }
            return false
        }

        var keptExecutions: [ExecutionIdentity: ExecutionRecord] = [:]
        for (identity, record) in executions
        where retainedExecutions.contains(identity) || isActive(record) {
            keptExecutions[identity] = record
        }

        // A session that an active execution still references pins its root. The root may
        // have ended before the boundary, but the live descendant's attribution depends on it.
        var sessionsForActiveExecutions: Set<String> = []
        for (identity, record) in keptExecutions where isActive(record) {
            if let entries = associations[identity] {
                sessionsForActiveExecutions.formUnion(entries.keys)
            }
        }
        for sessionID in sessionsForActiveExecutions {
            guard let session = sessions[sessionID], keptExecutions[session.root] == nil,
                  let root = executions[session.root] else {
                continue
            }
            keptExecutions[session.root] = root
        }

        // Keep the complete ancestry of every retained or active execution. The edges used
        // for that closure are retained so a projected graph can still explain the lineage.
        var lineageEdges: Set<ExecutionEdge> = []
        let ancestryEdges = edges.filter { $0.kind == .fork || $0.kind == .exec }
        var changed = true
        while changed {
            changed = false
            var additions: [ExecutionIdentity: ExecutionRecord] = [:]
            for edge in ancestryEdges where keptExecutions[edge.child] != nil {
                lineageEdges.insert(edge)
                if keptExecutions[edge.parent] == nil, let parent = executions[edge.parent] {
                    additions[edge.parent] = parent
                }
            }
            for record in keptExecutions.values {
                if let parent = record.parent, keptExecutions[parent] == nil,
                   let ancestor = executions[parent] {
                    additions[parent] = ancestor
                }
            }
            if !additions.isEmpty {
                for (identity, record) in additions where keptExecutions[identity] == nil {
                    keptExecutions[identity] = record
                }
                changed = true
            }
        }

        var keptSessions: [String: AgentSession] = [:]
        for (sessionID, session) in sessions {
            guard keptExecutions[session.root] != nil else { continue }
            let live = session.endedAt == nil
            let recent = session.startedAt >= boundary
                || (session.endedAt.map { $0 >= boundary } ?? false)
            // A session an active execution still points at remains live attribution even if
            // its original root ended before this boundary.
            if retainedSessions.contains(sessionID)
                || live
                || recent
                || sessionsForActiveExecutions.contains(sessionID) {
                keptSessions[sessionID] = session
            }
        }

        var keptAssociations: [ExecutionIdentity: [String: EvidenceKind]] = [:]
        for (identity, entries) in associations {
            guard let record = keptExecutions[identity] else { continue }
            for (sessionID, evidence) in entries {
                guard let session = keptSessions[sessionID] else { continue }
                let key = identity.stableID + "|" + sessionID
                let active = isActive(record) || session.endedAt == nil
                if retainedAssociations.contains(key) || active {
                    keptAssociations[identity, default: [:]][sessionID] = evidence
                }
            }
        }

        var keptEdges: [ExecutionEdge] = []
        var keptEdgeKeys: Set<EdgeKey> = []
        for edge in edges {
            guard keptExecutions[edge.parent] != nil, keptExecutions[edge.child] != nil else {
                continue
            }
            let active = isActive(keptExecutions[edge.parent]!)
                || isActive(keptExecutions[edge.child]!)
            guard retainedEdges.contains(edge)
                || lineageEdges.contains(edge)
                || edge.observedAt >= boundary
                || active else {
                continue
            }
            let key = EdgeKey(parent: edge.parent, child: edge.child, kind: edge.kind)
            guard keptEdgeKeys.insert(key).inserted else { continue }
            keptEdges.append(edge)
        }

        executions = keptExecutions
        sessions = keptSessions
        associations = keptAssociations
        edges = keptEdges
        edgeKeys = keptEdgeKeys

        latestByProcess.removeAll(keepingCapacity: true)
        for record in executions.values {
            updateLatest(record)
        }
    }

    /// Snapshot of the current live graph. Tokens reflect live observations; persisting callers
    /// must omit them, while `restore` always discards them.
    func snapshot() -> GraphSnapshot {
        var graph = copySnapshot()
        graph.executions.sort {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.identity.stableID < $1.identity.stableID
        }
        graph.edges.sort {
            if $0.child != $1.child { return $0.child.stableID < $1.child.stableID }
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.parent.stableID < $1.parent.stableID
        }
        graph.sessions.sort { $0.id < $1.id }
        graph.associations.sort {
            if $0.execution != $1.execution { return $0.execution.stableID < $1.execution.stableID }
            return $0.sessionID < $1.sessionID
        }
        return graph
    }

    /// Unsorted copy of the graph for callers that must leave a short synchronization region
    /// before sorting and projecting. The engine remains confined to its serial caller.
    func copySnapshot() -> GraphSnapshot {
        var graph = GraphSnapshot()
        graph.executions = Array(executions.values)
        graph.edges = edges
        graph.sessions = Array(sessions.values)
        graph.associations = associations.flatMap { pair -> [ExecutionAssociation] in
            let (execution, entries) = pair
            return entries.map { entry in
                ExecutionAssociation(
                    execution: execution,
                    sessionID: entry.key,
                    evidence: entry.value
                )
            }
        }
        return graph
    }

    // MARK: - Queries

    func sessionIDs(for identity: ExecutionIdentity) -> [String] {
        (associations[identity]?.keys).map { Array($0).sorted() } ?? []
    }

    func agents(for identity: ExecutionIdentity) -> Set<String> {
        Set(sessionIDs(for: identity).compactMap { sessions[$0]?.agent.id })
    }

    func execution(for identity: ExecutionIdentity) -> ExecutionRecord? { executions[identity] }

    /// Latest known execution version for a process instance. Like every engine accessor this
    /// is a cheap in-memory lookup confined to the caller's serial context.
    func currentExecution(for process: ProcessIdentity) -> ExecutionRecord? {
        guard let identity = latestByProcess[process] else { return nil }
        return executions[identity]
    }

    func project(for identity: ExecutionIdentity) -> ProjectRecord? {
        var result: ProjectRecord?
        for sessionID in sessionIDs(for: identity) {
            guard let project = sessions[sessionID]?.project else { continue }
            if let result, result.root != project.root { return nil }
            result = project
        }
        return result
    }

    /// True when the execution belongs to at least one recognized agent session, directly or
    /// through an observed/inferred parent chain. Unattributed processes are excluded.
    func isRelated(_ identity: ExecutionIdentity) -> Bool {
        !(associations[identity]?.isEmpty ?? true)
    }

    /// Running executions still alive after every session they are related to has confirmed
    /// the agent's exit. Unknown capture intervals are not treated as confirmed exits.
    func leftovers() -> [ExecutionRecord] {
        var result: [ExecutionRecord] = []
        for (identity, entries) in associations {
            guard let record = executions[identity], record.state == .running else { continue }
            var hasLiveSession = false
            var hasExitedSession = false
            for sessionID in entries.keys {
                guard let session = sessions[sessionID] else { continue }
                if session.endedAt == nil {
                    hasLiveSession = true
                } else {
                    hasExitedSession = true
                }
            }
            if hasExitedSession && !hasLiveSession {
                result.append(record)
            }
        }
        return result.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.identity.stableID < $1.identity.stableID
        }
    }

    // MARK: - Internals

    private func inferredParent(for execution: ExecutionRecord) -> ExecutionIdentity? {
        let candidates = executions.values.filter {
            $0.identity != execution.identity
                && $0.identity.process.bootID == execution.identity.process.bootID
                && $0.identity.process.pid == execution.parentPID
                && $0.state == .running
                && $0.startedAt <= execution.startedAt
        }
        return candidates.max {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.identity.version < $1.identity.version
        }?.identity
    }

    private func addEdge(parent: ExecutionIdentity, child: ExecutionIdentity, kind: EdgeKind, evidence: EvidenceKind, at: Date) {
        guard parent != child else { return }
        let key = EdgeKey(parent: parent, child: child, kind: kind)
        guard edgeKeys.insert(key).inserted else { return }
        edges.append(ExecutionEdge(parent: parent, child: child, kind: kind, evidence: evidence, observedAt: at))
    }

    private func sessionID(for root: ExecutionIdentity) -> String {
        "session:\(root.stableID)"
    }

    private func recognitionEvidence(for execution: ExecutionRecord) -> EvidenceKind {
        switch execution.evidence {
        case .observed:
            return .observed
        case .snapshot:
            return .snapshot
        case .inferred, .responsible:
            return .inferred
        }
    }

    /// A live session already attributes this execution to the same agent for the same process
    /// instance. Recognition must not create a second active root while reconciling a native
    /// snapshot identity; a forked child process is still a new root, and an exec after ending
    /// the previous root still creates one.
    private func liveSessionID(for identity: ExecutionIdentity, agentID: String) -> String? {
        if let entries = associations[identity] {
            let match = entries.keys
                .filter { sessionID in
                    guard let session = sessions[sessionID],
                          session.agent.id == agentID,
                          session.endedAt == nil else {
                        return false
                    }
                    return session.root.process == identity.process
                }
                .sorted()
                .first
            if let match { return match }
        }
        // The execution may not be linked yet (for example a native snapshot record arriving
        // after the live identity was observed). A live root for the same process instance is
        // still the one active root for this agent.
        return sessions.values
            .filter {
                $0.agent.id == agentID
                    && $0.endedAt == nil
                    && $0.root.process == identity.process
            }
            .map(\.id)
            .sorted()
            .first
    }

    private func session(for agent: AgentDefinition, root execution: ExecutionRecord, evidence: EvidenceKind) -> AgentSession {
        let id = sessionID(for: execution.identity)
        if var existing = sessions[id] {
            if existing.project == nil {
                existing.project = projectResolver(execution.workingDirectory)
                sessions[id] = existing
            }
            return existing
        }
        let session = AgentSession(
            id: id,
            agent: agent,
            root: execution.identity,
            project: projectResolver(execution.workingDirectory),
            startedAt: execution.startedAt,
            endedAt: nil,
            endReason: nil,
            evidence: evidence
        )
        sessions[id] = session
        return session
    }

    /// Sessions already recorded for an execution, including inherited ones.
    private func sessions(for identity: ExecutionIdentity) -> [String: EvidenceKind] {
        associations[identity] ?? [:]
    }

    /// Copies the parent's session links to a child. Fork links were observed, but the child's
    /// relation to the agent is inferred. Exec keeps the process's existing attribution and
    /// evidence because the execution identity changes while the process does not.
    private func inheritSessions(from identity: ExecutionIdentity, evidence: EvidenceKind?, into inherited: inout [String: EvidenceKind]) {
        for (sessionID, existing) in sessions(for: identity) {
            inherited[sessionID] = evidence ?? existing
        }
    }

    private func addAssociation(identity: ExecutionIdentity, sessionID: String, evidence: EvidenceKind) {
        guard sessions[sessionID] != nil else { return }
        var entries = associations[identity] ?? [:]
        if let existing = entries[sessionID] {
            entries[sessionID] = strongestEvidence(existing, evidence)
        } else {
            entries[sessionID] = evidence
        }
        associations[identity] = entries
    }

    private func strongestEvidence(_ lhs: EvidenceKind, _ rhs: EvidenceKind) -> EvidenceKind {
        // Direct observation is strongest. Inherited links stay inferred so a child never
        // claims its agent relationship was directly observed. Snapshot remains the weakest
        // positive evidence and is never upgraded by a restored graph.
        if lhs == .observed || rhs == .observed { return .observed }
        if lhs == .inferred || rhs == .inferred { return .inferred }
        if lhs == .snapshot || rhs == .snapshot { return .snapshot }
        return .responsible
    }

    private func updateLatest(_ record: ExecutionRecord) {
        let process = record.identity.process
        guard let currentID = latestByProcess[process], let current = executions[currentID] else {
            latestByProcess[process] = record.identity
            return
        }
        if record.identity.version > current.identity.version
            || (record.identity.version == current.identity.version && record.startedAt > current.startedAt) {
            latestByProcess[process] = record.identity
        }
    }
}
