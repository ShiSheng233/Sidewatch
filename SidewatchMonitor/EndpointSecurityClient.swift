import Darwin
import EndpointSecurity
import Foundation

enum EndpointSecurityClientError: Error, Equatable {
    /// Endpoint Security is not running, so a mode that needs AUTH cannot be acknowledged.
    case endpointSecurityInactive
    /// The server-supplied configuration is not an immutable, absolute-path snapshot.
    case invalidConfiguration
    /// Endpoint Security rejected a required AUTH subscription change.
    case subscriptionFailed

    /// Stable, non-sensitive code for the broker's wire error envelopes.
    var code: String {
        switch self {
        case .endpointSecurityInactive: "es_inactive"
        case .invalidConfiguration: "es_invalid_configuration"
        case .subscriptionFailed: "es_subscription_failed"
        }
    }
}

/// Owner-scope routing keyed by process instance.
///
/// A process inherits owner scopes only from established agent provenance. Otherwise its own
/// effective UID establishes a dispatch-only scope that never propagates to children, so shared
/// system ancestors (launchd and friends) cannot hand UID 0 ownership to an ordinary user's
/// agent descendants across privilege changes. A genuine agent lineage survives sudo/exec.
final class ESProvenanceIndex {
    private var effectiveScopes: [ProcessIdentity: Set<UInt32>] = [:]
    private var provenanceScopes: [ProcessIdentity: Set<UInt32>] = [:]

    var processCount: Int { effectiveScopes.count }

    /// Effective owner scopes for a process. Cached after the first observation:
    /// inherit actual provenance from `parent`, otherwise dispatch to this process's euid.
    func owners(
        for process: ProcessIdentity,
        userID: UInt32,
        parent: ExecutionIdentity?
    ) -> Set<UInt32> {
        if let existing = effectiveScopes[process], !existing.isEmpty {
            return existing
        }
        var owners: Set<UInt32> = []
        if let parent, let inherited = provenanceScopes[parent.process], !inherited.isEmpty {
            owners = inherited
        }
        if owners.isEmpty {
            owners = [userID]
        }
        effectiveScopes[process] = owners
        return owners
    }

    func scopes(for process: ProcessIdentity) -> Set<UInt32>? {
        effectiveScopes[process]
    }

    /// Records that a user's engine attributes this process to a recognized agent session.
    /// Only this kind of scope is inherited by children. A late attribution also joins the
    /// process's effective scopes so its own AUTH and file events route to that user.
    func markProvenance(_ userID: UInt32, for process: ProcessIdentity) {
        provenanceScopes[process, default: []].insert(userID)
        effectiveScopes[process, default: []].insert(userID)
    }

    /// Restored associations and session roots are proven provenance as well.
    func markRestored(_ userID: UInt32, for process: ProcessIdentity) {
        effectiveScopes[process, default: []].insert(userID)
        provenanceScopes[process, default: []].insert(userID)
    }

    func trim(liveProcesses: Set<ProcessIdentity>) {
        effectiveScopes = effectiveScopes.filter { liveProcesses.contains($0.key) }
        provenanceScopes = provenanceScopes.filter { liveProcesses.contains($0.key) }
    }
}

struct ESProcessVersionKey: Hashable {
    var pid: Int32
    var version: UInt32
}

/// Bounded map from a process instance to its current execution and pidversion lookups.
///
/// Every store retires the replaced version key, an observed exit retires its key, and trimming
/// a process removes all of its mappings. This keeps ordinary fork/exec/exit churn from growing
/// the privileged daemon's index without bound.
struct ESExecutionIndex {
    static let maximumEntries = 65_536
    static let targetEntries = 32_768

    private(set) var latest: [ProcessIdentity: ExecutionRecord] = [:]
    private(set) var byPIDVersion: [ESProcessVersionKey: ExecutionIdentity] = [:]

    var liveProcesses: Set<ProcessIdentity> { Set(latest.keys) }

    mutating func store(_ record: ExecutionRecord) {
        let process = record.identity.process
        if let previous = latest[process], previous.identity != record.identity {
            retire(previous.identity)
        }
        latest[process] = record
        byPIDVersion[ESProcessVersionKey(
            pid: process.pid,
            version: record.identity.version
        )] = record.identity
        trim()
    }

    @discardableResult
    mutating func markExited(_ identity: ExecutionIdentity, at date: Date) -> ExecutionRecord? {
        guard var record = latest[identity.process], record.identity == identity else {
            return nil
        }
        record.state = .exited
        record.endedAt = date
        record.auditToken = nil
        latest[identity.process] = record
        retire(identity)
        return record
    }

    mutating func markRunningUnknown() {
        for process in Array(latest.keys) {
            guard var record = latest[process], record.state == .running else { continue }
            record.state = .unknown
            record.auditToken = nil
            latest[process] = record
        }
    }

    mutating func retire(_ identity: ExecutionIdentity) {
        let key = ESProcessVersionKey(pid: identity.process.pid, version: identity.version)
        if byPIDVersion[key] == identity {
            byPIDVersion.removeValue(forKey: key)
        }
    }

    func identity(pid: Int32, version: UInt32) -> ExecutionIdentity? {
        byPIDVersion[ESProcessVersionKey(pid: pid, version: version)]
    }

    /// Enforces the entry cap. The bounds are injectable so the eviction rules can be verified
    /// without materializing tens of thousands of processes.
    mutating func trim(
        maximum: Int = ESExecutionIndex.maximumEntries,
        target: Int = ESExecutionIndex.targetEntries
    ) {
        var removed = false
        if latest.count > maximum {
            var removable: [ProcessIdentity] = []
            for (process, record) in latest where record.state != .running {
                removable.append(process)
            }
            for process in removable {
                latest.removeValue(forKey: process)
                removed = true
                if latest.count <= target { break }
            }
            if latest.count > maximum {
                latest.removeAll(keepingCapacity: true)
                byPIDVersion.removeAll(keepingCapacity: true)
                return
            }
        }

        let live = Set(latest.keys)
        if removed || byPIDVersion.count > latest.count {
            byPIDVersion = byPIDVersion.filter { _, identity in
                guard live.contains(identity.process) else { return false }
                return latest[identity.process]?.identity == identity
            }
        }
    }
}

/// Callback-state mutex that can bound the authorization path's wait. Non-authorization
/// callers block normally; AUTH fails open if the kernel deadline cannot accommodate a wait.
/// The timed wait uses Dispatch's monotonic clock, so a wall-clock adjustment cannot extend it.
private final class BoundedStateLock {
    private let semaphore = DispatchSemaphore(value: 1)

    func lock() {
        semaphore.wait()
    }

    /// Acquires the lock unless `timeout` elapses first. A nil timeout waits indefinitely; a
    /// non-positive timeout only succeeds when the lock is immediately available.
    func lock(timeout: TimeInterval?) -> Bool {
        guard let timeout else {
            lock()
            return true
        }
        guard timeout > 0 else {
            return semaphore.wait(timeout: .now()) == .success
        }
        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    func unlock() {
        semaphore.signal()
    }
}

/// Owns the real Endpoint Security client, the per-user attribution engines, and the
/// memory-only authorization decision path.
///
/// All callback state is protected by `stateLock`. The ES handler copies message data,
/// never performs filesystem/database/XPC work, and responds to every authorization event
/// before the kernel deadline. Project resolution runs on `projectQueue`; the engine's
/// project resolver only reads a pre-populated memory cache.
final class EndpointSecurityClient: @unchecked Sendable {
    private struct Callbacks: Sendable {
        var activity: @Sendable (UInt32, ActivityRecord) -> Void
        var gap: @Sendable (UInt32, CollectionGap) -> Void
        var graphChanged: @Sendable (UInt32) -> Void
        var healthChanged: @Sendable (UInt32) -> Void
    }

    private final class UserScope {
        var engine: AttributionEngine
        var policy: ESPreparedPolicy
        var activeRevision: Int64?
        var activeMode: MonitoringMode?
        var preparationMessage: String?

        init(
            engine: AttributionEngine,
            policy: ESPreparedPolicy,
            activeRevision: Int64?,
            activeMode: MonitoringMode?,
            preparationMessage: String?
        ) {
            self.engine = engine
            self.policy = policy
            self.activeRevision = activeRevision
            self.activeMode = activeMode
            self.preparationMessage = preparationMessage
        }
    }

    private struct ProjectCacheEntry {
        var project: ProjectRecord?
    }

    private struct AuthActivityMeta {
        var revision: Int64
        var sessionIDs: [String]
        var projectRoot: String?
        var sourcePath: String?
        var targetPath: String?
        var fileIdentity: FileIdentity?
        var detail: String?
    }

    private struct AuthRequest {
        var operation: ProtectedOperation
        var source: ESFileEndpoint
        var target: ESFileEndpoint?
    }

    private let capture: CaptureRecord

    // Lock order is controlLock -> stateLock -> indexLock -> projectLock. lifecycleLock is
    // independent and is never acquired while holding stateLock. The ES handler holds
    // stateLock only while responding, so a configuration install cannot acknowledge a mode
    // whose authorization decision has not been serialized. Graph projection and sorting
    // happen after that region.
    private let controlLock = NSLock()
    private let stateLock = BoundedStateLock()
    private let indexLock = NSLock()
    private let projectLock = NSLock()
    private let lifecycleLock = NSCondition()
    private let projectQueue = DispatchQueue(
        label: "dev.shisheng.Sidewatch.es-projects",
        qos: .utility
    )
    private let notificationQueue = DispatchQueue(
        label: "dev.shisheng.Sidewatch.es-health",
        qos: .utility
    )

