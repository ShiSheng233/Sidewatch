import Foundation
import GRDB
import XCTest

final class DatabaseMigrationTests: XCTestCase {
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

    func testInitialMigrationCreatesTheShippedSchema() async throws {
        let path = try makePath()
        let store = try ActivityStore(path: path)
        let applied = try await store.appliedMigrations()
        XCTAssertEqual(applied, [DatabaseMigrations.v1Initial])
        XCTAssertEqual(store.schemaFormatVersion, DatabaseMigrations.latestFormatVersion)

        let number = Int(Database.sqliteLibVersionNumber)
        let expectedVersion =
            "\(number / 1_000_000).\((number / 1_000) % 1_000).\(number % 1_000)"
        XCTAssertEqual(store.sqliteVersion, expectedVersion)
        XCTAssertNotNil(
            store.sqliteVersion.range(
                of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression))

        let configuration = try await store.configuration()
        XCTAssertEqual(configuration.revision, 1)
        XCTAssertEqual(configuration.mode, .recordOnly)
        XCTAssertEqual(configuration.retentionDays, 7)
        XCTAssertEqual(configuration.rules, [])
        XCTAssertEqual(configuration.agentDefinitions, AgentDefinition.defaults)

        var query = ActivityQuery()
        query.limit = 10
        let page = try await store.page(query)
        XCTAssertTrue(page.activities.isEmpty)
        XCTAssertEqual(page.storeID, store.storeID)

        try store.close()

        try withRawPool(path: path) { pool in
            try pool.read { db in
                let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode")
                XCTAssertEqual(journalMode, "wal")
                let foreignKeys = try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
                XCTAssertEqual(foreignKeys, 1)

                let tables = Set(
                    try String.fetchAll(
                        db,
                        sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
                let expected: Set<String> = [
                    "activities", "activity_sessions", "agent_sessions", "boot_epochs",
                    "capture_gaps", "capture_runs", "configuration_versions",
                    "control_actions", "execution_edges", "execution_sessions",
                    "executions", "preferences", "process_instances", "projects",
                    "rule_matches", "store_metadata",
                ]
                XCTAssertTrue(tables.isSuperset(of: expected))

                let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
                XCTAssertTrue(violations.isEmpty)
            }
        }
    }

    func testReopenIsIdempotentAndKeepsData() async throws {
        let path = try makePath()
        let store = try ActivityStore(path: path)
        let execution = makeExecution()
        _ = try await store.ingest(
            makeBatch(
                executions: [execution],
                activities: [
                    makeActivity(execution: execution.identity)
                ]))
        let identifier = store.storeID
        try store.close()

        let reopened = try ActivityStore(path: path)
        XCTAssertEqual(reopened.storeID, identifier)
        let applied = try await reopened.appliedMigrations()
        XCTAssertEqual(applied, [DatabaseMigrations.v1Initial])

        let graph = try await reopened.graph()
        XCTAssertEqual(graph.executions.count, 1)
        XCTAssertEqual(graph.executions.first?.identity, execution.identity)

        var query = ActivityQuery()
        query.limit = 10
        let page = try await reopened.page(query)
        XCTAssertEqual(page.activities.count, 1)
        try reopened.close()

        try withRawPool(path: path) { pool in
            try pool.read { db in
                let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
                XCTAssertTrue(violations.isEmpty)
            }
        }
    }

    func testFutureMigrationIsRejectedWithoutErasingHistory() async throws {
        let path = try makePath()
        let store = try ActivityStore(path: path)
        let execution = makeExecution()
        _ = try await store.ingest(
            makeBatch(
                executions: [execution],
                activities: [makeActivity(execution: execution.identity)]))
        try store.close()

        try withRawPool(path: path) { pool in
            try pool.write { db in
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: ["v99_future"])
            }
        }

        XCTAssertThrowsError(try ActivityStore(path: path)) { error in
            guard let storeError = error as? ActivityStoreError,
                  case .futureSchema = storeError
            else {
                XCTFail("Expected a future schema rejection, got \(error)")
                return
            }
        }

        var applied: [String] = []
        var activityCount: Int = 0
        try withRawPool(path: path) { pool in
            try pool.read { db in
                applied = try String.fetchAll(
                    db, sql: "SELECT identifier FROM grdb_migrations")
                activityCount = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM activities") ?? 0
            }
        }
        XCTAssertTrue(applied.contains(DatabaseMigrations.v1Initial))
        XCTAssertTrue(applied.contains("v99_future"))
        XCTAssertEqual(activityCount, 1)

        try withRawPool(path: path) { pool in
            try pool.write { db in
                try db.execute(
                    sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                    arguments: ["v99_future"])
            }
        }

        let reopened = try ActivityStore(path: path)
        var query = ActivityQuery()
        query.limit = 10
        let page = try await reopened.page(query)
        XCTAssertEqual(page.activities.count, 1)
        try reopened.close()
    }

    func testFutureFormatVersionIsRejected() async throws {
        let path = try makePath()
        let store = try ActivityStore(path: path)
        try store.close()

        try withRawPool(path: path) { pool in
            try pool.write { db in
                try db.execute(
                    sql: "UPDATE store_metadata SET format_version = 99 WHERE id = 1")
            }
        }

        XCTAssertThrowsError(try ActivityStore(path: path)) { error in
            guard let storeError = error as? ActivityStoreError,
                  case .unsupportedSchemaVersion(99) = storeError
            else {
                XCTFail("Expected an unsupported schema rejection, got \(error)")
                return
            }
        }

        try withRawPool(path: path) { pool in
            try pool.write { db in
                try db.execute(
                    sql: "UPDATE store_metadata SET format_version = 1 WHERE id = 1")
            }
        }

        let reopened = try ActivityStore(path: path)
        let applied = try await reopened.appliedMigrations()
        XCTAssertEqual(applied, [DatabaseMigrations.v1Initial])
        try reopened.close()
    }

    func testFailedInitialMigrationRollsBackEverything() async throws {
        let path = try makePath()

        // Force the migration to fail after it has created several tables.
        try withRawPool(path: path) { pool in
            try pool.write { db in
                try db.execute(sql: "CREATE TABLE activities (id INTEGER PRIMARY KEY)")
            }
        }

        XCTAssertThrowsError(try ActivityStore(path: path))

        var applied: [String] = []
        try withRawPool(path: path) { pool in
            try pool.read { db in
                XCTAssertFalse(try db.tableExists("boot_epochs"))
                XCTAssertFalse(try db.tableExists("store_metadata"))
                XCTAssertTrue(try db.tableExists("activities"))
                if try db.tableExists("grdb_migrations") {
                    applied = try String.fetchAll(
                        db, sql: "SELECT identifier FROM grdb_migrations")
                }
            }
        }
        XCTAssertFalse(applied.contains(DatabaseMigrations.v1Initial))

        try withRawPool(path: path) { pool in
            try pool.write { db in
                try db.execute(sql: "DROP TABLE activities")
            }
        }

        let store = try ActivityStore(path: path)
        let appliedAfterRepair = try await store.appliedMigrations()
        XCTAssertEqual(appliedAfterRepair, [DatabaseMigrations.v1Initial])
        try store.close()
    }

    // MARK: - Helpers

    private func withRawPool(
        path: String,
        _ body: (DatabasePool) throws -> Void
    ) throws {
        let pool = try DatabasePool(path: path)
        defer { try? pool.close() }
        try body(pool)
    }

    private func makePath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SidewatchMigrationTests-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory.appendingPathComponent("activity.sqlite").path
    }

