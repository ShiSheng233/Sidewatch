import Foundation

/// Bounded transport from the ES callback to transactional persistence.
/// Callback entry points never wait for disk or spawn one task per event.
final class ActivityIngestion: @unchecked Sendable {
    typealias SnapshotProvider = @Sendable (UInt32) -> GraphSnapshot
    typealias StoreProvider = @Sendable (UInt32) async throws -> ActivityStore
    private struct Buffer {
        var events: [ActivityRecord] = []
        var head = 0
        var endpoints: [ListeningEndpoint] = []
        var gaps: [CollectionGap] = []
        var graphDirty = false
        var count: Int { events.count - head }
        mutating func take(_ limit: Int) -> [ActivityRecord] {
            let end = min(events.count, head + limit)
            let result = Array(events[head..<end])
            head = end
            if head == events.count { events.removeAll(keepingCapacity: true); head = 0 }
            else if head >= 4096 && head >= events.count / 2 {
                events = Array(events[head...])
                head = 0
            }
            return result
        }
    }
    private struct PendingWork {
        var activities: [ActivityRecord] = []
        var endpoints: [ListeningEndpoint] = []
        var gaps: [CollectionGap] = []
        var graphDirty = false
        var isEmpty: Bool {
            activities.isEmpty && endpoints.isEmpty && gaps.isEmpty && !graphDirty
        }
    }
    /// Work detached at the pause instant. Only this snapshot is written before the
    /// caller's SQL pass; anything accepted later stays in the live buffer.
    private struct PausedWork {
        var remainingEvents: Int
        var endpoints: [ListeningEndpoint]
        var gaps: [CollectionGap]
        var graphDirty: Bool
        var isEmpty: Bool {
            remainingEvents == 0 && endpoints.isEmpty && gaps.isEmpty && !graphDirty
        }
    }
    /// The graph rows last committed for a user, so later batches carry only changes.
    /// Cleared whenever the store's rows may have diverged: after a failure, after a
    /// history mutation, or when the user's store is replaced.
    private struct PersistedGraph {
        var store: ObjectIdentifier
        var executions: [String: ExecutionRecord] = [:]
        var sessions: [String: AgentSession] = [:]
        var edges: Set<ExecutionEdge> = []
        var associations: Set<ExecutionAssociation> = []
    }
    private let lock = NSLock()
    private var buffers: [UInt32: Buffer] = [:]
    private var persisted: [UInt32: PersistedGraph] = [:]
    /// Users whose history is being mutated. Their callbacks keep buffering and no
    /// persistence pass copies their graph until the mutation resumes them.
    private var suspended: Set<UInt32> = []
    private var pausedWork: [UInt32: PausedWork] = [:]
    private var retentionBusy: Set<UInt32> = []
    private var retentionWaiters: [UInt32: [CheckedContinuation<Void, Never>]] = [:]
    private var eventCount = 0
    private var task: Task<Void, Never>?
    private var timer: DispatchSourceTimer?
    private var failedUsers: Set<UInt32> = []
    private let stores: StoreProvider
    private let capture: CaptureRecord
    private let snapshot: SnapshotProvider
    private let committed: @Sendable (UInt32, Int64) -> Void
    private let storageFailed: @Sendable (UInt32, Int32) -> Void
    private let dropped: @Sendable (UInt32, UInt64) -> Void
    private let capacity = 8192

    init(stores: @escaping StoreProvider, capture: CaptureRecord,
         snapshot: @escaping SnapshotProvider,
         committed: @escaping @Sendable (UInt32, Int64) -> Void,
         storageFailed: @escaping @Sendable (UInt32, Int32) -> Void,
         dropped: @escaping @Sendable (UInt32, UInt64) -> Void) {
        self.stores = stores
        self.capture = capture
        self.snapshot = snapshot
        self.committed = committed
        self.storageFailed = storageFailed
        self.dropped = dropped
    }

    func start() {
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.shisheng.Sidewatch.persistence-timer"))
        source.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        source.setEventHandler { [weak self] in self?.schedule() }
        lock.withLock { timer = source }
        source.resume()
    }