    private var callbacks: Callbacks?
    private var cachedCallbacks: Callbacks?
    private var cachedUserIDs: [UInt32] = []
    private var client: OpaquePointer?
    private var activeCallbacks = 0
    private var stopping = false

    private var started = false
    private var availability: MonitorAvailability = .unavailable
    private var statusMessage: String? = "Endpoint Security is not running."
    private var collectionUncertain = false
    private var responseFailureUsers: Set<UInt32> = []

    private var users: [UInt32: UserScope] = [:]
    private var provenance = ESProvenanceIndex()
    private var executionIndex = ESExecutionIndex()
    private var snapshotEnrichedProcesses: Set<ProcessIdentity> = []
    private var lastGlobalSequence: UInt64?
    private var subscribedAuthRaw: Set<UInt32> = []

    private var cwdOwners: [String: Set<UInt32>] = [:]
    private var pendingCwds: Set<String> = []
    private var projectPumpScheduled = false
    private var cachedProjects: [String: ProjectCacheEntry] = [:]

    private static let deadlineMargin: UInt64 = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS,
              info.numer != 0,
              info.denom != 0 else {
            return 0
        }
        // One millisecond in Mach absolute ticks for this architecture.
        return (1_000_000 * UInt64(info.denom)) / UInt64(info.numer)
    }()

