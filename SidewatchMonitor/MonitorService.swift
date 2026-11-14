import Foundation
import Darwin
import OSLog

/// Privileged broker. Every exported object captures its authenticated connection UID.
/// It never signals a process as root; the host requests a token and uses its own privileges.
final class MonitorService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let registry: UserStoreRegistry
    let client: EndpointSecurityClient
    let capture: CaptureRecord
    private let listener = NSXPCListener(machServiceName: MonitorWire.serviceName)
    private let lock = NSLock()
    private let outbound = DispatchQueue(label: "dev.shisheng.Sidewatch.xpc-notifications", qos: .utility)
    private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    private var storageErrors: [UInt32: String] = [:]
    private var dropCounts: [UInt32: UInt64] = [:]
    private var startupFailure: String?
    private let configurationTransactions = ConfigurationTransactions()
    private var stopping = false
    private var endpoints: [String: ListeningEndpoint] = [:]
    private var nativeTask: Task<Void, Never>?
    private var accessTask: Task<Void, Never>?
    /// Users who erased their data before uninstalling: their store is deleted, not
    /// persisted, when the extension stops. Kept in memory only.
    private var removalArmed: Set<UInt32> = []
    // Assigned once during init, before any client or ES callback can run.
    private var ingestion: ActivityIngestion!
    private struct Subscriber {
        let connection: NSXPCConnection
        let userID: UInt32
    }

    init(capture: CaptureRecord) {
        self.capture = capture
        self.registry = UserStoreRegistry()
        self.client = EndpointSecurityClient(capture: capture)
        super.init()
        listener.delegate = self
        ingestion = ActivityIngestion(stores: { [registry] uid in try await registry.store(for: uid) }, capture: capture,
            snapshot: { [client] uid in client.graph(userID: uid) },
            committed: { [weak self] uid, watermark in self?.didCommit(userID: uid, watermark: watermark) },
            storageFailed: { [weak self] uid, _ in self?.storageFailed(userID: uid) },
            dropped: { [weak self] uid, count in
                self?.lock.withLock { self?.dropCounts[uid, default: 0] &+= count }
            })
        client.setCallbacks(
            activity: { [weak self] uid, event in self?.ingestion.enqueue(event, userID: uid) },
            gap: { [weak self] uid, gap in self?.ingestion.gap(gap, userID: uid) },
            graphChanged: { [weak self] uid in self?.ingestion.graphChanged(userID: uid) },
            healthChanged: { [weak self] uid in self?.queueHealth(userID: uid) })
    }

    func start() async {
        Diagnostics.lifecycle.notice("Monitor broker starting")
        guard !lock.withLock({ stopping }) else { return }
        do {
            for uid in try await registry.knownUserIDs() {
                let store = try await registry.store(for: uid)
                let configuration = try await store.configuration()
                let graph = try await store.graph()
                try Self.validate(configuration)
                guard !lock.withLock({ stopping }) else { return }
                client.restore(graph, configuration: configuration, userID: uid)
            }
            guard !lock.withLock({ stopping }) else { return }
            let result = client.start()
            guard !lock.withLock({ stopping }) else { client.stop(); return }
            switch result.availability {
            case .active: beginCollection()
            case .fullDiskAccessRequired: awaitFullDiskAccess()
            default: break
            }
        } catch {
            lock.withLock { startupFailure = "storage_bootstrap" }
            Diagnostics.storage.error("Persisted monitor configuration could not be restored; code \((error as NSError).code, privacy: .public)")
        }
        guard !lock.withLock({ stopping }) else { return }
        listener.activate()
        Diagnostics.connection.notice("Monitor XPC listener active")
    }

    func shutdown() async {
        let shouldStop = lock.withLock { () -> Bool in
            guard !stopping else { return false }
            stopping = true
            return true
        }
        guard shouldStop else { return }
        listener.invalidate()
        let connections = lock.withLock { Array(subscribers.values.map(\.connection)) }
        for connection in connections { connection.invalidate() }
        let native = lock.withLock { () -> Task<Void, Never>? in
            let task = nativeTask
            nativeTask = nil
            task?.cancel()
            return task
        }
        await native?.value
        let access = lock.withLock { () -> Task<Void, Never>? in
            let task = accessTask
            accessTask = nil
            task?.cancel()
            return task
        }
        await access?.value
        await configurationTransactions.drain()
        client.stop()
        ingestion.stop()
        await ingestion.flush()
        var finalCapture = capture
        finalCapture.endedAt = Date()
        let ended = finalCapture
        let removals = lock.withLock { removalArmed }
        for uid in removals {
            do {
                try await registry.removeStore(for: uid)
                Diagnostics.storage.notice("Erased store removed before uninstall")
            } catch {
                Diagnostics.storage.error("Erased store could not be removed; code \((error as NSError).code, privacy: .public)")
            }
        }
        for uid in client.userIDs() where !removals.contains(uid) {
            do {
                let client = self.client
                let store = try await registry.store(for: uid)
                try await ingestion.withPausedIngestion(userID: uid) { _ in
                    _ = try await store.ingest(.init(capture: ended, graph: client.graph(userID: uid)))
                }
            } catch {
                Diagnostics.storage.error("Final monitor state could not be persisted; code \((error as NSError).code, privacy: .public)")
            }
        }
        Diagnostics.lifecycle.notice("Monitor broker stopped")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard !lock.withLock({ stopping }) else { return false }
        connection.setCodeSigningRequirement("anchor apple generic and identifier \"\(MonitorWire.hostID)\" and certificate leaf[subject.OU] = \"\(MonitorWire.teamID)\"")
        let uid = connection.effectiveUserIdentifier
        let key = ObjectIdentifier(connection)
        let session = MonitorSession(service: self, userID: uid)
        connection.exportedInterface = NSXPCInterface(with: MonitorRemote.self)
        connection.exportedObject = session
        connection.remoteObjectInterface = NSXPCInterface(with: MonitorClient.self)
        connection.invalidationHandler = { [weak self] in
            self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: key) }
            Diagnostics.connection.debug("Monitor XPC client disconnected")
        }
        connection.interruptionHandler = { Diagnostics.connection.debug("Monitor XPC client interrupted") }
        lock.withLock { subscribers[key] = .init(connection: connection, userID: uid) }
        connection.activate()
        Diagnostics.connection.debug("Monitor XPC client accepted")
        return true
    }

    func snapshot(userID: UInt32) async throws -> MonitorSnapshot {
        let store = try await registry.store(for: userID)
        guard !lock.withLock({ stopping }) else { throw BrokerError.monitorInactive }
        if health(userID: userID).availability == .active, client.health(userID: userID).activeRevision == nil {
            _ = try await configurationTransactions.run(userID: userID) { [self] in
                guard !lock.withLock({ stopping }) else { throw BrokerError.monitorInactive }
                let configuration = try await store.configuration()
                if client.health(userID: userID).activeRevision == nil {
                    try client.apply(configuration, userID: userID)
                }
                return configuration
            }
        }
        var value = try await store.snapshot(health: health(userID: userID))
        let live = client.graph(userID: userID)
        value.graph = Self.merge(history: value.graph, live: live)
        // Current-user live identities for native process control; tokens never leave
        // the extension through a snapshot reply.
        value.liveExecutions = client.liveExecutions(userID: userID).map { record in
            var record = record
            record.auditToken = nil
            return record
        }
        let allowed = Set(value.graph.executions.map(\.identity))
        let current = lock.withLock { endpoints.values.filter { allowed.contains($0.execution) && $0.endedAt == nil } }
        var byEndpoint = Dictionary(value.endpoints.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for endpoint in current { byEndpoint[endpoint.id] = endpoint }
        value.endpoints = Array(byEndpoint.values)
        return value
    }

    func activities(_ query: ActivityQuery, userID: UInt32) async throws -> ActivityPage {
        let store = try await registry.store(for: userID)
        return try await store.page(query)
    }

    func configure(_ requested: MonitorConfiguration, userID: UInt32) async throws -> MonitorConfiguration {
        try await configurationTransactions.run(userID: userID) { [self] in
            try await applyConfiguration(requested, userID: userID)
        }
    }

    private func applyConfiguration(_ requested: MonitorConfiguration, userID: UInt32) async throws -> MonitorConfiguration {
        guard !lock.withLock({ stopping }), health(userID: userID).availability == .active else { throw BrokerError.monitorInactive }
        try Self.validate(requested)
        let store = try await registry.store(for: userID)
        let old = try await store.configuration()
        // Each revision is immutable. The client must refresh on conflict instead of overwriting.
        guard requested.revision == old.revision + 1 else { throw BrokerError.configurationConflict }
        var prepared = requested
        let prior = Dictionary(old.rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        prepared.rules = try requested.rules.map { rule in
            if let previous = prior[rule.id], previous.path == rule.path, previous.target == rule.target {
                var reused = rule
                reused.path = previous.path
                reused.fileIdentity = previous.fileIdentity
                return reused
            }
            do {
                return try RuleMatcher.prepare(rule)
            } catch ProtectionRulePreparationError.targetTypeMismatch {
                throw BrokerError.ruleTargetMismatch
            } catch {
                // Missing, unreadable, or empty paths cannot be prepared; this is not a storage failure.
                throw BrokerError.rulePathUnavailable
            }
        }
        try await store.saveConfiguration(prepared)
        try client.apply(prepared, userID: userID)
        let state = client.health(userID: userID)
        guard state.activeRevision == prepared.revision, state.activeMode == prepared.mode else { throw BrokerError.configurationNotApplied }
        ingestion.enqueue(.init(captureID: capture.id, execution: nil, occurredAt: Date(), kind: .modeChange,
                                sessionIDs: [], evidence: .observed, configurationRevision: prepared.revision,
                                mode: prepared.mode, detail: "configurationApplied"), userID: userID)
        queueHealth(userID: userID)
        Diagnostics.lifecycle.notice("Monitor configuration applied")
        return prepared
    }

    func liveToken(_ identity: ExecutionIdentity, userID: UInt32) -> (Data?, Int32) {
        guard !lock.withLock({ stopping }), health(userID: userID).availability == .active else { return (nil, ENOTCONN) }
        return client.liveToken(identity, userID: userID)
    }

    func recordControl(_ action: ControlAction, userID: UInt32) async throws {
        let store = try await registry.store(for: userID)
        guard health(userID: userID).availability == .active else { throw BrokerError.monitorInactive }
        let client = self.client
        let capture = self.capture
        // Persisting the action's execution must not replay a graph snapshot that
        // retention has already removed while this request was waiting.
        try await ingestion.withPausedIngestion(userID: userID) { _ in
            var graph = client.graph(userID: userID)
            var record = graph.executions.first { $0.identity == action.execution }
            if record == nil, let current = client.currentExecution(action.execution.process),
               current.identity == action.execution, current.userID == userID {
                graph.executions.append(current)
                record = current
            }
            guard let record else { throw BrokerError.unknownExecution }
            guard record.userID == userID || !action.signalSent else { throw BrokerError.permissionDenied }
            _ = try await store.ingest(.init(capture: capture, graph: graph))
            try await store.recordControl(action)
        }
    }

    func clearHistory(userID: UInt32) async throws {
        let store = try await registry.store(for: userID)
        try await performRetention(userID: userID, pass: .clear)
        let page = try await store.page(.init(limit: 1))
        didCommit(userID: userID, watermark: page.watermark)
    }

    /// Erase All Data: removes every recorded row for this user, resets the configuration to
    /// the defaults (Record Only, no rules) and applies it, so no erased rule stays enforced.
    /// Processes running now remain tracked in memory and are persisted again as observed.
    func eraseAllData(userID: UInt32) async throws {
        let store = try await registry.store(for: userID)
        guard !lock.withLock({ stopping }) else { throw BrokerError.monitorInactive }
        _ = try await configurationTransactions.run(userID: userID) { [self] in
            let client = self.client
            let ingestion = self.ingestion!
            let configuration = try await ingestion.withPausedIngestion(userID: userID) { boundary in
                let configuration = try await store.eraseAll()
                // Drops recorded memory; executions still running and work seen since the
                // pause began are kept, since protection and attribution depend on them.
                client.retainGraph(GraphSnapshot(), userID: userID, since: boundary)
                try client.apply(configuration, userID: userID)
                ingestion.graphChanged(userID: userID)
                return configuration
            }
            let live = Set(client.graph(userID: userID).executions.map(\.identity))
            let open = lock.withLock { () -> [ListeningEndpoint] in
                dropCounts[userID] = nil
                storageErrors[userID] = nil
                return endpoints.values.filter { $0.endedAt == nil && live.contains($0.execution) }
            }
            if !open.isEmpty { ingestion.updateEndpoints(open, userID: userID) }
            return configuration
        }
        Diagnostics.lifecycle.notice("Monitor data erased")
        let page = try await store.page(.init(limit: 1))
        didCommit(userID: userID, watermark: page.watermark)
    }

    /// Arms (or disarms, when an uninstall is canceled) deletion of this user's store at shutdown.
    func setRemovalArmed(_ armed: Bool, userID: UInt32) {
        lock.withLock {
            if armed { removalArmed.insert(userID) } else { removalArmed.remove(userID) }
        }
        Diagnostics.lifecycle.notice("Store removal on shutdown \(armed ? "armed" : "disarmed", privacy: .public)")
    }

    /// Native socket observations enrich the ES graph without inventing launch history.
    /// Only endpoints belonging to a scoped provenance graph enter its user's history.
    func updateNativeSnapshot(executions: [ExecutionRecord], observed: [ListeningEndpoint], fullyInspected: Set<ProcessIdentity>) {
        guard !lock.withLock({ stopping }), client.health(userID: 0).availability == .active else { return }
        client.ingestProcessSnapshot(executions)
        let graphs = Dictionary(client.userIDs().map { ($0, client.graph(userID: $0)) }, uniquingKeysWith: { _, new in new })
        let exited = Dictionary(graphs.values.flatMap(\.executions).filter { $0.state == .exited }.map { ($0.identity, $0.endedAt) }, uniquingKeysWith: { first, _ in first })
        let timestamp = Date()
        var incoming: [String: ListeningEndpoint] = [:]
        for original in observed {
            var endpoint = original
            if let current = client.currentExecution(original.execution.process) { endpoint.execution = current.identity }
            incoming[endpoint.id] = endpoint
        }
        let changes = lock.withLock { () -> [ListeningEndpoint] in
            var changed: [ListeningEndpoint] = []
            for (id, var endpoint) in incoming {
                if let previous = endpoints[id], previous.endedAt == nil { endpoint.firstObservedAt = previous.firstObservedAt }
                endpoints[id] = endpoint
                changed.append(endpoint)
            }
            // Missing descriptors close only after a complete socket scan or an observed ES exit.
            let firstClosed = changed.count
            for (_, var previous) in endpoints where incoming[previous.id] == nil {
                if let ended = exited[previous.execution] {
                    previous.endedAt = ended ?? timestamp
                } else if fullyInspected.contains(previous.execution.process) {
                    previous.endedAt = timestamp
                } else {
                    continue
                }
                previous.lastObservedAt = timestamp
                changed.append(previous)
            }
            for index in firstClosed..<changed.count { endpoints.removeValue(forKey: changed[index].id) }
            return changed
        }
        for (uid, graph) in graphs {
            let identities = Set(graph.executions.map(\.identity))
            let related = changes.filter { identities.contains($0.execution) }
            if !related.isEmpty { ingestion.updateEndpoints(related, userID: uid) }
        }
    }

    private func beginCollection() {
        ingestion.start()
        for uid in client.userIDs() { ingestion.graphChanged(userID: uid) }
        startNativePolling()
    }

    /// TCC is checked only when an ES client is created, and users usually grant
    /// Full Disk Access after the extension first launches. Retry until it is granted
    /// so collection starts without restarting the extension.
    private func awaitFullDiskAccess() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, !self.lock.withLock({ self.stopping }) else { return }
                let health = self.client.start()
                if health.availability == .active {
                    Diagnostics.lifecycle.notice("Full Disk Access granted; collection starting")
                    self.beginCollection()
                    return
                }
                if health.availability != .fullDiskAccessRequired { return }
            }
        }
        lock.withLock {
            if stopping { task.cancel() } else { accessTask = task }
        }
    }

    private func startNativePolling() {
        let probe = ProcessSnapshotService()
        let task = Task { [weak self] in
            var nextMaintenance = Date.distantPast
            while !Task.isCancelled {
                do {
                    let snapshot = try await probe.snapshot()
                    if Task.isCancelled { break }
                    self?.updateNativeSnapshot(executions: snapshot.executions, observed: snapshot.endpoints,
                                               fullyInspected: snapshot.socketInspectedProcesses)
                } catch {
                    Diagnostics.lifecycle.error("Native process inspection failed; code \((error as NSError).code, privacy: .public)")
                }
                if Date() >= nextMaintenance, !Task.isCancelled {
                    await self?.maintainHistory()
                    nextMaintenance = Date().addingTimeInterval(3_600)
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
        lock.withLock {
            if stopping { task.cancel() } else { nativeTask = task }
        }
    }

    private func maintainHistory() async {
        for uid in client.userIDs() {
            guard !lock.withLock({ stopping }) else { return }
            do {
                try await performRetention(userID: uid, pass: .scheduled(Date()))
                let page = try await registry.store(for: uid).page(.init(limit: 1))
                didCommit(userID: uid, watermark: page.watermark)
            } catch {
                storageFailed(userID: uid)
            }
        }
    }

    private enum RetentionPass: Sendable {
        case clear
        case scheduled(Date)
    }

    /// Manual clear and hourly retention share one path: pause and drain this user's
    /// ingestion, clean storage, read the graph that survived, prune live memory to it,
    /// then resume the buffered work. A graph snapshot copied before the pause is
    /// written first, so it cannot replay the rows this pass removed.
    private func performRetention(userID: UInt32, pass: RetentionPass) async throws {
        let store = try await registry.store(for: userID)
        let client = self.client
        let ingestion = self.ingestion!
        try await ingestion.withPausedIngestion(userID: userID) { boundary in
            switch pass {
            case .clear:
                _ = try await store.clearHistory()
            case .scheduled(let now):
                try await store.retain(now: now)
            }
            let retained = try await store.graph()
            client.retainGraph(retained, userID: userID, since: boundary)
            // Persist the pruned live graph plus anything observed during the pass.
            ingestion.graphChanged(userID: userID)
        }
    }

    func health(userID: UInt32) -> MonitorHealth {
        var result = client.health(userID: userID)
        let state = lock.withLock { (startupFailure, storageErrors[userID], dropCounts[userID] ?? 0) }
        if let failure = state.0 { result.availability = .unavailable; result.message = failure; result.activeMode = nil; result.activeRevision = nil }
        result.storageError = state.1
        result.droppedEvents &+= state.2
        return result
    }

    private func storageFailed(userID: UInt32) {
        lock.withLock { storageErrors[userID] = "storage_unavailable" }
        queueHealth(userID: userID)
    }

    private func didCommit(userID: UInt32, watermark: Int64) {
        _ = lock.withLock { storageErrors.removeValue(forKey: userID) }
        Task { [weak self] in
            guard let self else { return }
            do {
                let store = try await registry.store(for: userID)
                let targets = connections(userID: userID)
                for target in targets {
                    (target.remoteObjectProxyWithErrorHandler { _ in } as? MonitorClient)?.databaseDidCommit(store.storeID, watermark: watermark)
                }
                queueHealth(userID: userID)
            } catch { storageFailed(userID: userID) }
        }
    }

    private func connections(userID: UInt32) -> [NSXPCConnection] {
        lock.withLock { subscribers.values.filter { $0.userID == userID }.map(\.connection) }
    }

    private func queueHealth(userID: UInt32) {
        outbound.async { [weak self] in
            guard let self else { return }
            let data = MonitorWire.reply(health(userID: userID))
            for connection in connections(userID: userID) {
                (connection.remoteObjectProxyWithErrorHandler { _ in } as? MonitorClient)?.monitorHealthChanged(data)
            }
        }
    }

    private static func merge(history: GraphSnapshot, live: GraphSnapshot) -> GraphSnapshot {
        var executions = Dictionary(history.executions.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        for var record in live.executions { record.auditToken = nil; executions[record.identity] = record }
        var sessions = Dictionary(history.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for session in live.sessions { sessions[session.id] = session }
        return .init(executions: Array(executions.values), edges: Array(Set(history.edges).union(live.edges)),
                     sessions: Array(sessions.values), associations: Array(Set(history.associations).union(live.associations)))
    }

    private static func validate(_ configuration: MonitorConfiguration) throws {
        guard configuration.revision > 0, (1...3650).contains(configuration.retentionDays),
              configuration.storageBudgetBytes >= 1024 * 1024, configuration.rules.count <= 512,
              configuration.agentDefinitions.count <= 64,
              Set(configuration.rules.map(\.id)).count == configuration.rules.count,
              Set(configuration.agentDefinitions.map(\.id)).count == configuration.agentDefinitions.count else { throw BrokerError.invalidConfiguration }
        for rule in configuration.rules {
            guard !rule.id.isEmpty, !rule.name.isEmpty, rule.path.hasPrefix("/"), !rule.path.contains("\0"),
                  rule.path.utf8.count <= 4096, !rule.operations.isEmpty else { throw BrokerError.invalidConfiguration }
        }
        for agent in configuration.agentDefinitions {
            guard !agent.id.isEmpty, !agent.name.isEmpty,
                  !(agent.executableNames.isEmpty && agent.scriptPathComponents.isEmpty && agent.installDirectoryComponents.isEmpty),
                  agent.executableNames.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\0") }),
                  agent.scriptPathComponents.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }),
                  agent.installDirectoryComponents.count <= 8,
                  agent.installDirectoryComponents.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\0") && $0 != "." && $0 != ".." })
            else { throw BrokerError.invalidConfiguration }
        }
    }
}

private enum BrokerError: Error {
    case monitorInactive, configurationConflict, configurationNotApplied, unknownExecution, permissionDenied, invalidConfiguration, invalidRequest, rulePathUnavailable, ruleTargetMismatch
    var code: String {
        switch self {
        case .monitorInactive: "monitor_inactive"
        case .configurationConflict: "configuration_conflict"
        case .configurationNotApplied: "configuration_not_applied"
        case .unknownExecution: "unknown_execution"
        case .permissionDenied: "permission_denied"
        case .invalidConfiguration: "invalid_configuration"
        case .invalidRequest: "invalid_request"
        case .rulePathUnavailable: "rule_path_unavailable"
        case .ruleTargetMismatch: "rule_target_mismatch"
        }
    }
}

private final class OnceReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Value) -> Void)?
    init(_ callback: @escaping (Value) -> Void) { self.callback = callback }
    func send(_ value: Value) {
        let action = lock.withLock { () -> ((Value) -> Void)? in
            defer { callback = nil }
            return callback
        }
        action?(value)
    }
}