    func enqueue(_ activity: ActivityRecord, userID: UInt32) {
        var overflow = false
        let wake = lock.withLock { () -> Bool in
            if eventCount >= capacity {
                overflow = true
                addGapLocked(userID: userID, reason: "queueOverflow", count: 1)
                return false
            }
            buffers[userID, default: Buffer()].events.append(activity)
            eventCount += 1
            return eventCount % 256 == 0
        }
        if overflow { dropped(userID, 1) }
        if wake { schedule() }
    }

    func updateEndpoints(_ endpoints: [ListeningEndpoint], userID: UInt32) {
        lock.withLock { buffers[userID, default: Buffer()].endpoints = endpoints }
    }

    func graphChanged(userID: UInt32) {
        lock.withLock { buffers[userID, default: Buffer()].graphDirty = true }
        schedule()
    }

    func gap(_ gap: CollectionGap, userID: UInt32) {
        lock.withLock {
            addGapLocked(userID: userID, reason: gap.reason, count: gap.missingCount ?? 0)
        }
    }

    /// Runs a history mutation (clear or retention) while this user's ingestion is paused.
    ///
    /// Work accepted before the pause is persisted first, so the SQL pass sees it. Callbacks
    /// that arrive during `operation` stay buffered and are written only after it resumes, so
    /// an old graph snapshot cannot be replayed over the rows the operation removed. The
    /// boundary is the instant the pause began: memory observed at or after it must survive
    /// the caller's pruning. Other users keep flowing throughout.
    func withPausedIngestion<T: Sendable>(
        userID: UInt32,
        _ operation: @Sendable (Date) async throws -> T
    ) async throws -> T {
        await acquireRetention(userID: userID)
        let boundary = lock.withLock { () -> Date in
            persisted.removeValue(forKey: userID)
            // Everything accepted up to this instant is detached atomically and will be
            // written before the mutation; later callbacks accumulate fresh state.
            var buffer = buffers[userID] ?? Buffer()
            pausedWork[userID] = PausedWork(
                remainingEvents: buffer.count,
                endpoints: buffer.endpoints,
                gaps: buffer.gaps,
                graphDirty: buffer.graphDirty)
            buffer.endpoints.removeAll(keepingCapacity: true)
            buffer.gaps.removeAll(keepingCapacity: true)
            buffer.graphDirty = false
            buffers[userID] = buffer
            suspended.insert(userID)
            return Date()
        }
        defer {
            resume(userID: userID)
            releaseRetention(userID: userID)
        }
        // Any pass that copied this user's graph before the pause must finish first.
        let current = lock.withLock { task }
        await current?.value
        try await persistBuffered(userID: userID)
        return try await operation(boundary)
    }

    func flush() async {
        repeat {
            schedule()
            let pending = lock.withLock { task }
            await pending?.value
            let more = lock.withLock {
                failedUsers.isEmpty && buffers.contains { userID, buffer in
                    !suspended.contains(userID)
                        && (buffer.count > 0 || buffer.graphDirty || !buffer.endpoints.isEmpty || !buffer.gaps.isEmpty)
                }
            }
            if !more { break }
        } while true
    }

    func stop() {
        lock.withLock { timer?.cancel(); timer = nil }
    }

    private func schedule() {
        lock.withLock {
            guard task == nil else { return }
            let hasWork = buffers.contains { userID, buffer in
                !suspended.contains(userID)
                    && (buffer.count > 0 || buffer.graphDirty || !buffer.endpoints.isEmpty || !buffer.gaps.isEmpty)
            }
            guard hasWork else { return }
            task = Task { [weak self] in
                guard let self else { return }
                await self.drain()
            }
        }
    }

    private func drain() async {
        // One pass per wake keeps disk failures from creating an immediate retry loop.
        let userIDs = lock.withLock { Array(buffers.keys) }
        for userID in userIDs {
            // Checking the pause and taking the batch share one lock, so a retention pass
            // either sees the copied work complete before its SQL boundary or skips it.
            guard let work = lock.withLock({ () -> PendingWork? in
                guard !suspended.contains(userID) else { return nil }
                return takePendingLocked(userID: userID)
            }), !work.isEmpty else {
                continue
            }
            do {
                try await persist(work, userID: userID)
            } catch {
                recordFailure(work, userID: userID, error: error)
            }
        }
        lock.withLock { task = nil }
    }

