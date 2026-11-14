import Foundation
import XCTest

/// Persistence contract for an execution identity that is first described by a native
/// process baseline and later by the exact Endpoint Security observation. Storage keeps
/// the directly observed execution start, never resurrects the synthetic snapshot-only
/// identity, and keeps one session per root process.
final class ExecutionIdentityStorageTests: XCTestCase {
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

    func testObservedExecutionStartIsNotDowngradedByMetadataBaselines() async throws {
        let path = try makePath()
        let store = try ActivityStore(path: path)
        defer { try? store.close() }
        try await saveConfiguration(store)

        let baseline = now.addingTimeInterval(-600)
        let execStart = now
        _ = try await store.ingest(makeBatch(executions: [
            makeExecution(version: 1, startedAt: baseline, evidence: .snapshot)
        ]))
        _ = try await store.ingest(makeBatch(executions: [
            makeExecution(version: 1, startedAt: execStart, evidence: .observed)
        ]))

        var records = try await store.graph().executions
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.evidence, .observed)
        XCTAssertEqual(records.first?.startedAt, execStart)

        // A later metadata refresh still carries the process creation baseline.
        _ = try await store.ingest(makeBatch(executions: [
            makeExecution(version: 1, startedAt: baseline, evidence: .snapshot)
        ]))
        records = try await store.graph().executions
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.evidence, .observed)
        XCTAssertEqual(records.first?.startedAt, execStart)
    }

    func testVersionsOfOneProcessKeepTheirOwnStartDates() async throws {
        let store = try ActivityStore(path: try makePath())
        defer { try? store.close() }
        try await saveConfiguration(store)

        let baseline = now.addingTimeInterval(-600)
        let execStart = now
        let placeholder = makeExecution(version: 0, startedAt: baseline, evidence: .snapshot)
        let observed = makeExecution(version: 3, startedAt: execStart, evidence: .observed)

        // Both rows are in the batch, so the engine still keeps the snapshot identity.
        _ = try await store.ingest(makeBatch(executions: [placeholder, observed]))
        var dates = Dictionary(
            try await store.graph().executions.map { ($0.identity, $0.startedAt) },
            uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(dates[placeholder.identity], baseline)
        XCTAssertEqual(dates[observed.identity], execStart)

        _ = try await store.ingest(makeBatch(executions: [
            makeExecution(version: 3, startedAt: baseline, evidence: .snapshot)
        ]))
        dates = Dictionary(
            try await store.graph().executions.map { ($0.identity, $0.startedAt) },
            uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(dates[placeholder.identity], baseline)
        XCTAssertEqual(dates[observed.identity], execStart)
    }

    func testPromotionKeepsCanonicalRootAndObservedExitClosesIt() async throws {
        let path = try makePath()
        let store = try ActivityStore(path: path)
        try await saveConfiguration(store)

        let baseline = now.addingTimeInterval(-600)
        let process = ProcessIdentity(
            bootID: "boot-identity-tests",
            pid: 900,
            startTimeMicros: MicroTime.value(baseline))
        let placeholder = makeExecution(
            process: process, version: 0, startedAt: baseline,
            evidence: .snapshot, state: .running)
        let observed = makeExecution(
            process: process, version: 7, startedAt: now,
            evidence: .observed, state: .running,
            executable: "/usr/bin/claude", arguments: ["claude"])
        let sessionID = "session:\(placeholder.identity.stableID)"
        let session = makeSession(id: sessionID, root: placeholder.identity, endedAt: nil)
        let before = makeActivity(
            execution: placeholder.identity, session: session, sourcePath: "/tmp/before")
        _ = try await store.ingest(makeBatch(
            executions: [placeholder], sessions: [session], activities: [before]))

        // The exact observation associates with the canonical placeholder-rooted session
        // instead of re-rooting or retiring it.
        let after = makeActivity(
            execution: observed.identity, session: session, sourcePath: "/tmp/after")
        _ = try await store.ingest(makeBatch(
            executions: [placeholder, observed],
            sessions: [session],
            associations: [
                .init(execution: placeholder.identity, sessionID: session.id, evidence: .snapshot),
                .init(execution: observed.identity, sessionID: session.id, evidence: .observed),
            ],
            activities: [after]))

        var graph = try await store.graph()
        XCTAssertEqual(
            Set(graph.executions.map(\.identity)),
            [placeholder.identity, observed.identity])
        XCTAssertEqual(graph.sessions.map(\.id), [sessionID])
        XCTAssertEqual(graph.sessions.map(\.root), [placeholder.identity])
        // Neither execution is retired by the promotion. Persisted live state reads back
        // as unknown (UIBuilderInterfaces: ExecutionState), never as a recorded exit.
        XCTAssertTrue(graph.executions.allSatisfy { $0.state == .unknown })
        var page = try await page(store)
        XCTAssertEqual(page.activities.map(\.execution), [observed.identity, placeholder.identity])

        // An observed exit of the exact identity also ends the placeholder for that
        // process, so a reopen cannot show it as permanently live.
        let endedAt = now.addingTimeInterval(30)
        let exited = makeExecution(
            process: process, version: 7, startedAt: now, evidence: .observed,
            state: .exited, endedAt: endedAt,
            executable: "/usr/bin/claude", arguments: ["claude"])
        let endedSession = makeSession(
            id: sessionID, root: placeholder.identity, endedAt: endedAt,
            endReason: "processExited")
        _ = try await store.ingest(makeBatch(
            executions: [exited],
            sessions: [endedSession],
            associations: [
                .init(execution: exited.identity, sessionID: sessionID, evidence: .observed)
            ]))

        try store.close()
        let reopened = try ActivityStore(path: path)
        defer { try? reopened.close() }
        graph = try await reopened.graph()
        XCTAssertEqual(graph.executions.count, 2)
        XCTAssertTrue(graph.executions.allSatisfy { $0.state == .exited && $0.endedAt == endedAt })
        XCTAssertEqual(graph.sessions.map(\.id), [sessionID])
        XCTAssertEqual(graph.sessions.map(\.root), [placeholder.identity])
        XCTAssertEqual(graph.sessions.first?.endedAt, endedAt)
        page = try await self.page(reopened)
        XCTAssertEqual(page.activities.count, 2)
    }

    func testImageReplacingExecRetiresThePlaceholderAndLeavesOneLiveRoot() async throws {
        let path = try makePath()
        let store = try ActivityStore(path: path)
        try await saveConfiguration(store)

        let baseline = now.addingTimeInterval(-600)
        let process = ProcessIdentity(
            bootID: "boot-identity-tests",
            pid: 901,
            startTimeMicros: MicroTime.value(baseline))
        let placeholder = makeExecution(
            process: process, version: 0, startedAt: baseline,
            evidence: .snapshot, state: .running)
        let sessionID = "session:\(placeholder.identity.stableID)"
        let session = makeSession(id: sessionID, root: placeholder.identity, endedAt: nil)
        _ = try await store.ingest(makeBatch(
            executions: [placeholder], sessions: [session]))

        // The observed exec replaces the image; the engine drops the placeholder and
        // starts a session rooted at the exact execution.
        let replacement = makeExecution(
            process: process, version: 4, startedAt: now,
            evidence: .observed, state: .running,
            executable: "/usr/bin/claude", arguments: ["claude"])
        let replacementID = "session:\(replacement.identity.stableID)"
        let oldSession = makeSession(
            id: sessionID, root: placeholder.identity,
            endedAt: now, endReason: "replaced")
        let newSession = makeSession(id: replacementID, root: replacement.identity, endedAt: nil)
        _ = try await store.ingest(makeBatch(
            executions: [replacement],
            sessions: [oldSession, newSession],
            associations: [
                .init(execution: replacement.identity, sessionID: replacementID, evidence: .observed)
            ]))

        var graph = try await store.graph()
        XCTAssertEqual(Set(graph.executions.map(\.identity)), [placeholder.identity, replacement.identity])
        let live = graph.executions.filter { $0.state != .exited }
        XCTAssertEqual(live.map(\.identity), [replacement.identity])
        XCTAssertEqual(
            graph.executions.first { $0.identity == placeholder.identity }?.endedAt,
            now)
        XCTAssertEqual(
            Set(graph.sessions.map(\.id)), [sessionID, replacementID])

        try store.close()
        let reopened = try ActivityStore(path: path)
        defer { try? reopened.close() }
        graph = try await reopened.graph()
        XCTAssertEqual(
            graph.executions.filter { $0.state != .exited }.map(\.identity),
            [replacement.identity])
        XCTAssertEqual(Set(graph.sessions.map(\.id)), [sessionID, replacementID])
    }

    // MARK: - Helpers

    private func page(_ store: ActivityStore) async throws -> ActivityPage {
        var query = ActivityQuery()
        query.limit = 100
        return try await store.page(query)
    }

    private func saveConfiguration(_ store: ActivityStore) async throws {
        var configuration = MonitorConfiguration()
        configuration.revision = 2
        configuration.mode = .recordOnly
        configuration.retentionDays = 1
        try await store.saveConfiguration(configuration)
    }

    private func makePath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidewatchIdentityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory.appendingPathComponent("activity.sqlite").path
    }

    private func makeExecution(
        process: ProcessIdentity? = nil,
        version: UInt32,
        startedAt: Date,
        evidence: EvidenceKind,
        state: ExecutionState = .running,
        endedAt: Date? = nil,
        executable: String = "/usr/bin/tool",
        arguments: [String] = ["tool"]
    ) -> ExecutionRecord {
        ExecutionRecord(
            identity: ExecutionIdentity(
                process: process ?? ProcessIdentity(
                    bootID: "boot-identity-tests",
                    pid: 500,
                    startTimeMicros: MicroTime.value(now.addingTimeInterval(-600))),
                version: version),
            parent: nil,
            responsible: nil,
            parentPID: 1,
            userID: 501,
            executable: executable,
            arguments: arguments,
            workingDirectory: nil,
            signingID: nil,
            teamID: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            state: state,
            evidence: evidence,
            auditToken: nil)
    }

    private func makeSession(
        id: String,
        root: ExecutionIdentity,
        endedAt: Date?,
        endReason: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            agent: AgentDefinition.defaults[0],
            root: root,
            project: nil,
            startedAt: now.addingTimeInterval(-600),
            endedAt: endedAt,
            endReason: endReason,
            evidence: .observed)
    }

    private func makeActivity(
        execution: ExecutionIdentity?,
        session: AgentSession,
        sourcePath: String
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
            sessionIDs: [session.id],
            evidence: .observed,
            configurationRevision: 2,
            mode: .recordOnly,
            evaluation: .notEvaluated,
            response: .notApplicable,
            matchedRuleIDs: [],
            detail: nil)
    }

    private func makeBatch(
        executions: [ExecutionRecord],
        sessions: [AgentSession] = [],
        associations: [ExecutionAssociation]? = nil,
        activities: [ActivityRecord] = []
    ) -> IngestionBatch {
        IngestionBatch(
            capture: CaptureRecord(
                id: "capture", bootID: "boot-identity-tests", startedAt: now, endedAt: nil),
            graph: GraphSnapshot(
                executions: executions,
                sessions: sessions,
                associations: associations ?? sessions.map { session in
                    ExecutionAssociation(
                        execution: session.root,
                        sessionID: session.id,
                        evidence: session.evidence)
                }),
            activities: activities)
    }
}
