import Foundation
import XCTest

/// Regression coverage for the broker retention boundary: ingestion for a user is
/// paused and drained, storage is cleaned, memory is pruned to the surviving graph,
/// and only then does buffered work resume. These tests use real stores on disk and
/// emulate only the contract the ES engine's `retain` provides to the broker.
final class IngestionRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let userID: UInt32 = 501
    private var directories: [URL] = []

    override func setUpWithError() throws {
        directories = []
    }

    override func tearDownWithError() throws {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        directories = []
    }

    // MARK: - Pause, drain, resume

    func testPauseDrainsAcceptedWorkBeforeTheMutationAndBuffersNewCallbacks() async throws {
        let uid = userID
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }
        try await saveConfiguration(store, revision: 2)

        let box = GraphBox()
        let log = WatermarkLog()
        let ingestion = makeIngestion(
            stores: [uid: store], graph: box, committed: { log.append($0) })

        ingestion.enqueue(
            makeActivity(execution: nil, revision: 2, sourcePath: "/tmp/first"),
            userID: uid)
        await ingestion.flush()
        let initialCount = try await page(store).activities.count
        XCTAssertEqual(initialCount, 1)

        let buffered = makeActivity(execution: nil, revision: 2, sourcePath: "/tmp/buffered")
        let occurredAt = now
        try await ingestion.withPausedIngestion(userID: uid) { _ in
            // Accepted before the pause: persisted before the caller's SQL pass.
            let before = try await store.page(ActivityQuery(limit: 100)).activities.count
            XCTAssertEqual(before, 1)

            // New callbacks during the mutation stay buffered. Flushing must not
            // write them, and must not block on them.
            ingestion.enqueue(buffered, userID: uid)
            ingestion.gap(
                .init(captureID: "capture", occurredAt: occurredAt, reason: "testGap", missingCount: 3),
                userID: uid)
            await ingestion.flush()
            let pausedCount = try await store.page(ActivityQuery(limit: 100)).activities.count
            XCTAssertEqual(pausedCount, 1)

            let paused = try await store.snapshot(health: .init(availability: .active))
            XCTAssertTrue(paused.gaps.isEmpty)
        }

        await ingestion.flush()
        let page = try await page(store)
        XCTAssertEqual(page.activities.map(\.sourcePath), ["/tmp/buffered", "/tmp/first"])
        let snapshot = try await store.snapshot(health: .init(availability: .active))
        XCTAssertEqual(snapshot.gaps.map(\.reason), ["testGap"])

        let watermarks = log.values
        XCTAssertEqual(watermarks, watermarks.sorted())
        XCTAssertEqual(watermarks.last, page.watermark)
    }

    func testQueuedGraphSnapshotCannotReplayRemovedHistory() async throws {
        let uid = userID
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }
        try await saveConfiguration(store, revision: 2)

        let old = makeExecution(pid: 700, start: now, state: .exited, endedAt: now)
        let oldSession = makeSession(id: "session-old", root: old.identity, endedAt: now)
        _ = try await store.ingest(makeBatch(
            executions: [old],
            sessions: [oldSession],
            activities: [makeActivity(execution: old.identity, revision: 2, sourcePath: "/tmp/old")]))
        let seeded = try await page(store)

        let box = GraphBox()
        box.write(GraphSnapshot(executions: [old], sessions: [oldSession]))
        let log = WatermarkLog()
        let ingestion = makeIngestion(
            stores: [uid: store], graph: box, committed: { log.append($0) })

        // A graph write is still queued when the retention boundary begins.
        ingestion.enqueue(
            makeActivity(execution: old.identity, revision: 2, sourcePath: "/tmp/queued"),
            userID: uid)
        ingestion.graphChanged(userID: uid)

        let live = makeExecution(
            pid: 701, start: now, executable: "/usr/bin/claude", arguments: ["claude"])
        let newActivity = makeActivity(
            execution: live.identity, revision: 2, sourcePath: "/tmp/new")
        try await ingestion.withPausedIngestion(userID: uid) { _ in
            // The queued write landed before cleanup, so nothing is left to replay.
            let before = try await store.graph()
            XCTAssertEqual(Set(before.executions.map(\.identity)), [old.identity])

            _ = try await store.clearHistory()
            let retained = try await store.graph()
            XCTAssertTrue(retained.executions.isEmpty)
            XCTAssertTrue(retained.sessions.isEmpty)

            // Emulates `client.retainGraph(retained, userID:since:)`, then a live
            // observation arriving while the SQL pass runs.
            box.write(GraphSnapshot(executions: [live]))
            ingestion.graphChanged(userID: uid)
            ingestion.enqueue(newActivity, userID: uid)
        }

        await ingestion.flush()
        let graph = try await store.graph()
        XCTAssertEqual(Set(graph.executions.map(\.identity)), [live.identity])
        XCTAssertTrue(graph.sessions.isEmpty)
        let page = try await page(store)
        XCTAssertEqual(page.activities.map(\.sourcePath), ["/tmp/new"])
        XCTAssertGreaterThanOrEqual(page.watermark, seeded.watermark)
        XCTAssertEqual(log.values, log.values.sorted())
    }

    func testOtherUsersKeepPersistingWhileOneUserIsPaused() async throws {
        let uid = userID
        let other: UInt32 = 502
        let firstStore = try ActivityStore(path: try makePath())
        let secondStore = try ActivityStore(path: try makePath())
        defer { try? firstStore.close(); try? secondStore.close() }
        try await saveConfiguration(firstStore, revision: 2)
        try await saveConfiguration(secondStore, revision: 2)

        let box = GraphBox()
        let ingestion = makeIngestion(
            stores: [uid: firstStore, other: secondStore],
            graph: box,
            committed: { _ in })

        let otherActivity = makeActivity(execution: nil, revision: 2, sourcePath: "/tmp/other")
        try await ingestion.withPausedIngestion(userID: uid) { _ in
            ingestion.enqueue(otherActivity, userID: other)
            await ingestion.flush()

            let otherCount = try await secondStore.page(ActivityQuery(limit: 100)).activities.count
            XCTAssertEqual(otherCount, 1)
            let pausedCount = try await firstStore.page(ActivityQuery(limit: 100)).activities.count
            XCTAssertTrue(pausedCount == 0)
        }
        await ingestion.flush()
        let firstCount = try await page(firstStore).activities.count
        let secondCount = try await page(secondStore).activities.count
        XCTAssertEqual(firstCount, 0)
        XCTAssertEqual(secondCount, 1)
    }

    func testPauseWaitsForAnInFlightGraphWriteBeforeTheMutation() async throws {
        let uid = userID
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }
        try await saveConfiguration(store, revision: 2)

        let old = makeExecution(pid: 800, start: now, state: .exited, endedAt: now)
        let box = GraphBox()
        box.write(GraphSnapshot(executions: [old]))
        let provider = BlockingStoreProvider(store: store)
        let ingestion = ActivityIngestion(
            stores: { _ in try await provider.store() },
            capture: makeCapture(),
            snapshot: { _ in box.read() },
            committed: { _, _ in },
            storageFailed: { _, _ in },
            dropped: { _, _ in })

        ingestion.graphChanged(userID: uid)
        await provider.waitUntilBlocked()

        let bodyRan = Flag()
        let retention = Task {
            try await ingestion.withPausedIngestion(userID: uid) { _ in
                await bodyRan.set()
                _ = try await store.clearHistory()
                box.write(try await store.graph())
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let ranWhileBlocked = await bodyRan.value
        XCTAssertFalse(ranWhileBlocked)
        await provider.release()
        try await retention.value
        let didRun = await bodyRan.value
        XCTAssertTrue(didRun)

        await ingestion.flush()
        let graph = try await store.graph()
        XCTAssertTrue(graph.executions.isEmpty)
    }

    func testFailedDrainAbortsTheMutationAndStaysResumable() async throws {
        let uid = userID
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }
        try await saveConfiguration(store, revision: 2)

        let provider = FailingStoreProvider(store: store)
        let box = GraphBox()
        let ingestion = ActivityIngestion(
            stores: { _ in try await provider.store() },
            capture: makeCapture(),
            snapshot: { _ in box.read() },
            committed: { _, _ in },
            storageFailed: { _, _ in },
            dropped: { _, _ in })

        ingestion.enqueue(
            makeActivity(execution: nil, revision: 2, sourcePath: "/tmp/pending"),
            userID: uid)

        let bodyRan = Flag()
        do {
            try await ingestion.withPausedIngestion(userID: uid) { _ in
                await bodyRan.set()
            }
            XCTFail("Retention ran over undelivered history")
        } catch {
            let ran = await bodyRan.value
            XCTAssertFalse(ran)
        }

        await ingestion.flush()
        let ran = await bodyRan.value
        XCTAssertFalse(ran)
        let snapshot = try await store.snapshot(health: .init(availability: .active))
        XCTAssertEqual(snapshot.gaps.map(\.reason), ["persistenceFailure"])
    }

    func testConcurrentMutationsForOneUserSerialize() async throws {
        let uid = userID
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }
        try await saveConfiguration(store, revision: 2)

        let box = GraphBox()
        let ingestion = makeIngestion(stores: [uid: store], graph: box, committed: { _ in })
        let order = OrderLog()

        let firstStarted = Flag()
        let releaseFirst = AsyncGate()
        let first = Task {
            try await ingestion.withPausedIngestion(userID: uid) { _ in
                await order.append("first")
                await firstStarted.set()
                await releaseFirst.wait()
                await order.append("first-end")
            }
        }
        // Reading the flag does not wait for it; the second mutation must only be
        // started once the first one actually holds the pause.
        while !(await firstStarted.value) { await Task.yield() }

        let secondEntered = Flag()
        let second = Task {
            try await ingestion.withPausedIngestion(userID: uid) { _ in
                await secondEntered.set()
                await order.append("second")
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let enteredEarly = await secondEntered.value
        XCTAssertFalse(enteredEarly)

        let buffered = makeActivity(execution: nil, revision: 2, sourcePath: "/tmp/late")
        ingestion.enqueue(buffered, userID: uid)
        await releaseFirst.open()
        try await first.value
        try await second.value
        let ordering = await order.values
        XCTAssertEqual(ordering, ["first", "first-end", "second"])

        await ingestion.flush()
        let count = try await page(store).activities.count
        XCTAssertEqual(count, 1)
    }

    // MARK: - Helpers

    private func makeIngestion(
        stores: [UInt32: ActivityStore],
        graph: GraphBox,
        committed: @escaping @Sendable (Int64) -> Void
    ) -> ActivityIngestion {
        ActivityIngestion(
            stores: { userID in
                guard let store = stores[userID] else { throw ActivityStoreError.storageConfiguration }
                return store
            },
            capture: makeCapture(),
            snapshot: { _ in graph.read() },
            committed: { _, watermark in committed(watermark) },
            storageFailed: { _, _ in },
            dropped: { _, _ in })
    }

    private func page(_ store: ActivityStore) async throws -> ActivityPage {
        try await store.page(ActivityQuery(limit: 100))
    }

    private func saveConfiguration(_ store: ActivityStore, revision: Int64) async throws {
        var configuration = MonitorConfiguration()
        configuration.revision = revision
        configuration.mode = .recordOnly
        configuration.retentionDays = 1
        try await store.saveConfiguration(configuration)
    }

    private func makePath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidewatchIngestionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory.appendingPathComponent("activity.sqlite").path
    }

    private func makeCapture() -> CaptureRecord {
        CaptureRecord(id: "capture", bootID: "boot-ingestion-tests", startedAt: now, endedAt: nil)
    }

    private func makeExecution(
        pid: Int32,
        start: Date,
        state: ExecutionState = .running,
        endedAt: Date? = nil,
        executable: String = "/usr/bin/tool",
        arguments: [String] = ["tool"]
    ) -> ExecutionRecord {
        ExecutionRecord(
            identity: ExecutionIdentity(
                process: ProcessIdentity(
                    bootID: "boot-ingestion-tests",
                    pid: pid,
                    startTimeMicros: MicroTime.value(start)),
                version: 1),
            parent: nil,
            responsible: nil,
            parentPID: 1,
            userID: userID,
            executable: executable,
            arguments: arguments,
            workingDirectory: nil,
            signingID: nil,
            teamID: nil,
            startedAt: start,
            endedAt: endedAt,
            state: state,
            evidence: .observed,
            auditToken: nil)
    }

    private func makeSession(
        id: String,
        root: ExecutionIdentity,
        endedAt: Date?
    ) -> AgentSession {
        AgentSession(
            id: id,
            agent: AgentDefinition.defaults[0],
            root: root,
            project: nil,
            startedAt: now,
            endedAt: endedAt,
            endReason: endedAt == nil ? nil : "exit",
            evidence: .observed)
    }

    private func makeActivity(
        execution: ExecutionIdentity?,
        revision: Int64,
        sourcePath: String?
    ) -> ActivityRecord {
        ActivityRecord(
            id: 0,
            captureID: "capture",
            sourceSequence: nil,
            execution: execution,
            occurredAt: now,
            kind: .open,
            sourcePath: sourcePath,
            targetPath: nil,
            fileIdentity: nil,
            projectRoot: nil,
            sessionIDs: [],
            evidence: .observed,
            configurationRevision: revision,
            mode: .recordOnly,
            evaluation: .notEvaluated,
            response: .notApplicable,
            matchedRuleIDs: [],
            detail: nil)
    }

    private func makeBatch(
        executions: [ExecutionRecord],
        sessions: [AgentSession],
        activities: [ActivityRecord]
    ) -> IngestionBatch {
        IngestionBatch(
            capture: makeCapture(),
            graph: GraphSnapshot(executions: executions, sessions: sessions),
            activities: activities)
    }
}