    /// Persists exactly the work detached when the pause began. A failure aborts the
    /// mutation instead of running SQL cleanup over undelivered history; whatever was not
    /// consumed stays buffered and is retried after the pause ends.
    private func persistBuffered(userID: UInt32) async throws {
        while true {
            let work = lock.withLock { () -> PendingWork? in
                guard var paused = pausedWork[userID], !paused.isEmpty else {
                    pausedWork.removeValue(forKey: userID)
                    return nil
                }
                let events = buffers[userID, default: Buffer()].take(min(256, paused.remainingEvents))
                eventCount -= events.count
                paused.remainingEvents = events.isEmpty
                    ? 0
                    : max(0, paused.remainingEvents - events.count)
                let result = PendingWork(
                    activities: events,
                    endpoints: paused.endpoints,
                    gaps: paused.gaps,
                    graphDirty: paused.graphDirty)
                paused.endpoints.removeAll(keepingCapacity: true)
                paused.gaps.removeAll(keepingCapacity: true)
                paused.graphDirty = false
                pausedWork[userID] = paused
                return result
            }
            guard let work else { return }
            do {
                try await persist(work, userID: userID)
            } catch {
                lock.withLock {
                    // The failed batch's events are covered by the failure gap. Whatever
                    // was still detached returns to the live buffer for the next pass.
                    guard let paused = pausedWork.removeValue(forKey: userID) else { return }
                    var buffer = buffers[userID, default: Buffer()]
                    buffer.gaps.append(contentsOf: paused.gaps)
                    buffer.graphDirty = buffer.graphDirty || paused.graphDirty
                    if buffer.endpoints.isEmpty { buffer.endpoints = paused.endpoints }
                    buffers[userID] = buffer
                }
                recordFailure(work, userID: userID, error: error)
                throw error
            }
        }
    }

    private func persist(_ work: PendingWork, userID: UInt32) async throws {
        let store = try await stores(userID)
        let storeKey = ObjectIdentifier(store)
        let previous = lock.withLock { persisted[userID] }.flatMap { $0.store == storeKey ? $0 : nil }

        // The engine graph is copied under the lock AUTH decisions also take, so it is read
        // only when it changed, or when an activity names an execution not yet committed.
        let needsGraph = work.graphDirty || previous == nil || work.activities.contains { activity in
            guard let execution = activity.execution else { return false }
            return previous?.executions[execution.stableID] == nil
        }
        var batch = IngestionBatch(capture: capture, graph: GraphSnapshot(),
                                   activities: work.activities, endpoints: work.endpoints, gaps: work.gaps)
        var next = previous ?? PersistedGraph(store: storeKey)
        if needsGraph {
            let full = snapshot(userID)
            if let previous {
                batch.graph = Self.delta(full, since: previous)
                batch.currentExecutions = full.executions
            } else {
                batch.graph = full
            }
            next = Self.record(full, store: storeKey)
        }
        let watermark: Int64
        do {
            watermark = try await store.ingest(batch)
        } catch {
            lock.withLock { _ = persisted.removeValue(forKey: userID) }
            throw error
        }
        let recovered = lock.withLock { () -> Bool in
            // A history mutation that started meanwhile invalidated the cache; keep it invalid.
            if !suspended.contains(userID) { persisted[userID] = next }
            return failedUsers.remove(userID) != nil
        }
        if recovered { Diagnostics.storage.notice("Activity storage recovered") }
        committed(userID, watermark)
    }