private final class MonitorSession: NSObject, MonitorRemote, @unchecked Sendable {
    private weak var service: MonitorService?
    private let userID: UInt32
    private let lock = NSLock()
    private var handshaken = false
    init(service: MonitorService, userID: UInt32) { self.service = service; self.userID = userID }

    func handshake(_ version: Int, withReply reply: @escaping (Data) -> Void) {
        guard version == MonitorWire.version else {
            reply(MonitorWire.failure("Unsupported protocol version.", code: "version"))
            return
        }
        lock.withLock { handshaken = true }
        reply(MonitorWire.reply(EmptyReply()))
    }

    func snapshot(withReply reply: @escaping (Data) -> Void) {
        perform(reply) { service, uid in MonitorWire.reply(try await service.snapshot(userID: uid)) }
    }

    func activities(_ query: Data, withReply reply: @escaping (Data) -> Void) {
        perform(reply) { service, uid in
            let value = try Self.decode(ActivityQuery.self, query, limit: 65_536)
            return MonitorWire.reply(try await service.activities(value, userID: uid))
        }
    }

    func configure(_ configuration: Data, withReply reply: @escaping (Data) -> Void) {
        perform(reply) { service, uid in
            let value = try Self.decode(MonitorConfiguration.self, configuration, limit: 4 * 1024 * 1024)
            return MonitorWire.reply(try await service.configure(value, userID: uid))
        }
    }

