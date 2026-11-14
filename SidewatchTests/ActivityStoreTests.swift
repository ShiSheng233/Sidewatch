import Foundation
import XCTest

final class ActivityStoreTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
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

    // MARK: - Identity and cursors

    func testSnapshotPreservesCaptureBoundariesAndGapsAcrossReopen() async throws {
        let path = try makePath()
        let store = try ActivityStore(path: path)
        let gaps = [
            CollectionGap(captureID: "capture", occurredAt: baseDate.addingTimeInterval(1), reason: "sequenceGap", missingCount: 3),
            CollectionGap(captureID: "capture", occurredAt: baseDate.addingTimeInterval(2), reason: "collectionInterrupted", missingCount: nil),
        ]
        var batch = makeBatch(gaps: gaps)
        batch.capture.endedAt = baseDate.addingTimeInterval(3)
        _ = try await store.ingest(batch)
        try store.close()

        let reopened = try ActivityStore(path: path)
        defer { try? reopened.close() }
        let snapshot = try await reopened.snapshot(health: .init(availability: .unavailable))
        XCTAssertEqual(snapshot.captures.map(\.id), ["capture"])
        XCTAssertEqual(snapshot.captures.first?.bootID, "boot-activity-tests")
        XCTAssertEqual(snapshot.captures.first?.startedAt, baseDate)
        XCTAssertEqual(snapshot.captures.first?.endedAt, batch.capture.endedAt)
        XCTAssertEqual(snapshot.gaps, gaps)
        XCTAssertTrue(snapshot.graph.executions.isEmpty)
    }

    func testStoreIdentityPersistsAndMismatchedCursorIsRejected() async throws {
        let path = try makePath()
        let store = try ActivityStore(path: path)
        let identity = makeExecution(pid: 100, start: baseDate).identity
        let activity = makeActivity(
            sequence: 1, execution: identity, occurredAt: baseDate)

        _ = try await store.ingest(
            makeBatch(executions: [makeExecution(pid: 100, start: baseDate)],
                      activities: [activity]))

        let originalStoreID = store.storeID
        try store.close()

        let reopened = try ActivityStore(path: path)
        XCTAssertEqual(reopened.storeID, originalStoreID)

        var query = ActivityQuery()
        query.storeID = "a-different-store"
        do {
            _ = try await reopened.page(query)
            XCTFail("A cursor from another database must be rejected")
        } catch let error as ActivityStoreError {
            XCTAssertEqual(error, .storeIdentifierMismatch)
        }
        try reopened.close()

        let other = try ActivityStore(path: try makePath())
        XCTAssertNotEqual(other.storeID, originalStoreID)
        query.storeID = originalStoreID
        do {
            _ = try await other.page(query)
            XCTFail("A cursor from another database must be rejected")
        } catch let error as ActivityStoreError {
            XCTAssertEqual(error, .storeIdentifierMismatch)
        }
        try other.close()
    }

    func testClearHistoryPreservesWatermarkAndMonotonicSequence() async throws {
        let path = try makePath()
        let store = try ActivityStore(path: path)
        let execution = makeExecution(pid: 200, start: baseDate)
        _ = try await store.ingest(
            makeBatch(
                captureID: "capture-one",
                executions: [execution],
                activities: [
                    makeActivity(
                        captureID: "capture-one",
                        sequence: 10,
                        execution: execution.identity,
                        occurredAt: baseDate)
                ]))

        var firstPageQuery = ActivityQuery()
        firstPageQuery.limit = 10
        let firstPage = try await store.page(firstPageQuery)
        let originalID = try XCTUnwrap(firstPage.activities.first?.id)
        let watermark = firstPage.watermark

        let clearedCount = try await store.clearHistory()
        XCTAssertEqual(clearedCount, 1)
        try store.close()

        let reopened = try ActivityStore(path: path)
        var health = MonitorHealth(availability: .active)
        health.sqliteVersion = "stale"
        let cleared = try await reopened.snapshot(health: health)
        XCTAssertEqual(cleared.watermark, watermark)
        XCTAssertTrue(cleared.graph.sessions.isEmpty)

        _ = try await reopened.ingest(
            makeBatch(
                captureID: "capture-two",
                executions: [execution],
                activities: [
                    makeActivity(
                        captureID: "capture-two",
                        sequence: 1,
                        execution: execution.identity,
                        occurredAt: baseDate.addingTimeInterval(1))
                ]))

        var reconnect = ActivityQuery()
        reconnect.afterID = watermark
        reconnect.limit = 10
        reconnect.storeID = reopened.storeID
        let page = try await reopened.page(reconnect)

        let newActivity = try XCTUnwrap(page.activities.first)
        XCTAssertGreaterThan(newActivity.id, originalID)
        XCTAssertGreaterThan(newActivity.id, watermark)
        XCTAssertEqual(page.activities.count, 1)

        var capped = ActivityQuery()
        capped.watermark = watermark
        capped.limit = 10
        let cappedPage = try await reopened.page(capped)
        XCTAssertTrue(cappedPage.activities.isEmpty)
        try reopened.close()
    }

    func testQueryRejectsInvalidCursorsAndOutcomes() async throws {
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }

        var future = ActivityQuery()
        let current = try await store.snapshot(health: MonitorHealth(availability: .active))
        future.watermark = current.watermark + 1
        do {
            _ = try await store.page(future)
            XCTFail("A watermark from a newer database state must be rejected")
        } catch let error as ActivityStoreError {
            XCTAssertEqual(error, .invalidWatermark(current.watermark + 1))
        }

        var both = ActivityQuery()
        both.beforeID = 10
        both.afterID = 1
        do {
            _ = try await store.page(both)
            XCTFail("Two conflicting cursors must be rejected")
        } catch let error as ActivityStoreError {
            XCTAssertEqual(error, .invalidQuery("beforeID and afterID"))
        }

        var unknownOutcome = ActivityQuery()
        unknownOutcome.outcome = "not-a-real-outcome"
        do {
            _ = try await store.page(unknownOutcome)
            XCTFail("An unknown outcome filter must be rejected")
        } catch let error as ActivityStoreError {
            XCTAssertEqual(error, .invalidQuery("outcome"))
        }
    }

    // MARK: - Atomic graph and events

    func testInvalidActivityRollsBackTheWholeBatch() async throws {
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }

        let execution = makeExecution(pid: 300, start: baseDate)
        let invalid = makeActivity(
            sequence: 1,
            execution: execution.identity,
            occurredAt: baseDate,
            revision: 999)

        do {
            _ = try await store.ingest(
                makeBatch(executions: [execution], activities: [invalid]))
            XCTFail("An unknown configuration revision must reject the batch")
        } catch let error as ActivityStoreError {
            guard case .invalidActivity = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        let rolledBackGraph = try await store.graph()
        XCTAssertTrue(rolledBackGraph.executions.isEmpty)
        var query = ActivityQuery()
        query.limit = 10
        let rolledBackPage = try await store.page(query)
        XCTAssertTrue(rolledBackPage.activities.isEmpty)
        let rolledBackSnapshot = try await store.snapshot(
            health: MonitorHealth(availability: .active))
        XCTAssertTrue(rolledBackSnapshot.endpoints.isEmpty)
    }

    func testGraphRestoreDropsTokensAndReportsUnknownState() async throws {
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }

        let parent = makeExecution(
            pid: 400, start: baseDate, executable: "/usr/bin/claude",
            arguments: ["claude"])
        let child = makeExecution(
            pid: 401, start: baseDate.addingTimeInterval(1),
            parent: parent.identity, executable: "/usr/bin/server",
            arguments: ["server"], auditToken: Data([0x01, 0x02, 0x03]))
        let edge = ExecutionEdge(
            parent: parent.identity,
            child: child.identity,
            kind: .fork,
            evidence: .observed,
            observedAt: baseDate)
        let session = makeSession(
            id: "session-restore", root: parent.identity, startedAt: baseDate)
        let association = ExecutionAssociation(
            execution: child.identity, sessionID: session.id, evidence: .observed)
        let activity = makeActivity(
            sequence: 1, execution: child.identity, occurredAt: baseDate,
            sessionIDs: [session.id])

        _ = try await store.ingest(
            makeBatch(
                executions: [parent, child],
                edges: [edge],
                sessions: [session],
                associations: [association],
                activities: [activity]))

        let graph = try await store.graph()
        XCTAssertEqual(graph.executions.count, 2)
        XCTAssertEqual(graph.edges.count, 1)
        XCTAssertEqual(graph.sessions.count, 1)
        XCTAssertEqual(graph.associations.count, 1)

        XCTAssertTrue(graph.executions.allSatisfy { $0.state == .unknown })
        XCTAssertTrue(graph.executions.allSatisfy { $0.auditToken == nil })

        let restoredChild = try XCTUnwrap(
            graph.executions.first { $0.identity == child.identity })
        XCTAssertEqual(restoredChild.parent, parent.identity)
    }

    func testUniqueExecutionIdentityComponentsDoNotMerge() async throws {
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }

        let first = makeExecution(pid: 500, start: baseDate)
        let secondStart = makeExecution(
            pid: 500, start: baseDate.addingTimeInterval(10))
        let secondVersion = makeExecution(
            pid: 500, start: baseDate, version: 2)
        let otherBoot = makeExecution(
            boot: "boot-other", pid: 500, start: baseDate)

        _ = try await store.ingest(
            makeBatch(executions: [first, secondStart, secondVersion, otherBoot]))

        let graph = try await store.graph()
        XCTAssertEqual(graph.executions.count, 4)
        XCTAssertEqual(
            Set(graph.executions.map(\.identity.stableID)).count, 4)
    }

    // MARK: - Mode and response constraints

    func testModeResponseConstraints() async throws {
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }
        let execution = makeExecution(pid: 600, start: baseDate)

        var dryRun = MonitorConfiguration()
        dryRun.revision = 2
        dryRun.mode = .dryRun
        try await store.saveConfiguration(dryRun)

        let invalidDenial = makeActivity(
            sequence: nil,
            execution: execution.identity,
            occurredAt: baseDate,
            kind: .authorization,
            sessionIDs: [],
            revision: 2,
            mode: .dryRun,
            evaluation: .deny,
            response: .deny)
        do {
            _ = try await store.ingest(
                makeBatch(executions: [execution], activities: [invalidDenial]))
            XCTFail("Dry Run must never record an actual denial")
        } catch let error as ActivityStoreError {
            guard case .invalidActivity = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        let wouldBlock = makeActivity(
            sequence: nil,
            execution: execution.identity,
            occurredAt: baseDate,
            kind: .authorization,
            revision: 2,
            mode: .dryRun,
            evaluation: .deny,
            response: .allow,
            matchedRuleIDs: ["rule-1"])
        _ = try await store.ingest(
            makeBatch(executions: [execution], activities: [wouldBlock]))

        var wouldBlockQuery = ActivityQuery()
        wouldBlockQuery.outcome = "wouldBlock"
        let wouldBlockPage = try await store.page(wouldBlockQuery)
        XCTAssertEqual(wouldBlockPage.activities.count, 1)

        let failedResponse = makeActivity(
            sequence: nil,
            execution: execution.identity,
            occurredAt: baseDate.addingTimeInterval(0.5),
            kind: .authorization,
            revision: 2,
            mode: .dryRun,
            evaluation: .deny,
            response: .failed)
        _ = try await store.ingest(
            makeBatch(executions: [execution], activities: [failedResponse]))

        var failedQuery = ActivityQuery()
        failedQuery.outcome = "failed"
        let failedPage = try await store.page(failedQuery)
        XCTAssertEqual(failedPage.activities.count, 1)
        XCTAssertEqual(failedPage.activities.first?.response, .failed)

        var protect = MonitorConfiguration()
        protect.revision = 3
        protect.mode = .protect
        try await store.saveConfiguration(protect)

        let blocked = makeActivity(
            sequence: nil,
            execution: execution.identity,
            occurredAt: baseDate.addingTimeInterval(1),
            kind: .authorization,
            revision: 3,
            mode: .protect,
            evaluation: .deny,
            response: .deny,
            matchedRuleIDs: ["rule-1"])
        _ = try await store.ingest(
            makeBatch(executions: [execution], activities: [blocked]))

        var blockedQuery = ActivityQuery()
        blockedQuery.outcome = "blocked"
        let blockedPage = try await store.page(blockedQuery)
        XCTAssertEqual(blockedPage.activities.count, 1)

        let invalidProtect = makeActivity(
            sequence: nil,
            execution: execution.identity,
            occurredAt: baseDate.addingTimeInterval(2),
            kind: .authorization,
            revision: 3,
            mode: .protect,
            evaluation: .deny,
            response: .allow)
        do {
            _ = try await store.ingest(
                makeBatch(executions: [execution], activities: [invalidProtect]))
            XCTFail("Protect must record the actual denial")
        } catch let error as ActivityStoreError {
            guard case .invalidActivity = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        let recordOnlyDenial = makeActivity(
            sequence: nil,
            execution: execution.identity,
            occurredAt: baseDate,
            kind: .open,
            response: .deny)
        do {
            _ = try await store.ingest(
                makeBatch(executions: [execution], activities: [recordOnlyDenial]))
            XCTFail("Record Only cannot record a system denial")
        } catch let error as ActivityStoreError {
            guard case .invalidActivity = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        let missingResponse = makeActivity(
            sequence: nil,
            execution: execution.identity,
            occurredAt: baseDate,
            kind: .authorization,
            revision: 3,
            mode: .protect,
            evaluation: .allow,
            response: .notApplicable)
        do {
            _ = try await store.ingest(
                makeBatch(executions: [execution], activities: [missingResponse]))
            XCTFail("An authorization event must carry a system response")
        } catch let error as ActivityStoreError {
            guard case .invalidActivity = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        let wrongMode = makeActivity(
            sequence: nil,
            execution: execution.identity,
            occurredAt: baseDate,
            kind: .authorization,
            revision: 1,
            mode: .dryRun,
            evaluation: .allow,
            response: .allow)
        do {
            _ = try await store.ingest(
                makeBatch(executions: [execution], activities: [wrongMode]))
            XCTFail("Activity mode must match the configuration revision")
        } catch let error as ActivityStoreError {
            guard case .invalidActivity = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    // MARK: - Filters and pagination

    func testFiltersAreLiteralAndPortUsesEndpointJoin() async throws {
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }

        let first = makeExecution(
            pid: 700, start: baseDate, executable: "/usr/bin/tool",
            arguments: ["tool", "a%b"])
        let second = makeExecution(
            pid: 701, start: baseDate, executable: "/usr/bin/tool",
            arguments: ["tool", "axb"])
        let session = makeSession(
            id: "session-filter", root: first.identity, startedAt: baseDate)
        let association = ExecutionAssociation(
            execution: first.identity, sessionID: session.id, evidence: .observed)
        let endpoint = ListeningEndpoint(
            execution: first.identity,
            transport: .tcp,
            address: "127.0.0.1",
            addressFamily: 2,
            scopeID: 0,
            port: 8080,
            firstObservedAt: baseDate,
            lastObservedAt: baseDate,
            endedAt: nil)

        let firstActivity = makeActivity(
            sequence: 1,
            execution: first.identity,
            occurredAt: baseDate,
            kind: .open,
            sourcePath: "/tmp/report_2024.txt",
            projectRoot: "/tmp/projectA",
            sessionIDs: [session.id])
        let secondActivity = makeActivity(
            sequence: 2,
            execution: second.identity,
            occurredAt: baseDate.addingTimeInterval(1),
            kind: .open,
            sourcePath: "/tmp/reportX2024.txt")

        _ = try await store.ingest(
            makeBatch(
                executions: [first, second],
                sessions: [session],
                associations: [association],
                activities: [firstActivity, secondActivity],
                endpoints: [endpoint]))

        func ids(for query: ActivityQuery) async throws -> Set<Int64> {
            let page = try await store.page(query)
            return Set(page.activities.map(\.id))
        }

        var literalPercent = ActivityQuery()
        literalPercent.text = "a%b"
        literalPercent.limit = 10
        let percentIDs = try await ids(for: literalPercent)
        XCTAssertEqual(percentIDs.count, 1)

        var literalUnderscore = ActivityQuery()
        literalUnderscore.text = "report_"
        literalUnderscore.limit = 10
        let underscoreIDs = try await ids(for: literalUnderscore)
        XCTAssertEqual(underscoreIDs.count, 1)
        XCTAssertEqual(underscoreIDs, percentIDs)

        var portQuery = ActivityQuery()
        portQuery.text = "8080"
        portQuery.limit = 10
        let portIDs = try await ids(for: portQuery)
        XCTAssertEqual(portIDs, percentIDs)

        var kindQuery = ActivityQuery()
        kindQuery.kind = .open
        kindQuery.limit = 10
        let kindPage = try await store.page(kindQuery)
        XCTAssertEqual(kindPage.activities.count, 2)

        var executionQuery = ActivityQuery()
        executionQuery.execution = first.identity
        executionQuery.limit = 10
        let executionIDs = try await ids(for: executionQuery)
        XCTAssertEqual(executionIDs, percentIDs)

        var sessionQuery = ActivityQuery()
        sessionQuery.sessionID = session.id
        sessionQuery.limit = 10
        let sessionFilteredIDs = try await ids(for: sessionQuery)
        XCTAssertEqual(sessionFilteredIDs, percentIDs)

        var projectQuery = ActivityQuery()
        projectQuery.projectRoot = "/tmp/projectA"
        projectQuery.limit = 10
        let projectIDs = try await ids(for: projectQuery)
        XCTAssertEqual(projectIDs, percentIDs)

        var outcomeQuery = ActivityQuery()
        outcomeQuery.outcome = "notApplicable"
        outcomeQuery.limit = 10
        let outcomePage = try await store.page(outcomeQuery)
        XCTAssertEqual(outcomePage.activities.count, 2)

        var allQuery = ActivityQuery()
        allQuery.limit = 10
        let allPage = try await store.page(allQuery)
        let allIDs = allPage.activities.map(\.id).sorted()
        XCTAssertEqual(allIDs.count, 2)
        let oldestID = try XCTUnwrap(allIDs.first)
        let newestID = try XCTUnwrap(allIDs.last)

        var olderPage = ActivityQuery()
        olderPage.beforeID = newestID + 1
        olderPage.limit = 10
        let olderPageResult = try await store.page(olderPage)
        let descending = olderPageResult.activities.map(\.id)
        XCTAssertEqual(descending, descending.sorted(by: >))

        var newerPage = ActivityQuery()
        newerPage.afterID = oldestID - 1
        newerPage.limit = 10
        let newerPageResult = try await store.page(newerPage)
        let ascending = newerPageResult.activities.map(\.id)
        XCTAssertEqual(ascending, ascending.sorted())
        XCTAssertEqual(ascending.count, 2)
    }

    func testNumericSearchMatchesEndpointWithoutTextMatch() async throws {
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }

        let execution = makeExecution(
            pid: 750, start: baseDate, executable: "/usr/bin/npm",
            arguments: ["npm", "run", "dev"])
        let endpoint = ListeningEndpoint(
            execution: execution.identity,
            transport: .tcp,
            address: "127.0.0.1",
            addressFamily: 2,
            scopeID: 0,
            port: 3000,
            firstObservedAt: baseDate,
            lastObservedAt: baseDate,
            endedAt: nil)
        let activity = makeActivity(
            sequence: 1,
            execution: execution.identity,
            occurredAt: baseDate,
            kind: .open,
            sourcePath: "/tmp/plain")

        _ = try await store.ingest(
            makeBatch(
                executions: [execution],
                activities: [activity],
                endpoints: [endpoint]))

        var portQuery = ActivityQuery()
        portQuery.text = "3000"
        portQuery.limit = 10
        let portPage = try await store.page(portQuery)
        XCTAssertEqual(portPage.activities.count, 1)
        XCTAssertEqual(portPage.activities.first?.execution, execution.identity)

        var absentPortQuery = ActivityQuery()
        absentPortQuery.text = "3001"
        absentPortQuery.limit = 10
        let absentPage = try await store.page(absentPortQuery)
        XCTAssertTrue(absentPage.activities.isEmpty)
    }

    // MARK: - Configuration
    func testConfigurationIsImmutableAcrossReopen() async throws {
        let path = try makePath()
        let store = try ActivityStore(path: path)

        let initial = try await store.configuration()
        XCTAssertEqual(initial.revision, 1)
        XCTAssertEqual(initial.mode, .recordOnly)

        var configured = MonitorConfiguration()
        configured.revision = 2
        configured.mode = .dryRun
        configured.rules = [
            ProtectionRule(
                id: "rule-a",
                name: "Project A",
                target: .directory,
                path: "/tmp/projectA",
                operations: [.open, .delete],
                agentIDs: ["claude"])
        ]
        configured.retentionDays = 3
        configured.storageBudgetBytes = 64 * 1024 * 1024
        try await store.saveConfiguration(configured)

        let saved = try await store.configuration()
        XCTAssertEqual(saved, configured)

        // Same revision and same content is an idempotent retry.
        try await store.saveConfiguration(configured)

        var conflicting = configured
        conflicting.mode = .protect
        do {
            try await store.saveConfiguration(conflicting)
            XCTFail("An immutable revision cannot change content")
        } catch let error as ActivityStoreError {
            XCTAssertEqual(error, .configurationRevisionConflict(2))
        }

        do {
            try await store.saveConfiguration(initial)
            XCTFail("An older revision cannot be selected again")
        } catch let error as ActivityStoreError {
            XCTAssertEqual(error, .configurationRevisionConflict(1))
        }

        try store.close()
        let reopened = try ActivityStore(path: path)
        let reopenedConfiguration = try await reopened.configuration()
        XCTAssertEqual(reopenedConfiguration, configured)

        let snapshot = try await reopened.snapshot(
            health: MonitorHealth(availability: .active))
        XCTAssertEqual(snapshot.health.sqliteVersion, reopened.sqliteVersion)
        XCTAssertEqual(snapshot.configuration, configured)
        XCTAssertEqual(snapshot.storeID, reopened.storeID)
        try reopened.close()
    }

    // MARK: - Endpoint transitions

    func testEndpointIntervalsCloseOnlyWhenEndedAtIsSupplied() async throws {
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }
        let execution = makeExecution(pid: 800, start: baseDate)

        func endpoint(
            first: Date,
            last: Date,
            ended: Date?
        ) -> ListeningEndpoint {
            ListeningEndpoint(
                execution: execution.identity,
                transport: .tcp,
                address: "127.0.0.1",
                addressFamily: 2,
                scopeID: 0,
                port: 9000,
                firstObservedAt: first,
                lastObservedAt: last,
                endedAt: ended)
        }

        _ = try await store.ingest(
            makeBatch(
                executions: [execution],
                endpoints: [endpoint(first: baseDate, last: baseDate, ended: nil)]))
        var endpoints = try await store.snapshot(
            health: MonitorHealth(availability: .active)).endpoints
        XCTAssertEqual(endpoints.count, 1)
        XCTAssertNil(endpoints[0].endedAt)

        let later = baseDate.addingTimeInterval(30)
        _ = try await store.ingest(
            makeBatch(
                executions: [execution],
                endpoints: [endpoint(first: baseDate, last: later, ended: nil)]))
        endpoints = try await store.snapshot(
            health: MonitorHealth(availability: .active)).endpoints
        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(
            endpoints[0].lastObservedAt.timeIntervalSince1970,
            later.timeIntervalSince1970,
            accuracy: 0.000_001)

        let closedAt = later.addingTimeInterval(5)
        _ = try await store.ingest(
            makeBatch(
                executions: [execution],
                endpoints: [
                    endpoint(first: baseDate, last: closedAt, ended: closedAt)
                ]))
        let closedSnapshot = try await store.snapshot(
            health: MonitorHealth(availability: .active))
        XCTAssertTrue(closedSnapshot.endpoints.isEmpty)

        let reopenedAt = closedAt.addingTimeInterval(60)
        _ = try await store.ingest(
            makeBatch(
                executions: [execution],
                endpoints: [
                    endpoint(first: reopenedAt, last: reopenedAt, ended: nil)
                ]))
        endpoints = try await store.snapshot(
            health: MonitorHealth(availability: .active)).endpoints
        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(
            endpoints[0].firstObservedAt.timeIntervalSince1970,
            reopenedAt.timeIntervalSince1970,
            accuracy: 0.000_001)
    }

    // MARK: - Control audit

    func testControlActionRequiresKnownExecution() async throws {
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }
        let execution = makeExecution(pid: 900, start: baseDate)
        _ = try await store.ingest(makeBatch(executions: [execution]))

        try await store.recordControl(
            ControlAction(
                execution: execution.identity,
                operation: .stop,
                requestedAt: baseDate,
                signalSent: true,
                exitConfirmed: false,
                errorCode: nil))

        let unknown = ExecutionIdentity(
            process: ProcessIdentity(
                bootID: "missing-boot",
                pid: 1,
                startTimeMicros: 1),
            version: 1)
        do {
            try await store.recordControl(
                ControlAction(
                    execution: unknown,
                    operation: .forceQuit,
                    requestedAt: baseDate,
                    signalSent: false,
                    exitConfirmed: false,
                    errorCode: 1))
            XCTFail("A control action for an unknown execution must be rejected")
        } catch let error as ActivityStoreError {
            XCTAssertEqual(error, .unknownExecution)
        }
    }

    // MARK: - Erase all

    func testEraseAllRemovesEveryRowAndResetsConfigurationToNextRevision() async throws {
        let path = try makePath()
        let store = try ActivityStore(path: path)
        var configured = MonitorConfiguration()
        configured.revision = 2
        configured.mode = .dryRun
        configured.retentionDays = 30
        configured.rules = [ProtectionRule(name: "Temp", target: .directory, path: "/tmp", operations: [.delete])]
        try await store.saveConfiguration(configured)

        // A running execution is kept by Clear History; Erase All must remove it too.
        let running = makeExecution(pid: 300, start: baseDate)
        let session = makeSession(id: "session-erase", root: running.identity, startedAt: baseDate)
        _ = try await store.ingest(makeBatch(
            executions: [running],
            sessions: [session],
            associations: [ExecutionAssociation(execution: running.identity, sessionID: session.id, evidence: .observed)],
            activities: [makeActivity(sequence: 1, execution: running.identity, occurredAt: baseDate,
                                      sessionIDs: [session.id], revision: 2, mode: .dryRun)],
            gaps: [CollectionGap(captureID: "capture", occurredAt: baseDate, reason: "sequenceGap", missingCount: 1)]))
        try await store.recordControl(ControlAction(
            id: "control-erase", execution: running.identity, operation: .stop, requestedAt: baseDate,
            signalSent: true, exitConfirmed: false, errorCode: nil))
        let before = try await store.page(.init(limit: 10))
        let originalID = try XCTUnwrap(before.activities.first?.id)

        let reset = try await store.eraseAll()
        XCTAssertEqual(reset.revision, 3)
        XCTAssertEqual(reset.mode, .recordOnly)
        XCTAssertTrue(reset.rules.isEmpty)
        XCTAssertEqual(reset.retentionDays, MonitorConfiguration().retentionDays)
        XCTAssertEqual(reset.agentDefinitions, AgentDefinition.defaults)
        try store.close()

        let reopened = try ActivityStore(path: path)
        defer { try? reopened.close() }
        let snapshot = try await reopened.snapshot(health: .init(availability: .active))
        XCTAssertEqual(snapshot.configuration, reset)
        XCTAssertTrue(snapshot.graph.executions.isEmpty)
        XCTAssertTrue(snapshot.graph.sessions.isEmpty)
        XCTAssertTrue(snapshot.graph.edges.isEmpty)
        XCTAssertTrue(snapshot.captures.isEmpty)
        XCTAssertTrue(snapshot.gaps.isEmpty)
        XCTAssertNil(snapshot.oldestActivity)
        XCTAssertEqual(snapshot.watermark, before.watermark)
        let emptied = try await reopened.page(.init(limit: 10))
        XCTAssertTrue(emptied.activities.isEmpty)

        // Revisions and activity IDs keep moving forward after an erase.
        var next = reset
        next.revision = 4
        try await reopened.saveConfiguration(next)
        _ = try await reopened.ingest(makeBatch(
            captureID: "capture-after",
            executions: [running],
            activities: [makeActivity(captureID: "capture-after", sequence: 1, execution: running.identity,
                                      occurredAt: baseDate.addingTimeInterval(5), revision: 4)]))
        let after = try await reopened.page(.init(limit: 10))
        XCTAssertGreaterThan(try XCTUnwrap(after.activities.first?.id), originalID)
    }

    // MARK: - Fixtures

    private func makePath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SidewatchActivityStoreTests-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory.appendingPathComponent("activity.sqlite").path
    }

    private func makeExecution(
        boot: String = "boot-activity-tests",
        pid: Int32,
        start: Date,
        version: UInt32 = 1,
        parent: ExecutionIdentity? = nil,
        state: ExecutionState = .running,
        endedAt: Date? = nil,
        executable: String = "/usr/bin/tool",
        arguments: [String] = ["tool"],
        auditToken: Data? = nil
    ) -> ExecutionRecord {
        ExecutionRecord(
            identity: ExecutionIdentity(
                process: ProcessIdentity(
                    bootID: boot,
                    pid: pid,
                    startTimeMicros: MicroTime.value(start)),
                version: version),
            parent: parent,
            responsible: nil,
            parentPID: 1,
            userID: 501,
            executable: executable,
            arguments: arguments,
            workingDirectory: nil,
            signingID: nil,
            teamID: nil,
            startedAt: start,
            endedAt: endedAt,
            state: state,
            evidence: .observed,
            auditToken: auditToken)
    }

    private func makeSession(
        id: String,
        root: ExecutionIdentity,
        startedAt: Date,
        endedAt: Date? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            agent: AgentDefinition.defaults[0],
            root: root,
            project: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            endReason: nil,
            evidence: .observed)
    }

    private func makeActivity(
        captureID: String = "capture",
        sequence: UInt64?,
        execution: ExecutionIdentity?,
        occurredAt: Date,
        kind: ActivityKind = .open,
        sourcePath: String? = nil,
        targetPath: String? = nil,
        projectRoot: String? = nil,
        sessionIDs: [String] = [],
        revision: Int64 = 1,
        mode: MonitoringMode = .recordOnly,
        evaluation: RuleEvaluation = .notEvaluated,
        response: SystemResponse = .notApplicable,
        matchedRuleIDs: [String] = [],
        detail: String? = nil
    ) -> ActivityRecord {
        ActivityRecord(
            id: 0,
            captureID: captureID,
            sourceSequence: sequence,
            execution: execution,
            occurredAt: occurredAt,
            kind: kind,
            sourcePath: sourcePath,
            targetPath: targetPath,
            fileIdentity: nil,
            projectRoot: projectRoot,
            sessionIDs: sessionIDs,
            evidence: .observed,
            configurationRevision: revision,
            mode: mode,
            evaluation: evaluation,
            response: response,
            matchedRuleIDs: matchedRuleIDs,
            detail: detail)
    }

    private func makeBatch(
        captureID: String = "capture",
        bootID: String = "boot-activity-tests",
        captureStartedAt: Date? = nil,
        executions: [ExecutionRecord] = [],
        edges: [ExecutionEdge] = [],
        sessions: [AgentSession] = [],
        associations: [ExecutionAssociation] = [],
        activities: [ActivityRecord] = [],
        endpoints: [ListeningEndpoint] = [],
        gaps: [CollectionGap] = []
    ) -> IngestionBatch {
        IngestionBatch(
            capture: CaptureRecord(
                id: captureID,
                bootID: bootID,
                startedAt: captureStartedAt ?? baseDate,
                endedAt: nil),
            graph: GraphSnapshot(
                executions: executions,
                edges: edges,
                sessions: sessions,
                associations: associations),
            activities: activities,
            endpoints: endpoints,
            gaps: gaps)
    }
}