    private static let nanosecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS,
              info.numer != 0,
              info.denom != 0 else {
            return 1
        }
        return Double(info.numer) / Double(info.denom)
    }()

    init(capture: CaptureRecord) {
        self.capture = capture
    }

    // MARK: - Installation

    func setCallbacks(
        activity: @escaping @Sendable (UInt32, ActivityRecord) -> Void,
        gap: @escaping @Sendable (UInt32, CollectionGap) -> Void,
        graphChanged: @escaping @Sendable (UInt32) -> Void,
        healthChanged: @escaping @Sendable (UInt32) -> Void
    ) {
        stateLock.lock()
        let value = Callbacks(
            activity: activity,
            gap: gap,
            graphChanged: graphChanged,
            healthChanged: healthChanged
        )
        callbacks = value
        stateLock.unlock()
        indexLock.lock()
        cachedCallbacks = value
        indexLock.unlock()
    }

    func restore(
        _ graph: GraphSnapshot,
        configuration: MonitorConfiguration,
        userID: UInt32
    ) {
        let prepared = Self.prepareForRestoration(configuration)
        let engine = makeEngine(definitions: prepared.configuration.agentDefinitions)
        engine.restore(graph)
        let policy = ESPreparedPolicy(configuration: prepared.configuration)

        do {
            try install(
                policy: policy,
                userID: userID,
                replacementEngine: engine,
                allowInactiveEnforcementStorage: true,
                preparationMessage: prepared.message,
                restoredGraph: graph
            )
        } catch {
            stateLock.lock()
            if let scope = users[userID] {
                scope.preparationMessage = "Protection configuration could not be restored."
            }
            stateLock.unlock()
            publishHealth([userID])
        }
    }

    // MARK: - Lifecycle

    func start() -> MonitorHealth {
        controlLock.lock()
        defer { controlLock.unlock() }

        stateLock.lock()
        if started {
            let health = healthLocked(userID: nil)
            stateLock.unlock()
            return health
        }
        stateLock.unlock()

        var created: OpaquePointer?
        let result = es_new_client(&created) { [weak self] client, message in
            self?.handleMessage(client, message)
        }

        guard result == ES_NEW_CLIENT_RESULT_SUCCESS, let client = created else {
            let failure = Self.startFailure(result)
            stateLock.lock()
            started = false
            // The broker retries while waiting for Full Disk Access; report only changes.
            let changed = availability != failure.availability || statusMessage != failure.message
            availability = failure.availability
            statusMessage = failure.message
            let identifiers = Set(users.keys)
            let health = healthLocked(userID: nil)
            stateLock.unlock()
            if changed {
                publishHealth(identifiers)
                Diagnostics.endpointSecurity.error(
                    "es_new_client failed result=\(result.rawValue)"
                )
            }
            return health
        }

        lifecycleLock.lock()
        self.client = client
        stopping = false
        activeCallbacks = 0
        lifecycleLock.unlock()

        stateLock.lock()
        let targetAuth = Self.requiredAuthRawValues(users.values.map(\.policy))
        let events = Self.notificationEventRawValues().union(targetAuth)
        // A new ES client lifetime has its own global sequence space. Reset before any
        // message can be delivered so the first observed sequence is the baseline.
        lastGlobalSequence = nil
        collectionUncertain = false
        stateLock.unlock()

        guard Self.subscribe(client, rawEvents: events) else {
            teardown(client)

            stateLock.lock()
            started = false
            availability = .unavailable
            statusMessage = "Endpoint Security subscription failed."
            lastGlobalSequence = nil
            markCaptureUncertainLocked()
            let identifiers = Set(users.keys)
            let health = healthLocked(userID: nil)
            stateLock.unlock()
            publishHealth(identifiers)
            Diagnostics.endpointSecurity.error("Endpoint Security event subscription failed")
            return health
        }

        stateLock.lock()
        started = true
        availability = .active
        statusMessage = nil
        subscribedAuthRaw = targetAuth
        for scope in users.values {
            scope.activeRevision = scope.policy.revision
            scope.activeMode = scope.policy.mode
        }
        let identifiers = Set(users.keys)
        let health = healthLocked(userID: nil)
        stateLock.unlock()

        publishHealth(identifiers)
        Diagnostics.endpointSecurity.notice("Endpoint Security client started")
        return health
    }

    func stop() {
        controlLock.lock()
        defer { controlLock.unlock() }

        lifecycleLock.lock()
        let existingClient = client
        lifecycleLock.unlock()
        if let existingClient {
            teardown(existingClient)
        }

        stateLock.lock()
        let wasCollecting = started || existingClient != nil
        started = false
        availability = .unavailable
        statusMessage = "Endpoint Security collection is stopped."
        subscribedAuthRaw = []
        lastGlobalSequence = nil
        collectionUncertain = false
        if wasCollecting {
            for scope in users.values {
                scope.activeRevision = nil
                scope.activeMode = nil
            }
            // A stopped capture cannot prove any execution is still current, so live
            // tokens become unavailable until a fresh observation.
            markCaptureUncertainLocked()
        }
        let identifiers = Set(users.keys)
        stateLock.unlock()

        if wasCollecting {
            deliverGraphChanges(identifiers)
        }
        publishHealth(identifiers)
        Diagnostics.endpointSecurity.notice("Endpoint Security client stopped")
    }

    /// Stops message delivery, waits for every callback that already entered, and only
    /// then calls es_delete_client. New callbacks see a nil client and never touch the
    /// freed pointer.
    private func teardown(_ client: OpaquePointer) {
        lifecycleLock.lock()
        stopping = true
        _ = es_unsubscribe_all(client)
        while activeCallbacks > 0 {
            lifecycleLock.wait()
        }
        self.client = nil
        stopping = false
        lifecycleLock.unlock()
        _ = es_delete_client(client)
    }

    // MARK: - Configuration

    func apply(_ configuration: MonitorConfiguration, userID: UInt32) throws {
        try Self.validate(configuration)
        try install(
            policy: ESPreparedPolicy(configuration: configuration),
            userID: userID,
            replacementEngine: nil,
            allowInactiveEnforcementStorage: false,
            preparationMessage: nil,
            restoredGraph: nil
        )
    }

    private func install(
        policy: ESPreparedPolicy,
        userID: UInt32,
        replacementEngine: AttributionEngine?,
        allowInactiveEnforcementStorage: Bool,
        preparationMessage: String?,
        restoredGraph: GraphSnapshot?
    ) throws {
        controlLock.lock()
        defer { controlLock.unlock() }

        stateLock.lock()
        let isStarted = started
        if !isStarted && !allowInactiveEnforcementStorage && policy.mode != .recordOnly {
            stateLock.unlock()
            throw EndpointSecurityClientError.endpointSecurityInactive
        }

        var candidatePolicies = users.mapValues { $0.policy }
        candidatePolicies[userID] = policy
        let targetAuth = Self.requiredAuthRawValues(Array(candidatePolicies.values))
        let currentAuth = subscribedAuthRaw
        stateLock.unlock()

        var activeClient: OpaquePointer?
        let additions = targetAuth.subtracting(currentAuth)
        let removals = currentAuth.subtracting(targetAuth)
        if isStarted {
            guard let client = currentClient else {
                throw EndpointSecurityClientError.endpointSecurityInactive
            }
            activeClient = client
            if !additions.isEmpty, !Self.subscribe(client, rawEvents: additions) {
                // Roll back additions so no unacknowledged policy can rely on them. Extra
                // subscriptions are harmless; missing ones never become acknowledged.
                _ = Self.unsubscribe(client, rawEvents: additions)
                stateLock.lock()
                subscribedAuthRaw = currentAuth
                stateLock.unlock()
                Diagnostics.endpointSecurity.error("Endpoint Security AUTH subscription failed")
                throw EndpointSecurityClientError.subscriptionFailed
            }
        }

        stateLock.lock()
        let scope: UserScope
        if let existing = users[userID] {
            scope = existing
            if let replacementEngine {
                existing.engine = replacementEngine
            } else {
                existing.engine.configure(definitions: policy.configuration.agentDefinitions)
            }
        } else if let replacementEngine {
            scope = UserScope(
                engine: replacementEngine,
                policy: policy,
                activeRevision: nil,
                activeMode: nil,
                preparationMessage: preparationMessage
            )
            users[userID] = scope
        } else {
            scope = UserScope(
                engine: makeEngine(definitions: policy.configuration.agentDefinitions),
                policy: policy,
                activeRevision: nil,
                activeMode: nil,
                preparationMessage: preparationMessage
            )
            users[userID] = scope
        }

        scope.policy = policy
        scope.preparationMessage = preparationMessage
        if isStarted {
            subscribedAuthRaw = currentAuth.union(additions)
            // The replacement policy remains unconfirmed until its subscription union is
            // installed. AUTH skips unconfirmed scopes, so failed transitions stay allow.
            if removals.isEmpty {
                scope.activeRevision = policy.revision
                scope.activeMode = policy.mode
            } else {
                scope.activeRevision = nil
                scope.activeMode = nil
            }
        } else {
            scope.activeRevision = nil
            scope.activeMode = nil
        }

        if let restoredGraph {
            // Only executions already associated with this user's sessions may propagate
            // the owner scope. Seeding common ancestors (for example launchd) would hand
            // this user's provenance to unrelated future children.
            var relatedProcesses = Set(restoredGraph.associations.map { $0.execution.process })
            for session in restoredGraph.sessions {
                relatedProcesses.insert(session.root.process)
            }
            for record in restoredGraph.executions {
                if relatedProcesses.contains(record.identity.process) {
                    provenance.markRestored(userID, for: record.identity.process)
                }
                noteCwdLocked(record, userID: userID)
            }
            trimProvenanceLocked()
        }
        refreshUserCacheLocked()
        stateLock.unlock()

        var removalSucceeded = true
        if isStarted, let activeClient, !removals.isEmpty {
            removalSucceeded = Self.unsubscribe(activeClient, rawEvents: removals)
            if removalSucceeded {
                stateLock.lock()
                subscribedAuthRaw.subtract(removals)
                scope.activeRevision = policy.revision
                scope.activeMode = policy.mode
                stateLock.unlock()
            }
        }

        if isStarted, let activeClient, removalSucceeded, !removals.isEmpty || !additions.isEmpty {
            // Invalidate cached authorization decisions after the subscription set changes.
            _ = es_clear_cache(activeClient)
        }

        guard removalSucceeded else {
            stateLock.lock()
            scope.preparationMessage = "auth_subscription_failed"
            stateLock.unlock()
            publishHealth([userID])
            Diagnostics.endpointSecurity.error("Endpoint Security AUTH unsubscription failed")
            throw EndpointSecurityClientError.subscriptionFailed
        }

        // A pre-start restore is followed by start(), which publishes fresh health and the
        // parent marks every restored scope graph-dirty. Avoid waking ingestion early.
        if isStarted || restoredGraph == nil {
            deliverGraphChanges([userID])
            publishHealth([userID])
        }
    }

    // MARK: - Retention

    /// Prunes memory-only history after the broker's SQL retention pass.
    ///
    /// The broker calls this while ingestion for `userID` is paused and drained, after it has
    /// cleared/retained storage and read the resulting `retained` graph. Only history that
    /// storage no longer keeps is removed. Live tokens, the current policy, project metadata,
    /// and other user scopes are untouched, and a live engine is never rebuilt from `restore`.
    func retainGraph(_ retained: GraphSnapshot, userID: UInt32, since boundary: Date) {
        stateLock.lock()
        users[userID]?.engine.retain(retained, since: boundary)
        stateLock.unlock()
    }

    // MARK: - Queries

    func graph(userID: UInt32) -> GraphSnapshot {
        stateLock.lock()
        guard let scope = users[userID] else {
            stateLock.unlock()
            return GraphSnapshot()
        }
        // Copying under the callback lock keeps the engine confined; sorting and the repeated
        // ancestry scan happen after the lock so AUTH is not queued behind graph projection.
        let copy = scope.engine.copySnapshot()
        stateLock.unlock()
        return scopedGraph(copy)
    }

    func health(userID: UInt32) -> MonitorHealth {
        stateLock.lock()
        defer { stateLock.unlock() }
        return healthLocked(userID: userID)
    }

    func liveToken(_ identity: ExecutionIdentity, userID: UInt32) -> (Data?, Int32) {
        stateLock.lock()
        guard identity.process.bootID == capture.bootID,
              let record = executionIndex.latest[identity.process],
              record.identity == identity,
              record.state == .running,
              record.evidence == .observed,
              let token = record.auditToken,
              token.count == MemoryLayout<audit_token_t>.size else {
            stateLock.unlock()
            return (nil, ESRCH)
        }
        guard record.userID == userID else {
            stateLock.unlock()
            return (nil, EACCES)
        }
        stateLock.unlock()

        var information = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bytes = proc_pidinfo(
            identity.process.pid,
            PROC_PIDTBSDINFO,
            0,
            &information,
            size
        )
        guard bytes == size else { return (nil, ESRCH) }
        guard information.pbi_pid == UInt32(bitPattern: identity.process.pid),
              information.pbi_status != SZOMB else {
            return (nil, ESRCH)
        }
        let startMicros = Int64(information.pbi_start_tvsec) * 1_000_000
            + Int64(information.pbi_start_tvusec)
        guard startMicros == identity.process.startTimeMicros else {
            return (nil, ESRCH)
        }
        guard information.pbi_uid == userID else {
            return (nil, EACCES)
        }

        // Recheck the exact live execution after the kernel process check. A concurrent
        // exec or exit invalidates the token rather than returning a stale one.
        stateLock.lock()
        guard let current = executionIndex.latest[identity.process],
              current.identity == identity,
              current.state == .running,
              current.evidence == .observed,
              current.userID == userID,
              current.auditToken == token else {
            stateLock.unlock()
            return (nil, ESRCH)
        }
        stateLock.unlock()

        return (token, 0)
    }

    func currentExecution(_ process: ProcessIdentity) -> ExecutionRecord? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard process.bootID == capture.bootID else { return nil }

        var record = executionIndex.latest[process]
        if record == nil || record?.evidence == .snapshot {
            // After a restart, native polling can reinsert a synthetic version-0 placeholder
            // before the first ES message. A user engine already knows the observed version.
            for scope in users.values {
                guard let candidate = scope.engine.currentExecution(for: process),
                      candidate.evidence != .snapshot,
                      candidate.identity.version >= (record?.identity.version ?? 0) else {
                    continue
                }
                record = candidate
            }
        }
        guard var record else { return nil }
        // Tokens are only released through liveToken after a fresh kernel check.
        record.auditToken = nil
        return record
    }

    /// Transient current-execution metadata for the broker's snapshot overlay.
    ///
    /// Returns only records from this boot whose effective UID matches the caller, are running
    /// and observed, and still carry a fresh in-memory audit token. Tokens are stripped here;
    /// signal authorization must still use `liveToken`, which revalidates the exact execution
    /// against the kernel. The index is bounded, so this cannot enumerate unlimited history.
    func liveExecutions(userID: UInt32) -> [ExecutionRecord] {
        stateLock.lock()
        let records = executionIndex.latest.values.filter { $0.userID == userID }
        stateLock.unlock()
        return Self.currentLiveExecutions(
            records,
            userID: userID,
            bootID: capture.bootID
        )
    }

    /// Pure filter used by `liveExecutions` so ownership and token-stripping rules can be
    /// verified without Endpoint Security.
    static func currentLiveExecutions(
        _ records: [ExecutionRecord],
        userID: UInt32,
        bootID: String
    ) -> [ExecutionRecord] {
        let tokenSize = MemoryLayout<audit_token_t>.size
        return records.compactMap { record -> ExecutionRecord? in
            guard record.identity.process.bootID == bootID,
                  record.userID == userID,
                  record.state == .running,
                  record.evidence == .observed,
                  let token = record.auditToken,
                  token.count == tokenSize else {
                return nil
            }
            var stripped = record
            stripped.auditToken = nil
            return stripped
        }
        .sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.identity.stableID < $1.identity.stableID
        }
    }

    func ingestProcessSnapshot(_ records: [ExecutionRecord]) {
        var graphUsers: Set<UInt32> = []

        stateLock.lock()
        let callbacks = self.callbacks
        // Parents first so a child's inferred ancestry can resolve within this snapshot.
        let ordered = records.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            if $0.identity.process.pid != $1.identity.process.pid {
                return $0.identity.process.pid < $1.identity.process.pid
            }
            return $0.identity.stableID < $1.identity.stableID
        }
        for original in ordered {
            guard original.identity.process.bootID == capture.bootID else { continue }
            // A native snapshot cannot confirm an ES exit. Only live/unknown processes are
            // admitted, and an observed ES identity is never overwritten by version 0.
            guard original.state != .exited else { continue }
            let process = original.identity.process
            let observed = executionIndex.latest[process]
            if let observed {
                if observed.evidence == .snapshot { continue }
                if snapshotEnrichedProcesses.contains(process) { continue }
                // ES process data has no argv, so a node/bun script agent first seen by an ES
                // event is not recognizable. A snapshot can supply that metadata once; if
                // argv is already known, it adds nothing.
                if !observed.arguments.isEmpty { continue }
            }

            var record = original
            record.auditToken = nil
            record.evidence = .snapshot

            let owners = provenance.scopes(for: process)
                ?? provenance.owners(for: process, userID: record.userID, parent: record.parent)
            let relatedIdentity = observed?.identity ?? record.identity
            for userID in owners {
                // Only users with a restored/applied scope have an engine and store.
                guard let scope = users[userID] else { continue }
                scope.engine.observe(record, kind: nil, at: Date())
                if let observed {
                    // Link the snapshot-derived attribution onto the live identity without
                    // creating an exec edge or a second root.
                    _ = scope.engine.adoptObserved(observed)
                }
                if scope.engine.isRelated(relatedIdentity) {
                    provenance.markProvenance(userID, for: process)
                    graphUsers.insert(userID)
                }
                noteCwdLocked(record, userID: userID)
            }

            if let observed {
                snapshotEnrichedProcesses.insert(process)
                var enriched = observed
                if enriched.arguments.isEmpty { enriched.arguments = record.arguments }
                if enriched.workingDirectory == nil {
                    enriched.workingDirectory = record.workingDirectory
                }
                if enriched.parent == nil { enriched.parent = record.parent }
                if enriched.responsible == nil { enriched.responsible = record.responsible }
                storeLatestLocked(enriched)
            } else {
                storeLatestLocked(record)
            }
        }
        stateLock.unlock()

        deliver(
            activities: [],
            gaps: [],
            graphUsers: graphUsers,
            healthUsers: [],
            callbacks: callbacks
        )
    }

    func userIDs() -> [UInt32] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return users.keys.sorted()
    }

    // MARK: - Endpoint Security handler

    private func handleMessage(_ client: OpaquePointer, _ message: UnsafePointer<es_message_t>) {
        lifecycleLock.lock()
        guard self.client != nil else {
            lifecycleLock.unlock()
            return
        }
        if stopping {
            // Drain teardown messages without touching graph state. The callback is still
            // counted so es_delete_client cannot race this response.
            activeCallbacks += 1
            lifecycleLock.unlock()
            defer { finishedCallback() }
            respondDuringStop(client, message)
            return
        }
        activeCallbacks += 1
        lifecycleLock.unlock()
        defer { finishedCallback() }

        if Self.isAuthorizationEventType(message.pointee.event_type) {
            let decoded = ESMessageDecoder.decode(message, bootID: capture.bootID)
            processAuthorization(client: client, message: message, decoded: decoded)
        } else {
            let decoded = ESMessageDecoder.decode(message, bootID: capture.bootID)
            processNotification(decoded: decoded)
        }
    }

    private func finishedCallback() {
        lifecycleLock.lock()
        if activeCallbacks > 0 {
            activeCallbacks -= 1
        }
        lifecycleLock.broadcast()
        lifecycleLock.unlock()
    }

    // MARK: - Authorization

    private func processAuthorization(
        client: OpaquePointer,
        message: UnsafePointer<es_message_t>,
        decoded: ESDecodedMessage
    ) {
        let budget = authorizationBudget(message)

        // Acquisition is bounded by the kernel deadline. If the graph mutex is busy, the only
        // safe outcome is one fail-open response plus a truthful gap; never wait past the
        // deadline for a graph query or a configuration scan.
        guard stateLock.lock(timeout: budget.timeout) else {
            respondWithoutAuthorizationLock(client: client, message: message, decoded: decoded)
            return
        }

        var activities: [(UInt32, ActivityRecord)] = []
        var gaps: [(UInt32, CollectionGap)] = []
        var graphUsers: Set<UInt32> = []
        var healthUsers: Set<UInt32> = []
        let callbacks = self.callbacks

        let identity = decoded.process.identity
        let occurredAt = decoded.occurredAt
        var failOpen = !hasBudget(budget)

        var owners: Set<UInt32> = []
        if !failOpen {
            // Native polling can install a startup agent with synthetic version 0. Reconcile
            // it to this exact live execution before ownership or rule decisions run. With no
            // budget left, skip all graph mutation and answer immediately.
            adoptObservedProcessLocked(decoded.process, at: occurredAt, graphUsers: &graphUsers)
            owners = provenance.scopes(for: identity.process) ?? []
        }
        let request = authorizationRequest(from: decoded.payload)
        var pending: [(ESAuthScopeDecision, AuthActivityMeta)] = []
        var evaluatedTruncatedUsers: Set<UInt32> = []

        if let request, !failOpen {
            for userID in owners.sorted() {
                if !hasBudget(budget) {
                    failOpen = true
                    break
                }
                guard let scope = users[userID],
                      scope.policy.mode != .recordOnly,
                      scope.activeRevision == scope.policy.revision,
                      scope.activeMode == scope.policy.mode,
                      scope.engine.isRelated(identity) else {
                    continue
                }
                let agentIDs = scope.engine.agents(for: identity)
                guard !agentIDs.isEmpty else { continue }

                let decision = scope.policy.decide(
                    operation: request.operation,
                    sourcePath: request.source.path,
                    sourceTruncated: request.source.truncated,
                    targetPath: request.target?.path,
                    targetTruncated: request.target?.truncated ?? false,
                    fileIdentity: request.source.identity,
                    targetFileIdentity: request.target?.identity,
                    agentIDs: agentIDs
                )
                if request.source.truncated || (request.target?.truncated ?? false) {
                    evaluatedTruncatedUsers.insert(userID)
                }
                guard decision.evaluation == .deny else { continue }

                let meta = AuthActivityMeta(
                    revision: scope.policy.revision,
                    sessionIDs: scope.engine.sessionIDs(for: identity),
                    projectRoot: projectRootLocked(userID: userID, identity: identity),
                    sourcePath: request.source.path.isEmpty ? nil : request.source.path,
                    targetPath: request.target.flatMap { $0.path.isEmpty ? nil : $0.path },
                    fileIdentity: request.source.identity,
                    detail: detailText(
                        extra: nil,
                        truncated: request.source.truncated
                            || (request.target?.truncated ?? false)
                    )
                )
                pending.append((
                    ESAuthScopeDecision(
                        userID: userID,
                        mode: scope.policy.mode,
                        evaluation: decision.evaluation,
                        shouldDeny: decision.shouldDeny,
                        matchedRuleIDs: decision.matchedRuleIDs
                    ),
                    meta
                ))
            }
        }

        // Final budget check: evaluation work above may have consumed the remaining margin.
        if !failOpen, !hasBudget(budget) {
            failOpen = true
        }

        if failOpen {
            // No complete evaluation was possible. Fail open exactly once; partial decisions
            // must not deny (or record a result) the kernel never waited for.
            pending.removeAll()
            evaluatedTruncatedUsers.removeAll()
            let affected = owners.isEmpty ? Set(cachedUserIdentifiers()) : owners
            let gap = CollectionGap(
                captureID: capture.id,
                occurredAt: occurredAt,
                reason: "authorizationDeadlineExceeded",
                missingCount: nil
            )
            for userID in affected {
                gaps.append((userID, gap))
                healthUsers.insert(userID)
            }
        } else if request != nil {
            let gap = CollectionGap(
                captureID: capture.id,
                occurredAt: occurredAt,
                reason: "truncatedPath",
                missingCount: nil
            )
            for userID in evaluatedTruncatedUsers {
                gaps.append((userID, gap))
            }
        }

        let requested = ESAuthPlanner.requestedResponse(pending.map(\.0))
        // The response is issued while stateLock is held. Configuration installs take the
        // same lock before becoming visible, so no authorization can deny under a Protect
        // snapshot after a Record Only configuration has been acknowledged.
        let respondResult = respondAuthorization(
            client: client,
            message: message,
            deny: requested == .deny
        )
        let succeeded = respondResult == ES_RESPOND_RESULT_SUCCESS
        if succeeded {
            responseFailureUsers.subtract(owners)
        } else {
            // A response failure is real regardless of whether any rule matched or an allow
            // was sent. Record it as a gap and an operational health failure for every scope
            // that could be affected; never pretend the Allow was delivered.
            let affected = owners.isEmpty ? Set(cachedUserIdentifiers()) : owners
            let gap = CollectionGap(
                captureID: capture.id,
                occurredAt: occurredAt,
                reason: "authorizationResponseFailed",
                missingCount: nil
            )
            for userID in affected {
                gaps.append((userID, gap))
                healthUsers.insert(userID)
            }
            responseFailureUsers.formUnion(affected)
        }

        let resolution = ESAuthPlanner.resolve(pending.map(\.0), responseSucceeded: succeeded)
        var metaByUser: [UInt32: AuthActivityMeta] = [:]
        for entry in pending {
            metaByUser[entry.0.userID] = entry.1
        }
        for record in resolution.records {
            guard let meta = metaByUser[record.userID] else { continue }
            let activity = ActivityRecord(
                captureID: capture.id,
                sourceSequence: decoded.globalSequence,
                execution: identity,
                occurredAt: occurredAt,
                kind: .authorization,
                sourcePath: meta.sourcePath,
                targetPath: meta.targetPath,
                fileIdentity: meta.fileIdentity,
                projectRoot: meta.projectRoot,
                sessionIDs: meta.sessionIDs,
                evidence: .observed,
                configurationRevision: meta.revision,
                mode: record.mode,
                evaluation: record.evaluation,
                response: record.response,
                matchedRuleIDs: record.matchedRuleIDs,
                detail: meta.detail
            )
            activities.append((record.userID, activity))
        }

        // Gap bookkeeping runs after the kernel response so a slow sequence repair can
        // never delay an authorization deadline.
        appendSequenceGapsLocked(
            decoded,
            gaps: &gaps,
            graphUsers: &graphUsers,
            healthUsers: &healthUsers
        )

        stateLock.unlock()

        deliver(
            activities: activities,
            gaps: gaps,
            graphUsers: graphUsers,
            healthUsers: healthUsers,
            callbacks: callbacks
        )
    }

    /// Fail-open path used when the authorization serialization boundary cannot be acquired
    /// before the deadline. It responds once and records gaps from lock-free caches only.
    private func respondWithoutAuthorizationLock(
        client: OpaquePointer,
        message: UnsafePointer<es_message_t>,
        decoded: ESDecodedMessage
    ) {
        let result = respondAuthorization(client: client, message: message, deny: false)
        let users = cachedUserIdentifiers()
        var gaps: [(UInt32, CollectionGap)] = []
        let deadlineGap = CollectionGap(
            captureID: capture.id,
            occurredAt: decoded.occurredAt,
            reason: "authorizationDeadlineExceeded",
            missingCount: nil
        )
        for userID in users {
            gaps.append((userID, deadlineGap))
        }
        if result != ES_RESPOND_RESULT_SUCCESS {
            let failureGap = CollectionGap(
                captureID: capture.id,
                occurredAt: decoded.occurredAt,
                reason: "authorizationResponseFailed",
                missingCount: nil
            )
            for userID in users {
                gaps.append((userID, failureGap))
            }
        }
        deliver(
            activities: [],
            gaps: gaps,
            graphUsers: [],
            healthUsers: Set(users),
            callbacks: cachedCallbacksValue()
        )
    }

    private func authorizationRequest(from payload: ESMessagePayload) -> AuthRequest? {
        switch payload {
        case .authOpen(let endpoint):
            return AuthRequest(operation: .open, source: endpoint, target: nil)
        case .authUnlink(let endpoint):
            return AuthRequest(operation: .delete, source: endpoint, target: nil)
        case .authRename(let source, let target):
            return AuthRequest(operation: .rename, source: source, target: target)
        default:
            return nil
        }
    }

    private struct AuthorizationBudget {
        /// Monotonic Mach-tick limit (margin already applied) for evaluation checks.
        var tickLimit: UInt64?
        /// Remaining monotonic seconds available for the bounded mutex wait.
        var timeout: TimeInterval?
    }

    /// Deadline for this authorization message. Both a wall-clock and a monotonic limit are
    /// captured; evaluation uses the monotonic one so a clock adjustment cannot extend the
    /// kernel's deadline. No kernel deadline yields no budget limit.
    private func authorizationBudget(
        _ message: UnsafePointer<es_message_t>
    ) -> AuthorizationBudget {
        let deadline = message.pointee.deadline
        guard deadline != 0 else {
            return AuthorizationBudget(tickLimit: nil, timeout: nil)
        }
        let now = mach_absolute_time()
        guard deadline > now, deadline - now > Self.deadlineMargin else {
            return AuthorizationBudget(tickLimit: 0, timeout: 0)
        }
        let tickLimit = deadline - Self.deadlineMargin
        let seconds = Double(tickLimit - now)
            * Self.nanosecondsPerTick / 1_000_000_000
        return AuthorizationBudget(tickLimit: tickLimit, timeout: seconds)
    }

    private func hasBudget(_ budget: AuthorizationBudget) -> Bool {
        guard let tickLimit = budget.tickLimit else { return true }
        return mach_absolute_time() < tickLimit
    }

    @discardableResult
    private func respondAuthorization(
        client: OpaquePointer,
        message: UnsafePointer<es_message_t>,
        deny: Bool
    ) -> es_respond_result_t {
        if message.pointee.event_type == ES_EVENT_TYPE_AUTH_OPEN {
            // AUTH_OPEN is a flags event: 0 denies every requested flag, UINT32_MAX allows.
            return es_respond_flags_result(
                client,
                message,
                deny ? 0 : UInt32.max,
                false
            )
        }
        return es_respond_auth_result(
            client,
            message,
            deny ? ES_AUTH_RESULT_DENY : ES_AUTH_RESULT_ALLOW,
            false
        )
    }

    private func respondDuringStop(
        _ client: OpaquePointer,
        _ message: UnsafePointer<es_message_t>
    ) {
        let type = message.pointee.event_type
        if type == ES_EVENT_TYPE_AUTH_OPEN {
            _ = es_respond_flags_result(client, message, UInt32.max, false)
        } else if Self.isAuthorizationEventType(type) {
            _ = es_respond_auth_result(client, message, ES_AUTH_RESULT_ALLOW, false)
        }
    }

    // MARK: - Notifications

    private func processNotification(decoded: ESDecodedMessage) {
        var activities: [(UInt32, ActivityRecord)] = []
        var gaps: [(UInt32, CollectionGap)] = []
        var graphUsers: Set<UInt32> = []
        var healthUsers: Set<UInt32> = []

        stateLock.lock()
        appendSequenceGapsLocked(
            decoded,
            gaps: &gaps,
            graphUsers: &graphUsers,
            healthUsers: &healthUsers
        )

        let occurredAt = decoded.occurredAt
        let sequence = decoded.globalSequence
        let callbacks = self.callbacks

        // Native polling can install synthetic version-0 identities. Promote the process to
        // this exact live observation before any fork/exec/file/exit decision.
        adoptObservedProcessLocked(decoded.process, at: occurredAt, graphUsers: &graphUsers)

        switch decoded.payload {
        case .fork(let child):
            let parentSnapshot = decoded.process
            let previousParent = knownRecordLocked(for: parentSnapshot.identity)
            let resolvedParent = resolveIdentity(parentSnapshot.parentToken)
            let parentParent = previousParent?.parent ?? resolvedParent
            let parentRecord = makeRecord(
                parentSnapshot,
                parent: parentParent,
                responsible: previousParent?.responsible
                    ?? resolveIdentity(parentSnapshot.responsibleToken),
                arguments: previousParent?.arguments ?? [],
                workingDirectory: previousParent?.workingDirectory
            )
            let owners = provenance.owners(
                for: parentSnapshot.identity.process,
                userID: parentSnapshot.userID,
                parent: parentParent
            )
            for userID in owners {
                guard let scope = users[userID] else { continue }
                if needsProcessObservationLocked(scope, identity: parentRecord.identity) {
                    scope.engine.observe(parentRecord, kind: nil, at: occurredAt)
                }
                if scope.engine.isRelated(parentRecord.identity) {
                    provenance.markProvenance(userID, for: parentSnapshot.identity.process)
                }
                noteCwdLocked(parentRecord, userID: userID)
            }
            storeLatestLocked(parentRecord)

            let childRecord = makeRecord(
                child,
                parent: parentSnapshot.identity,
                responsible: resolveIdentity(child.responsibleToken)
                    ?? parentRecord.responsible,
                arguments: parentRecord.arguments,
                workingDirectory: parentRecord.workingDirectory
            )
            // A child inherits only established agent provenance. A process that merely
            // dispatched under its own euid does not hand that scope to its descendants.
            let childOwners = provenance.owners(
                for: child.identity.process,
                userID: child.userID,
                parent: parentSnapshot.identity
            )
            for userID in childOwners {
                guard let scope = users[userID] else { continue }
                scope.engine.observe(childRecord, kind: .fork, at: occurredAt)
                noteCwdLocked(childRecord, userID: userID)
                guard scope.engine.isRelated(child.identity) else { continue }
                provenance.markProvenance(userID, for: child.identity.process)
                activities.append((
                    userID,
                    makeProcessActivity(
                        kind: .fork,
                        scope: scope,
                        identity: child.identity,
                        occurredAt: occurredAt,
                        sequence: sequence
                    )
                ))
                graphUsers.insert(userID)
            }
            storeLatestLocked(childRecord)

        case .exec(let target, let arguments, let workingDirectory):
            let previous = knownRecordLocked(for: decoded.process.identity)
            let resolvedParent = resolveIdentity(decoded.process.parentToken)
            let parentIdentity = previous?.parent ?? resolvedParent
            let preExecRecord = makeRecord(
                decoded.process,
                parent: parentIdentity,
                responsible: previous?.responsible
                    ?? resolveIdentity(decoded.process.responsibleToken),
                arguments: previous?.arguments ?? [],
                workingDirectory: previous?.workingDirectory
            )
            let owners = provenance.owners(
                for: decoded.process.identity.process,
                userID: decoded.process.userID,
                parent: parentIdentity
            )
            for userID in owners {
                guard let scope = users[userID] else { continue }
                if needsProcessObservationLocked(scope, identity: preExecRecord.identity) {
                    scope.engine.observe(preExecRecord, kind: nil, at: occurredAt)
                }
                if scope.engine.isRelated(preExecRecord.identity) {
                    provenance.markProvenance(userID, for: preExecRecord.identity.process)
                }
                noteCwdLocked(preExecRecord, userID: userID)
            }
            storeLatestLocked(preExecRecord)

            var targetRecord = makeRecord(
                target,
                parent: parentIdentity,
                responsible: resolveIdentity(target.responsibleToken)
                    ?? previous?.responsible,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
            // `process.start_time` is the process creation time. An exec creates a new
            // execution within the same process, so its real start is this observed event.
            // Later metadata-only observations preserve the stored value.
            targetRecord.startedAt = occurredAt
            // An exec keeps the process's established provenance across effective-UID
            // changes; without provenance, the target's own euid establishes the scope.
            let targetOwners = provenance.owners(
                for: target.identity.process,
                userID: target.userID,
                parent: decoded.process.identity
            )
            for userID in targetOwners {
                guard let scope = users[userID] else { continue }
                scope.engine.observe(targetRecord, kind: .exec, at: occurredAt)
                noteCwdLocked(targetRecord, userID: userID)
                guard scope.engine.isRelated(target.identity) else { continue }
                provenance.markProvenance(userID, for: target.identity.process)
                activities.append((
                    userID,
                    makeProcessActivity(
                        kind: .exec,
                        scope: scope,
                        identity: target.identity,
                        occurredAt: occurredAt,
                        sequence: sequence
                    )
                ))
                graphUsers.insert(userID)
            }
            storeLatestLocked(targetRecord)

        case .exit:
            let identity = decoded.process.identity
            var owners = provenance.scopes(for: identity.process) ?? []
            // Restored ancestors may be present in a user's graph without having
            // propagated an owner scope. Their observed exit still closes that record.
            for (userID, scope) in users where scope.engine.execution(for: identity) != nil {
                owners.insert(userID)
            }
            for userID in owners {
                guard let scope = users[userID] else { continue }
                let existed = scope.engine.execution(for: identity) != nil
                let related = scope.engine.isRelated(identity)
                scope.engine.exit(identity, at: occurredAt)
                if existed || related {
                    graphUsers.insert(userID)
                }
                guard related else { continue }
                activities.append((
                    userID,
                    makeProcessActivity(
                        kind: .exit,
                        scope: scope,
                        identity: identity,
                        occurredAt: occurredAt,
                        sequence: sequence
                    )
                ))
            }
            if executionIndex.latest[identity.process] == nil,
               let restored = knownRecordLocked(for: identity) {
                // The process predates this capture. The exit is still an observed fact,
                // so currentExecution can join it without inventing an exec event.
                storeLatestLocked(restored)
            }
            markExitedLocked(identity, at: occurredAt)

        case .open(let endpoint):
            appendFileActivityLocked(
                kind: .open,
                identity: decoded.process.identity,
                occurredAt: occurredAt,
                sequence: sequence,
                source: endpoint,
                target: nil,
                extraDetail: nil,
                process: decoded.process,
                owners: provenance.scopes(for: decoded.process.identity.process) ?? [],
                activities: &activities,
                gaps: &gaps,
                graphUsers: &graphUsers
            )

        case .create(let endpoint):
            appendFileActivityLocked(
                kind: .create,
                identity: decoded.process.identity,
                occurredAt: occurredAt,
                sequence: sequence,
                source: endpoint,
                target: nil,
                extraDetail: nil,
                process: decoded.process,
                owners: provenance.scopes(for: decoded.process.identity.process) ?? [],
                activities: &activities,
                gaps: &gaps,
                graphUsers: &graphUsers
            )

        case .write(let endpoint):
            appendFileActivityLocked(
                kind: .write,
                identity: decoded.process.identity,
                occurredAt: occurredAt,
                sequence: sequence,
                source: endpoint,
                target: nil,
                extraDetail: nil,
                process: decoded.process,
                owners: provenance.scopes(for: decoded.process.identity.process) ?? [],
                activities: &activities,
                gaps: &gaps,
                graphUsers: &graphUsers
            )

        case .closeModified(let endpoint):
            appendFileActivityLocked(
                kind: .write,
                identity: decoded.process.identity,
                occurredAt: occurredAt,
                sequence: sequence,
                source: endpoint,
                target: nil,
                extraDetail: "modifiedClose",
                process: decoded.process,
                owners: provenance.scopes(for: decoded.process.identity.process) ?? [],
                activities: &activities,
                gaps: &gaps,
                graphUsers: &graphUsers
            )

        case .rename(let source, let target):
            appendFileActivityLocked(
                kind: .rename,
                identity: decoded.process.identity,
                occurredAt: occurredAt,
                sequence: sequence,
                source: source,
                target: target,
                extraDetail: nil,
                process: decoded.process,
                owners: provenance.scopes(for: decoded.process.identity.process) ?? [],
                activities: &activities,
                gaps: &gaps,
                graphUsers: &graphUsers
            )

        case .unlink(let endpoint):
            appendFileActivityLocked(
                kind: .unlink,
                identity: decoded.process.identity,
                occurredAt: occurredAt,
                sequence: sequence,
                source: endpoint,
                target: nil,
                extraDetail: nil,
                process: decoded.process,
                owners: provenance.scopes(for: decoded.process.identity.process) ?? [],
                activities: &activities,
                gaps: &gaps,
                graphUsers: &graphUsers
            )

        case .authOpen, .authUnlink, .authRename, .unsupported:
            break
        }

        stateLock.unlock()

        deliver(
            activities: activities,
            gaps: gaps,
            graphUsers: graphUsers,
            healthUsers: healthUsers,
            callbacks: callbacks
        )
    }

    private func appendFileActivityLocked(
        kind: ActivityKind,
        identity: ExecutionIdentity,
        occurredAt: Date,
        sequence: UInt64?,
        source: ESFileEndpoint,
        target: ESFileEndpoint?,
        extraDetail: String?,
        process: ESProcessSnapshot,
        owners: Set<UInt32>,
        activities: inout [(UInt32, ActivityRecord)],
        gaps: inout [(UInt32, CollectionGap)],
        graphUsers: inout Set<UInt32>
    ) {
        let truncated = source.truncated || (target?.truncated ?? false)
        for userID in owners {
            guard let scope = users[userID] else { continue }

            // A restored or gap-interrupted execution becomes live again on its first
            // related file event. This is a one-time state refresh per process, not work
            // on every file event.
            if let existing = scope.engine.execution(for: identity),
               existing.state == .unknown || existing.evidence != .observed {
                let known = knownRecordLocked(for: identity) ?? existing
                let refreshed = makeRecord(
                    process,
                    parent: known.parent,
                    responsible: resolveIdentity(process.responsibleToken) ?? known.responsible,
                    arguments: known.arguments,
                    workingDirectory: known.workingDirectory
                )
                scope.engine.observe(refreshed, kind: nil, at: occurredAt)
                storeLatestLocked(refreshed)
                graphUsers.insert(userID)
            }

            guard scope.engine.isRelated(identity) else { continue }
            let activity = ActivityRecord(
                captureID: capture.id,
                sourceSequence: sequence,
                execution: identity,
                occurredAt: occurredAt,
                kind: kind,
                sourcePath: source.path.isEmpty ? nil : source.path,
                targetPath: target.flatMap { $0.path.isEmpty ? nil : $0.path },
                fileIdentity: source.identity,
                projectRoot: projectRootLocked(userID: userID, identity: identity),
                sessionIDs: scope.engine.sessionIDs(for: identity),
                evidence: .observed,
                configurationRevision: scope.policy.revision,
                mode: scope.policy.mode,
                detail: detailText(extra: extraDetail, truncated: truncated)
            )
            activities.append((userID, activity))
            if truncated {
                gaps.append((
                    userID,
                    CollectionGap(
                        captureID: capture.id,
                        occurredAt: occurredAt,
                        reason: "truncatedPath",
                        missingCount: nil
                    )
                ))
            }
        }
    }

    private func makeProcessActivity(
        kind: ActivityKind,
        scope: UserScope,
        identity: ExecutionIdentity,
        occurredAt: Date,
        sequence: UInt64?
    ) -> ActivityRecord {
        // The user's engine owns this method's scope; project lookup is memory-only.
        let projectRoot: String?
        if let project = scope.engine.project(for: identity) {
            projectRoot = project.root
        } else if let record = scope.engine.execution(for: identity),
                  let cwd = record.workingDirectory {
            projectRoot = cachedProject(cwd)?.root
        } else {
            projectRoot = nil
        }
        return ActivityRecord(
            captureID: capture.id,
            sourceSequence: sequence,
            execution: identity,
            occurredAt: occurredAt,
            kind: kind,
            projectRoot: projectRoot,
            sessionIDs: scope.engine.sessionIDs(for: identity),
            evidence: .observed,
            configurationRevision: scope.policy.revision,
            mode: scope.policy.mode,
            detail: nil
        )
    }

    // MARK: - Sequence gaps and uncertainty

    private func appendSequenceGapsLocked(
        _ decoded: ESDecodedMessage,
        gaps: inout [(UInt32, CollectionGap)],
        graphUsers: inout Set<UInt32>,
        healthUsers: inout Set<UInt32>
    ) {
        guard let sequence = decoded.globalSequence else { return }

        if let previous = lastGlobalSequence,
           sequence > previous,
           sequence - previous > 1 {
            let missing = sequence - previous - 1
            collectionUncertain = true
            markCaptureUncertainLocked()
            let gap = CollectionGap(
                captureID: capture.id,
                occurredAt: decoded.occurredAt,
                reason: "sequenceGap",
                missingCount: missing
            )
            for userID in users.keys {
                gaps.append((userID, gap))
                graphUsers.insert(userID)
                healthUsers.insert(userID)
            }
        }

        if lastGlobalSequence == nil || sequence > (lastGlobalSequence ?? 0) {
            lastGlobalSequence = sequence
        }
    }

    private func markCaptureUncertainLocked() {
        for scope in users.values {
            scope.engine.markUnknown()
        }
        executionIndex.markRunningUnknown()
    }

    // MARK: - Scope routing

    /// Reconciles a process previously reported by native polling (synthetic version 0) with
    /// this exact live observation. The snapshot record stays as the canonical session root;
    /// the live identity receives the fresh token and copied attribution. Returns the identity
    /// carried by the current message.
    @discardableResult
    private func adoptObservedProcessLocked(
        _ snapshot: ESProcessSnapshot,
        at occurredAt: Date,
        graphUsers: inout Set<UInt32>
    ) -> ExecutionIdentity {
        let process = snapshot.identity.process
        let identity = snapshot.identity
        let known = executionIndex.latest[process]
        if let known {
            if known.identity == identity { return identity }
            // Only a snapshot-only placeholder is reconciled here. Another observed version
            // is authoritative and must not be overwritten by a stale notification.
            guard known.evidence == .snapshot else { return identity }
        }

        let parent = liveIdentityLocked(known?.parent)
            ?? liveIdentityLocked(resolveIdentity(snapshot.parentToken))
        let responsible = liveIdentityLocked(resolveIdentity(snapshot.responsibleToken))
            ?? liveIdentityLocked(known?.responsible)
        let record = makeRecord(
            snapshot,
            parent: parent,
            responsible: responsible,
            arguments: known?.arguments ?? [],
            workingDirectory: known?.workingDirectory
        )

        let owners = provenance.scopes(for: process)
            ?? provenance.owners(for: process, userID: snapshot.userID, parent: parent)
        for userID in owners {
            guard let scope = users[userID] else { continue }
            if !scope.engine.adoptObserved(record) {
                // No snapshot identity is known to this engine (for example a process that
                // predates this capture without native polling): observe it directly.
                scope.engine.observe(record, kind: nil, at: occurredAt)
            }
            if scope.engine.isRelated(identity) {
                provenance.markProvenance(userID, for: process)
                graphUsers.insert(userID)
            }
        }
        storeLatestLocked(record)
        return identity
    }

    /// Maps a stale synthetic parent identity to the process's current live identity when the
    /// snapshot placeholder has already been reconciled.
    private func liveIdentityLocked(_ identity: ExecutionIdentity?) -> ExecutionIdentity? {
        guard let identity else { return nil }
        if let latest = executionIndex.latest[identity.process],
           latest.identity != identity,
           latest.evidence != .snapshot {
            return latest.identity
        }
        return identity
    }

    private func refreshUserCacheLocked() {
        let identifiers = users.keys.sorted()
        indexLock.lock()
        cachedUserIDs = identifiers
        indexLock.unlock()
    }

    private func cachedUserIdentifiers() -> [UInt32] {
        indexLock.lock()
        defer { indexLock.unlock() }
        return cachedUserIDs
    }

    private func cachedCallbacksValue() -> Callbacks? {
        indexLock.lock()
        defer { indexLock.unlock() }
        return cachedCallbacks
    }

    private func resolveIdentity(_ token: ESProcessTokenIdentity?) -> ExecutionIdentity? {
        guard let token else { return nil }
        return executionIndex.identity(pid: token.pid, version: token.version)
    }

    /// An existing, directly observed running record does not need to be re-observed.
    /// This keeps fork/exec from paying the engine's inferred-parent scan per event.
    private func needsProcessObservationLocked(
        _ scope: UserScope,
        identity: ExecutionIdentity
    ) -> Bool {
        guard let existing = scope.engine.execution(for: identity) else {
            return true
        }
        return existing.state == .unknown || existing.evidence != .observed
    }

    /// Finds the best known record for an exact execution identity. Live ES state wins;
    /// otherwise a restored per-user engine supplies preserved argv/cwd metadata.
    private func knownRecordLocked(for identity: ExecutionIdentity) -> ExecutionRecord? {
        if let record = executionIndex.latest[identity.process], record.identity == identity {
            return record
        }
        for scope in users.values {
            if let record = scope.engine.execution(for: identity) {
                return record
            }
        }
        return nil
    }

    private func makeRecord(
        _ snapshot: ESProcessSnapshot,
        parent: ExecutionIdentity?,
        responsible: ExecutionIdentity?,
        arguments: [String],
        workingDirectory: String?
    ) -> ExecutionRecord {
        ExecutionRecord(
            identity: snapshot.identity,
            parent: parent,
            responsible: responsible,
            parentPID: snapshot.parentPID,
            userID: snapshot.userID,
            executable: snapshot.executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            signingID: snapshot.signingID,
            teamID: snapshot.teamID,
            startedAt: snapshot.startedAt,
            endedAt: nil,
            state: .running,
            evidence: .observed,
            auditToken: snapshot.auditToken
        )
    }

    private func storeLatestLocked(_ record: ExecutionRecord) {
        executionIndex.store(record)
        trimProvenanceLocked()
    }

    private func markExitedLocked(_ identity: ExecutionIdentity, at date: Date) {
        executionIndex.markExited(identity, at: date)
        snapshotEnrichedProcesses.remove(identity.process)
    }

    /// Provenance entries are only meaningful while their process instance is tracked. They
    /// are capped independently so long lived captures cannot grow them without bound.
    private func trimProvenanceLocked() {
        if provenance.processCount > ESExecutionIndex.maximumEntries {
            provenance.trim(liveProcesses: executionIndex.liveProcesses)
        }
        if snapshotEnrichedProcesses.count > ESExecutionIndex.maximumEntries {
            snapshotEnrichedProcesses.formIntersection(executionIndex.liveProcesses)
        }
    }

    // MARK: - Projects

    private func makeEngine(definitions: [AgentDefinition]) -> AttributionEngine {
        AttributionEngine(
            projectResolver: { [weak self] cwd in
                self?.cachedProject(cwd)
            },
            definitions: definitions
        )
    }

    private func cachedProject(_ cwd: String?) -> ProjectRecord? {
        guard let cwd, !cwd.isEmpty else { return nil }
        projectLock.lock()
        defer { projectLock.unlock() }
        return cachedProjects[cwd]?.project
    }

    private func noteCwdLocked(_ record: ExecutionRecord, userID: UInt32) {
        guard let cwd = record.workingDirectory, !cwd.isEmpty else { return }
        if cwdOwners.count > 16_384 {
            cwdOwners.removeAll(keepingCapacity: true)
        }
        cwdOwners[cwd, default: []].insert(userID)
        requestProjectResolution(cwd)
    }

    private func requestProjectResolution(_ cwd: String) {
        guard !cwd.isEmpty else { return }
        projectLock.lock()
        if cachedProjects[cwd] != nil {
            projectLock.unlock()
            return
        }
        let schedule: Bool
        if pendingCwds.insert(cwd).inserted {
            schedule = !projectPumpScheduled
            if schedule {
                projectPumpScheduled = true
            }
        } else {
            schedule = false
        }
        projectLock.unlock()

        if schedule {
            projectQueue.async { [weak self] in
                self?.drainProjectQueue()
            }
        }
    }

    private func drainProjectQueue() {
        var resolvedInBatch = 0
        while resolvedInBatch < 128 {
            projectLock.lock()
            guard let cwd = pendingCwds.first else {
                projectPumpScheduled = false
                projectLock.unlock()
                return
            }
            pendingCwds.remove(cwd)
            projectLock.unlock()

            // Disk work happens only on this worker and only after the cwd was captured.
            let project = ProjectResolver.resolve(cwd)

            projectLock.lock()
            cachedProjects[cwd] = ProjectCacheEntry(project: project)
            if cachedProjects.count > 4096 {
                cachedProjects.removeAll(keepingCapacity: true)
                cachedProjects[cwd] = ProjectCacheEntry(project: project)
            }
            projectLock.unlock()

            stateLock.lock()
            let collecting = started
            let owners = cwdOwners[cwd] ?? []
            stateLock.unlock()
            if collecting, !owners.isEmpty {
                deliverGraphChanges(owners)
            }
            resolvedInBatch += 1
        }

        projectLock.lock()
        let more = !pendingCwds.isEmpty
        if !more {
            projectPumpScheduled = false
        }
        projectLock.unlock()
        if more {
            projectQueue.async { [weak self] in
                self?.drainProjectQueue()
            }
        }
    }

    private func projectRootLocked(userID: UInt32, identity: ExecutionIdentity) -> String? {
        guard let scope = users[userID] else { return nil }
        if let project = scope.engine.project(for: identity) {
            return project.root
        }
        if let record = scope.engine.execution(for: identity),
           let cwd = record.workingDirectory {
            return cachedProject(cwd)?.root
        }
        return nil
    }

    // MARK: - Graph projection

    /// Projects one user's scoped graph from an engine copy. Sorting and the repeated ancestry
    /// scan intentionally run outside the authorization serialization boundary.
    private func scopedGraph(_ snapshot: GraphSnapshot) -> GraphSnapshot {
        var included = Set<ExecutionIdentity>()

        for association in snapshot.associations {
            included.insert(association.execution)
        }
        for session in snapshot.sessions {
            included.insert(session.root)
        }

        // Keep only a user's recognized sessions, associated executions, and the fork/exec
        // ancestors needed to explain them. Responsible edges are auxiliary, not ancestry.
        let ancestorEdges = snapshot.edges.filter {
            $0.kind == .fork || $0.kind == .exec
        }
        var changed = true
        while changed {
            changed = false
            for edge in ancestorEdges where included.contains(edge.child) {
                if included.insert(edge.parent).inserted {
                    changed = true
                }
            }
        }

        var graph = GraphSnapshot()
        graph.executions = snapshot.executions
            .filter { included.contains($0.identity) }
            .map { record in
                var stripped = record
                stripped.auditToken = nil
                return stripped
            }
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.identity.stableID < $1.identity.stableID
            }

        let executionByID = Dictionary(
            uniqueKeysWithValues: graph.executions.map { ($0.identity, $0) }
        )

        graph.edges = snapshot.edges
            .filter {
                included.contains($0.parent) && included.contains($0.child)
            }
            .sorted {
                if $0.child != $1.child { return $0.child.stableID < $1.child.stableID }
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.parent.stableID < $1.parent.stableID
            }
        graph.sessions = snapshot.sessions
            .filter { included.contains($0.root) }
            .sorted { $0.id < $1.id }
        for index in graph.sessions.indices {
            guard let root = executionByID[graph.sessions[index].root],
                  let cwd = root.workingDirectory,
                  let project = cachedProject(cwd) else {
                continue
            }
            graph.sessions[index].project = project
        }
        graph.associations = snapshot.associations
            .filter { included.contains($0.execution) }
            .sorted {
                if $0.execution != $1.execution {
                    return $0.execution.stableID < $1.execution.stableID
                }
                return $0.sessionID < $1.sessionID
            }
        return graph
    }

    // MARK: - Health and callbacks

    private func healthLocked(userID: UInt32?) -> MonitorHealth {
        let scope = userID.flatMap { users[$0] }
        let message: String?
        if availability != .active {
            message = statusMessage
        } else if collectionUncertain {
            message = "Event sequence gap; collection state is uncertain."
        } else if let userID, responseFailureUsers.contains(userID) {
            message = "An authorization response failed."
        } else {
            message = scope?.preparationMessage
        }
        return MonitorHealth(
            availability: availability,
            message: message,
            storageError: nil,
            droppedEvents: 0,
            activeRevision: scope?.activeRevision,
            activeMode: scope?.activeMode,
            sqliteVersion: nil
        )
    }

    private var currentClient: OpaquePointer? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return client
    }

    private func deliver(
        activities: [(UInt32, ActivityRecord)],
        gaps: [(UInt32, CollectionGap)],
        graphUsers: Set<UInt32>,
        healthUsers: Set<UInt32>,
        callbacks: Callbacks?
    ) {
        guard let callbacks else { return }
        for (userID, activity) in activities {
            callbacks.activity(userID, activity)
        }
        for (userID, gap) in gaps {
            callbacks.gap(userID, gap)
        }
        for userID in graphUsers {
            callbacks.graphChanged(userID)
        }
        publishHealth(healthUsers)
    }

    private func deliverGraphChanges(_ userIDs: Set<UInt32>) {
        guard !userIDs.isEmpty, let callbacks = cachedCallbacksValue() else { return }
        for userID in userIDs {
            callbacks.graphChanged(userID)
        }
    }

    private func publishHealth(_ userIDs: Set<UInt32>) {
        guard !userIDs.isEmpty else { return }
        guard let healthChanged = cachedCallbacksValue()?.healthChanged else { return }
        let identifiers = userIDs.sorted()
        notificationQueue.async {
            for userID in identifiers {
                healthChanged(userID)
            }
        }
    }

    // MARK: - Static policy and ES constants

    private static func isAuthorizationEventType(_ type: es_event_type_t) -> Bool {
        // AUTH event types are the contiguous prefix of the event enum. Only the three
        // subscribed types normally arrive, but any authorization message must be answered.
        type.rawValue >= ES_EVENT_TYPE_AUTH_EXEC.rawValue
            && type.rawValue <= ES_EVENT_TYPE_AUTH_UNLINK.rawValue
    }

    private static func notificationEventRawValues() -> Set<UInt32> {
        [
            ES_EVENT_TYPE_NOTIFY_FORK.rawValue,
            ES_EVENT_TYPE_NOTIFY_EXEC.rawValue,
            ES_EVENT_TYPE_NOTIFY_EXIT.rawValue,
            ES_EVENT_TYPE_NOTIFY_OPEN.rawValue,
            ES_EVENT_TYPE_NOTIFY_CREATE.rawValue,
            ES_EVENT_TYPE_NOTIFY_WRITE.rawValue,
            ES_EVENT_TYPE_NOTIFY_CLOSE.rawValue,
            ES_EVENT_TYPE_NOTIFY_RENAME.rawValue,
            ES_EVENT_TYPE_NOTIFY_UNLINK.rawValue
        ]
    }

    private static func requiredAuthRawValues(
        _ policies: [ESPreparedPolicy]
    ) -> Set<UInt32> {
        var rawEvents: Set<UInt32> = []
        for operation in ESPreparedPolicy.requiredOperations(for: policies) {
            switch operation {
            case .open:
                rawEvents.insert(ES_EVENT_TYPE_AUTH_OPEN.rawValue)
            case .delete:
                rawEvents.insert(ES_EVENT_TYPE_AUTH_UNLINK.rawValue)
            case .rename:
                rawEvents.insert(ES_EVENT_TYPE_AUTH_RENAME.rawValue)
            }
        }
        return rawEvents
    }

    private static func subscribe(
        _ client: OpaquePointer,
        rawEvents: Set<UInt32>
    ) -> Bool {
        guard !rawEvents.isEmpty else { return true }
        let events = rawEvents.sorted().map { es_event_type_t(rawValue: $0) }
        return events.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            return es_subscribe(client, base, UInt32(events.count)) == ES_RETURN_SUCCESS
        }
    }

    private static func unsubscribe(
        _ client: OpaquePointer,
        rawEvents: Set<UInt32>
    ) -> Bool {
        guard !rawEvents.isEmpty else { return true }
        let events = rawEvents.sorted().map { es_event_type_t(rawValue: $0) }
        return events.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            return es_unsubscribe(client, base, UInt32(events.count)) == ES_RETURN_SUCCESS
        }
    }

    private static func startFailure(
        _ result: es_new_client_result_t
    ) -> (availability: MonitorAvailability, message: String) {
        if result == ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED {
            return (.notEntitled, "Endpoint Security entitlement is unavailable.")
        }
        if result == ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED {
            return (.fullDiskAccessRequired, "Full Disk Access is required for Endpoint Security.")
        }
        if result == ES_NEW_CLIENT_RESULT_ERR_NOT_PRIVILEGED {
            return (.unavailable, "Endpoint Security requires root privileges.")
        }
        if result == ES_NEW_CLIENT_RESULT_ERR_TOO_MANY_CLIENTS {
            return (.unavailable, "Too many Endpoint Security clients are connected.")
        }
        return (.unavailable, "Endpoint Security is unavailable.")
    }

    private static func validate(_ configuration: MonitorConfiguration) throws {
        guard configuration.revision >= 1 else {
            throw EndpointSecurityClientError.invalidConfiguration
        }
        // The server's preparation worker resolves paths and vnode identities. This boundary
        // rejects relative or empty rule paths so a callback can never match ambiguously.
        for rule in configuration.rules where rule.enabled {
            guard !rule.path.isEmpty, rule.path.hasPrefix("/") else {
                throw EndpointSecurityClientError.invalidConfiguration
            }
        }
    }

    /// Persisted configurations are trusted but may name a target that is temporarily
    /// absent. Previously prepared identities are retained in that case; a new rule that
    /// cannot be prepared is disabled rather than widened to a path-only match.
    private static func prepareForRestoration(
        _ configuration: MonitorConfiguration
    ) -> (configuration: MonitorConfiguration, message: String?) {
        guard configuration.mode != .recordOnly else {
            return (configuration, nil)
        }

        var prepared = configuration
        var unavailable = 0
        for index in prepared.rules.indices {
            let rule = prepared.rules[index]
            guard rule.enabled else { continue }
            guard !rule.path.isEmpty, rule.path.hasPrefix("/") else {
                prepared.rules[index].enabled = false
                unavailable += 1
                continue
            }

            do {
                prepared.rules[index] = try RuleMatcher.prepare(rule)
            } catch let error as ProtectionRulePreparationError {
                switch error {
                case .unresolvablePath:
                    if rule.fileIdentity == nil {
                        prepared.rules[index].enabled = false
                        unavailable += 1
                    }
                case .emptyPath, .targetTypeMismatch:
                    prepared.rules[index].enabled = false
                    unavailable += 1
                }
            } catch {
                if rule.fileIdentity == nil {
                    prepared.rules[index].enabled = false
                    unavailable += 1
                }
            }
        }

        let message = unavailable > 0
            ? "\(unavailable) persisted protection rules are unavailable."
            : nil
        return (prepared, message)
    }

    private func detailText(extra: String?, truncated: Bool) -> String? {
        var parts: [String] = []
        if let extra, !extra.isEmpty {
            parts.append(extra)
        }
        if truncated {
            parts.append("pathTruncated")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }
}