    private static func record(_ graph: GraphSnapshot, store: ObjectIdentifier) -> PersistedGraph {
        PersistedGraph(
            store: store,
            executions: Dictionary(graph.executions.map { ($0.identity.stableID, $0) }, uniquingKeysWith: { _, new in new }),
            sessions: Dictionary(graph.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }),
            edges: Set(graph.edges),
            associations: Set(graph.associations))
    }

    /// Rows that differ from the last commit. A new execution also resends the executions
    /// that point at it, so a parent link that couldn't resolve earlier is filled in, and
    /// edges and associations touching a changed row are resent for the same reason.
    private static func delta(_ full: GraphSnapshot, since previous: PersistedGraph) -> GraphSnapshot {
        PersistedGraphView(executions: previous.executions, sessions: previous.sessions,
                           edges: previous.edges, associations: previous.associations).delta(full)
    }

    private func recordFailure(_ work: PendingWork, userID: UInt32, error: Error) {
        let firstFailure = lock.withLock { () -> Bool in
            addGapLocked(
                userID: userID,
                reason: "persistenceFailure",
                count: UInt64(work.activities.count) + work.gaps.reduce(0) { $0 + ($1.missingCount ?? 0) })
            buffers[userID, default: Buffer()].graphDirty = true
            return failedUsers.insert(userID).inserted
        }
        if firstFailure { Diagnostics.storage.error("Activity persistence unavailable") }
        storageFailed(userID, Int32(clamping: (error as NSError).code))
        dropped(userID, UInt64(work.activities.count))
    }

    private func takePendingLocked(userID: UInt32) -> PendingWork {
        guard var buffer = buffers[userID] else { return PendingWork() }
        let activities = buffer.take(256)
        eventCount -= activities.count
        let work = PendingWork(
            activities: activities,
            endpoints: buffer.endpoints,
            gaps: buffer.gaps,
            graphDirty: buffer.graphDirty)
        buffer.endpoints.removeAll(keepingCapacity: true)
        buffer.gaps.removeAll(keepingCapacity: true)
        buffer.graphDirty = false
        buffers[userID] = buffer
        return work
    }

    private func resume(userID: UInt32) {
        lock.withLock {
            suspended.remove(userID)
            pausedWork.removeValue(forKey: userID)
            // The mutation may have removed committed rows. The next pass rewrites the
            // whole graph so history again holds everything the engine knows.
            persisted.removeValue(forKey: userID)
            buffers[userID, default: Buffer()].graphDirty = true
        }
        schedule()
    }

    private func acquireRetention(userID: UInt32) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var acquired = false
            lock.withLock {
                if retentionBusy.contains(userID) {
                    retentionWaiters[userID, default: []].append(continuation)
                } else {
                    retentionBusy.insert(userID)
                    acquired = true
                }
            }
            if acquired { continuation.resume() }
        }
    }

    private func releaseRetention(userID: UInt32) {
        var next: CheckedContinuation<Void, Never>?
        lock.withLock {
            if var waiters = retentionWaiters[userID], !waiters.isEmpty {
                // Hand the exclusive pause straight to the next caller.
                next = waiters.removeFirst()
                retentionWaiters[userID] = waiters.isEmpty ? nil : waiters
            } else {
                retentionWaiters.removeValue(forKey: userID)
                retentionBusy.remove(userID)
            }
        }
        if let next { next.resume() } else { schedule() }
    }

    private func addGapLocked(userID: UInt32, reason: String, count: UInt64) {
        if let index = buffers[userID]?.gaps.firstIndex(where: { $0.reason == reason }) {
            let old = buffers[userID]!.gaps[index].missingCount ?? 0
            buffers[userID]!.gaps[index].missingCount = old &+ count
        } else {
            buffers[userID, default: Buffer()].gaps.append(.init(captureID: capture.id, occurredAt: Date(), reason: reason, missingCount: count))
        }
    }
}

/// The committed graph rows used to compute a delta. Separate from the ingestion actor
/// state so the delta rules can be tested directly.
struct PersistedGraphView {
    var executions: [String: ExecutionRecord]
    var sessions: [String: AgentSession]
    var edges: Set<ExecutionEdge>
    var associations: Set<ExecutionAssociation>

    func delta(_ full: GraphSnapshot) -> GraphSnapshot {
        var changed = Set<String>()
        var added = Set<String>()
        for record in full.executions {
            let key = record.identity.stableID
            guard let old = executions[key] else {
                added.insert(key)
                changed.insert(key)
                continue
            }
            if old != record { changed.insert(key) }
        }
        var result = GraphSnapshot()
        result.executions = full.executions.filter { record in
            changed.contains(record.identity.stableID)
                || record.parent.map { added.contains($0.stableID) } == true
                || record.responsible.map { added.contains($0.stableID) } == true
        }
        let resent = Set(result.executions.map(\.identity.stableID))
        result.sessions = full.sessions.filter { sessions[$0.id] != $0 }
        let changedSessions = Set(result.sessions.map(\.id))
        result.edges = full.edges.filter { edge in
            !edges.contains(edge) || resent.contains(edge.parent.stableID) || resent.contains(edge.child.stableID)
        }
        result.associations = full.associations.filter { association in
            !associations.contains(association) || resent.contains(association.execution.stableID)
                || changedSessions.contains(association.sessionID)
        }
        return result
    }
}
