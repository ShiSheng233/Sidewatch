import Foundation
import XCTest

final class HistoryRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
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

    func testRetentionRemovesOldActivitiesButKeepsLiveSourceChain() async throws {
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }
        try await saveRetentionConfiguration(store, revision: 2, days: 1)

        let agent = makeExecution(
            pid: 400, start: daysAgo(10), executable: "/usr/bin/claude",
            arguments: ["claude"])
        let service = makeExecution(
            pid: 401, start: daysAgo(10), parent: agent.identity,
            executable: "/usr/bin/server", arguments: ["server"])
        let dead = makeExecution(
            pid: 402, start: daysAgo(20), state: .exited, endedAt: daysAgo(20))
        let edge = ExecutionEdge(
            parent: agent.identity, child: service.identity,
            kind: .fork, evidence: .observed, observedAt: daysAgo(10))
        let session = makeSession(
            id: "session-pinned",
            root: agent.identity,
            startedAt: daysAgo(10),
            endedAt: daysAgo(9))
        let association = ExecutionAssociation(
            execution: service.identity, sessionID: session.id, evidence: .observed)

        let serviceActivity = makeActivity(
            execution: service.identity, occurredAt: daysAgo(10), revision: 2,
            sourcePath: "/tmp/old-service")
        let deadActivity = makeActivity(
            execution: dead.identity, occurredAt: daysAgo(10), revision: 2,
            sourcePath: "/tmp/old-dead")

        _ = try await store.ingest(
            makeBatch(
                captureStartedAt: daysAgo(25),
                executions: [agent, service, dead],
                edges: [edge],
                sessions: [session],
                associations: [association],
                activities: [serviceActivity, deadActivity]))

        var query = ActivityQuery()
        query.limit = 100
        let before = try await store.page(query)
        XCTAssertEqual(before.activities.count, 2)

        try await store.retain(now: now)

        let after = try await store.page(query)
        XCTAssertTrue(after.activities.isEmpty)

        let graph = try await store.graph()
        let identities = Set(graph.executions.map(\.identity))
        XCTAssertTrue(identities.contains(agent.identity))
        XCTAssertTrue(identities.contains(service.identity))
        XCTAssertFalse(identities.contains(dead.identity))
        XCTAssertEqual(graph.edges.count, 1)
        XCTAssertEqual(graph.sessions.map(\.id), [session.id])
        XCTAssertEqual(graph.associations.count, 1)
        XCTAssertTrue(graph.executions.allSatisfy { $0.state == .unknown })

        let configuration = try await store.configuration()
        XCTAssertEqual(configuration.revision, 2)
        XCTAssertEqual(configuration.retentionDays, 1)
    }

    func testRetentionKeepsDeadAncestorAndSessionOfLiveService() async throws {
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }
        try await saveRetentionConfiguration(store, revision: 2, days: 1)

        let ancestor = makeExecution(
            pid: 500, start: daysAgo(30), state: .exited, endedAt: daysAgo(30),
            executable: "/usr/bin/claude", arguments: ["claude"])
        let service = makeExecution(
            pid: 501, start: daysAgo(30), parent: ancestor.identity,
            executable: "/usr/bin/server", arguments: ["server"])
        let edge = ExecutionEdge(
            parent: ancestor.identity, child: service.identity,
            kind: .fork, evidence: .observed, observedAt: daysAgo(30))
        let session = makeSession(
            id: "session-ancestor",
            root: ancestor.identity,
            startedAt: daysAgo(31),
            endedAt: daysAgo(31))

        _ = try await store.ingest(
            makeBatch(
                captureStartedAt: daysAgo(35),
                executions: [ancestor, service],
                edges: [edge],
                sessions: [session]))

        try await store.retain(now: now)

        let graph = try await store.graph()
        let identities = Set(graph.executions.map(\.identity))
        XCTAssertTrue(identities.contains(ancestor.identity))
        XCTAssertTrue(identities.contains(service.identity))
        XCTAssertEqual(graph.edges.count, 1)
        XCTAssertEqual(graph.sessions.map(\.id), [session.id])
    }

    func testRetentionKeepsRecentActivitiesAndActiveEndpoints() async throws {
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }
        try await saveRetentionConfiguration(store, revision: 2, days: 1)

        let service = makeExecution(
            pid: 600, start: daysAgo(30), executable: "/usr/bin/server",
            arguments: ["server"])
        let dead = makeExecution(
            pid: 601, start: daysAgo(30), state: .exited, endedAt: daysAgo(30))
        let activeEndpoint = ListeningEndpoint(
            execution: service.identity,
            transport: .tcp,
            address: "127.0.0.1",
            addressFamily: 2,
            scopeID: 0,
            port: 8081,
            firstObservedAt: daysAgo(30),
            lastObservedAt: now,
            endedAt: nil)
        let closedEndpoint = ListeningEndpoint(
            execution: dead.identity,
            transport: .tcp,
            address: "127.0.0.1",
            addressFamily: 2,
            scopeID: 0,
            port: 8082,
            firstObservedAt: daysAgo(30),
            lastObservedAt: daysAgo(10),
            endedAt: daysAgo(10))
        let recent = makeActivity(
            execution: service.identity,
            occurredAt: now.addingTimeInterval(-3_600),
            revision: 2,
            sourcePath: "/tmp/recent")

        _ = try await store.ingest(
            makeBatch(
                captureStartedAt: daysAgo(30),
                executions: [service, dead],
                activities: [recent],
                endpoints: [activeEndpoint, closedEndpoint]))

        try await store.retain(now: now)

        var query = ActivityQuery()
        query.limit = 100
        let page = try await store.page(query)
        XCTAssertEqual(page.activities.count, 1)
        XCTAssertEqual(page.activities.first?.sourcePath, "/tmp/recent")

        let snapshot = try await store.snapshot(
            health: MonitorHealth(availability: .active))
        XCTAssertEqual(snapshot.endpoints.count, 1)
        XCTAssertEqual(snapshot.endpoints.first?.port, 8081)
        XCTAssertEqual(snapshot.endpoints.first?.execution, service.identity)

        let graph = try await store.graph()
        XCTAssertFalse(graph.executions.contains { $0.identity == dead.identity })
    }

    func testClearHistoryKeepsPinnedLineageAndPreservesWatermark() async throws {
        let path = try makePath()
        let store = try ActivityStore(path: path)
        try await saveRetentionConfiguration(store, revision: 2, days: 1)

        let agent = makeExecution(
            pid: 700, start: daysAgo(10), state: .exited, endedAt: daysAgo(9), executable: "/usr/bin/claude",
            arguments: ["claude"])
        let service = makeExecution(
            pid: 701, start: daysAgo(10), parent: agent.identity,
            executable: "/usr/bin/server", arguments: ["server"])
        let edge = ExecutionEdge(
            parent: agent.identity, child: service.identity,
            kind: .fork, evidence: .observed, observedAt: daysAgo(10))
        let session = makeSession(
            id: "session-clear", root: agent.identity,
            startedAt: daysAgo(10), endedAt: daysAgo(9))
        let oldActivity = makeActivity(
            captureID: "capture-old",
            execution: service.identity, occurredAt: daysAgo(10), revision: 2,
            sourcePath: "/tmp/old")

        _ = try await store.ingest(
            makeBatch(
                captureID: "capture-old",
                captureStartedAt: daysAgo(25),
                executions: [agent, service],
                edges: [edge],
                sessions: [session],
                activities: [oldActivity]))

        var query = ActivityQuery()
        query.limit = 100
        let originalPage = try await store.page(query)
        let originalID = try XCTUnwrap(originalPage.activities.first?.id)
        let before = try await store.snapshot(
            health: MonitorHealth(availability: .active))
        let watermark = before.watermark

        let cleared = try await store.clearHistory()
        XCTAssertEqual(cleared, 1)

        let afterClear = try await store.snapshot(
            health: MonitorHealth(availability: .active))
        XCTAssertEqual(afterClear.watermark, watermark)
        let clearedPage = try await store.page(query)
        XCTAssertTrue(clearedPage.activities.isEmpty)

        let graph = try await store.graph()
        XCTAssertTrue(graph.executions.contains { $0.identity == agent.identity })
        XCTAssertTrue(graph.executions.contains { $0.identity == service.identity })
        XCTAssertEqual(graph.sessions.map(\.id), [session.id])
        XCTAssertEqual(graph.edges.count, 1)

        let configuration = try await store.configuration()
        XCTAssertEqual(configuration.revision, 2)

        let freshActivity = makeActivity(
            captureID: "capture-new",
            execution: service.identity,
            occurredAt: now,
            revision: 2,
            sourcePath: "/tmp/new")
        _ = try await store.ingest(
            makeBatch(
                captureID: "capture-new",
                captureStartedAt: now,
                executions: [agent, service],
                activities: [freshActivity]))

        var reconnect = ActivityQuery()
        reconnect.afterID = watermark
        reconnect.limit = 100
        reconnect.storeID = store.storeID
        let reconnectPage = try await store.page(reconnect)
        let newActivity = try XCTUnwrap(reconnectPage.activities.first)
        XCTAssertEqual(reconnectPage.activities.count, 1)
        XCTAssertGreaterThan(newActivity.id, originalID)
        XCTAssertGreaterThan(newActivity.id, watermark)

        try store.close()

        let reopened = try ActivityStore(path: path)
        XCTAssertEqual(reopened.storeID, before.storeID)
        let reopenedPage = try await reopened.page(reconnect)
        XCTAssertEqual(reopenedPage.activities.count, 1)
        XCTAssertEqual(reopenedPage.activities.first?.sourcePath, "/tmp/new")
        try reopened.close()
    }

    func testRetentionPreservesLaunchChainBeyondThirtyTwoAncestors() async throws {
        let store = try ActivityStore(path: makePath())
        try await saveRetentionConfiguration(store, revision: 2, days: 1)
        var chain: [ExecutionRecord] = []
        var edges: [ExecutionEdge] = []
        for index in 0..<48 {
            let parent = chain.last?.identity
            let execution = makeExecution(pid: Int32(1000 + index), start: daysAgo(10).addingTimeInterval(Double(index)),
                                          parent: parent, state: index == 47 ? .running : .exited,
                                          endedAt: index == 47 ? nil : daysAgo(9))
            if let parent { edges.append(.init(parent: parent, child: execution.identity, kind: .fork, evidence: .observed, observedAt: execution.startedAt)) }
            chain.append(execution)
        }
        let session = makeSession(id: "deep-source", root: chain[0].identity, startedAt: daysAgo(10), endedAt: daysAgo(9))
        _ = try await store.ingest(makeBatch(captureStartedAt: daysAgo(10), executions: chain, edges: edges, sessions: [session],
                                            associations: [.init(execution: chain[47].identity, sessionID: session.id, evidence: .observed)]))
        try await store.retain(now: now)
        let retained = try await store.graph()
        XCTAssertEqual(Set(retained.executions.map(\.identity)), Set(chain.map(\.identity)))
        XCTAssertEqual(retained.edges.count, 47)
        try store.close()
    }

    // MARK: - Helpers

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    private func saveRetentionConfiguration(
        _ store: ActivityStore,
        revision: Int64,
        days: Int
    ) async throws {
        var configuration = MonitorConfiguration()
        configuration.revision = revision
        configuration.mode = .recordOnly
        configuration.retentionDays = days
        try await store.saveConfiguration(configuration)
    }

    private func makePath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SidewatchRetentionTests-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory.appendingPathComponent("activity.sqlite").path
    }

    private func makeExecution(
        boot: String = "boot-retention-tests",
        pid: Int32,
        start: Date,
        parent: ExecutionIdentity? = nil,
        state: ExecutionState = .running,
        endedAt: Date? = nil,
        executable: String = "/usr/bin/tool",
        arguments: [String] = ["tool"]
    ) -> ExecutionRecord {
        ExecutionRecord(
            identity: ExecutionIdentity(
                process: ProcessIdentity(
                    bootID: boot,
                    pid: pid,
                    startTimeMicros: MicroTime.value(start)),
                version: 1),
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
            auditToken: nil)
    }

    private func makeSession(
        id: String,
        root: ExecutionIdentity,
        startedAt: Date,
        endedAt: Date?
    ) -> AgentSession {
        AgentSession(
            id: id,
            agent: AgentDefinition.defaults[0],
            root: root,
            project: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            endReason: endedAt == nil ? nil : "exit",
            evidence: .observed)
    }

    private func makeActivity(
        captureID: String = "capture",
        execution: ExecutionIdentity?,
        occurredAt: Date,
        revision: Int64,
        sourcePath: String?
    ) -> ActivityRecord {
        ActivityRecord(
            id: 0,
            captureID: captureID,
            sourceSequence: nil,
            execution: execution,
            occurredAt: occurredAt,
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
        captureID: String = "capture",
        captureStartedAt: Date,
        executions: [ExecutionRecord],
        edges: [ExecutionEdge] = [],
        sessions: [AgentSession] = [],
        associations: [ExecutionAssociation] = [],
        activities: [ActivityRecord] = [],
        endpoints: [ListeningEndpoint] = []
    ) -> IngestionBatch {
        IngestionBatch(
            capture: CaptureRecord(
                id: captureID,
                bootID: "boot-retention-tests",
                startedAt: captureStartedAt,
                endedAt: nil),
            graph: GraphSnapshot(
                executions: executions,
                edges: edges,
                sessions: sessions,
                associations: associations),
            activities: activities,
            endpoints: endpoints,
            gaps: [])
    }
}