    func liveToken(_ execution: Data, withReply reply: @escaping (Data?, Int32) -> Void) {
        guard lock.withLock({ handshaken }), let service else { reply(nil, ENOTCONN); return }
        do {
            let identity = try Self.decode(ExecutionIdentity.self, execution, limit: 4096)
            let result = service.liveToken(identity, userID: userID)
            reply(result.0, result.1)
        } catch { reply(nil, EINVAL) }
    }

    func recordControl(_ action: Data, withReply reply: @escaping (Data) -> Void) {
        perform(reply) { service, uid in
            let value = try Self.decode(ControlAction.self, action, limit: 16_384)
            try await service.recordControl(value, userID: uid)
            return MonitorWire.reply(EmptyReply())
        }
    }

    func clearHistory(withReply reply: @escaping (Data) -> Void) {
        perform(reply) { service, uid in
            try await service.clearHistory(userID: uid)
            return MonitorWire.reply(EmptyReply())
        }
    }

    func eraseAllData(withReply reply: @escaping (Data) -> Void) {
        perform(reply) { service, uid in
            try await service.eraseAllData(userID: uid)
            return MonitorWire.reply(EmptyReply())
        }
    }

    func prepareForRemoval(_ armed: Bool, withReply reply: @escaping (Data) -> Void) {
        perform(reply) { service, uid in
            service.setRemovalArmed(armed, userID: uid)
            return MonitorWire.reply(EmptyReply())
        }
    }

    private func perform(_ callback: @escaping (Data) -> Void,
                         operation: @escaping @Sendable (MonitorService, UInt32) async throws -> Data) {
        let reply = OnceReply(callback)
        guard lock.withLock({ handshaken }), let service else {
            reply.send(MonitorWire.failure("Monitor connection is not ready.", code: "not_connected"))
            return
        }
        let uid = userID
        Task {
            do { reply.send(try await operation(service, uid)) }
            catch {
                let code = (error as? ActivityStoreError)?.code
                    ?? (error as? BrokerError)?.code
                    ?? (error as? EndpointSecurityClientError)?.code
                    ?? "storage_unavailable"
                Diagnostics.connection.error("Monitor request failed; code \((error as NSError).code, privacy: .public)")
                reply.send(MonitorWire.failure("The monitor request could not be completed.", code: code))
            }
        }
    }

    private static func decode<T: Codable & Sendable>(_ type: T.Type, _ data: Data, limit: Int) throws -> T {
        guard data.count <= limit else { throw BrokerError.invalidRequest }
        do { return try MonitorWire.decode(type, from: data) }
        catch { throw BrokerError.invalidRequest }
    }
}