    private func makeExecution() -> ExecutionRecord {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return ExecutionRecord(
            identity: ExecutionIdentity(
                process: ProcessIdentity(
                    bootID: "boot-migration-tests",
                    pid: 1_000,
                    startTimeMicros: MicroTime.value(start)),
                version: 1),
            parent: nil,
            responsible: nil,
            parentPID: 1,
            userID: 501,
            executable: "/usr/bin/tool",
            arguments: ["tool"],
            workingDirectory: nil,
            signingID: nil,
            teamID: nil,
            startedAt: start,
            endedAt: nil,
            state: .running,
            evidence: .observed,
            auditToken: nil)
    }

    private func makeActivity(execution: ExecutionIdentity) -> ActivityRecord {
        ActivityRecord(
            id: 0,
            captureID: "capture-migration",
            sourceSequence: 1,
            execution: execution,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_001),
            kind: .open,
            sourcePath: "/tmp/file",
            targetPath: nil,
            fileIdentity: nil,
            projectRoot: nil,
            sessionIDs: [],
            evidence: .observed,
            configurationRevision: 1,
            mode: .recordOnly,
            evaluation: .notEvaluated,
            response: .notApplicable,
            matchedRuleIDs: [],
            detail: nil)
    }

    private func makeBatch(
        executions: [ExecutionRecord],
        activities: [ActivityRecord]
    ) -> IngestionBatch {
        IngestionBatch(
            capture: CaptureRecord(
                id: "capture-migration",
                bootID: "boot-migration-tests",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: nil),
            graph: GraphSnapshot(executions: executions),
            activities: activities,
            endpoints: [],
            gaps: [])
    }
}