private final class GraphBox: @unchecked Sendable {
    private let lock = NSLock()
    private var graph = GraphSnapshot()

    func read() -> GraphSnapshot {
        lock.withLock { graph }
    }

    func write(_ value: GraphSnapshot) {
        lock.withLock { graph = value }
    }
}

private final class WatermarkLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []

    func append(_ value: Int64) {
        lock.withLock { storage.append(value) }
    }

    var values: [Int64] {
        lock.withLock { storage }
    }
}

private actor Flag {
    private(set) var value = false

    func set() { value = true }
}

private actor OrderLog {
    private(set) var values: [String] = []

    func append(_ value: String) { values.append(value) }
}

private actor AsyncGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}

/// Holds the first store lookup so a persistence pass is genuinely in flight when the
/// retention boundary is taken.
private actor BlockingStoreProvider {
    private let store: ActivityStore
    private let blocked = Flag()
    private let gate = AsyncGate()

    init(store: ActivityStore) {
        self.store = store
    }

    func store() async throws -> ActivityStore {
        let isBlocked = await blocked.value
        if !isBlocked {
            await blocked.set()
            await gate.wait()
        }
        return store
    }

    func waitUntilBlocked() async {
        while true {
            if await blocked.value { return }
            await Task.yield()
        }
    }

    func release() async {
        await gate.open()
    }
}

private actor FailingStoreProvider {
    private let wrapped: ActivityStore
    private var failed = false

    init(store: ActivityStore) {
        self.wrapped = store
    }

    func store() throws -> ActivityStore {
        if !failed {
            failed = true
            throw POSIXError(.EIO)
        }
        return wrapped
    }
}
