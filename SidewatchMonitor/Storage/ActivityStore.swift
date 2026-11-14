import Foundation
import GRDB
import OSLog

/// Sanitized storage failures. Messages never include paths, commands, rule
/// contents, parameter values, or SQLite messages.
enum ActivityStoreError: Error, Equatable, Sendable {
    case corruptRecord
    case storeIdentifierMismatch
    case invalidQuery(String)
    case invalidWatermark(Int64)
    case futureSchema
    case unsupportedSchemaVersion(Int)
    case unsupportedConfigurationFormat(Int)
    case invalidActivity(String)
    case invalidConfiguration(String)
    case configurationRevisionConflict(Int64)
    case unknownCapture
    case unknownExecution
    case storageConfiguration

    var code: String {
        switch self {
        case .corruptRecord: "store_corrupt_record"
        case .storeIdentifierMismatch: "store_cursor_mismatch"
        case .invalidQuery: "store_invalid_query"
        case .invalidWatermark: "store_invalid_watermark"
        case .futureSchema: "store_future_schema"
        case .unsupportedSchemaVersion: "store_unsupported_schema"
        case .unsupportedConfigurationFormat: "store_unsupported_configuration"
        case .invalidActivity: "store_invalid_activity"
        case .invalidConfiguration: "store_invalid_configuration"
        case .configurationRevisionConflict: "store_configuration_conflict"
        case .unknownCapture: "store_unknown_capture"
        case .unknownExecution: "store_unknown_execution"
        case .storageConfiguration: "store_configuration_failure"
        }
    }
}

extension ActivityStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .corruptRecord:
            return "A stored record could not be decoded."
        case .storeIdentifierMismatch:
            return "The activity cursor belongs to a different database. Reload the timeline."
        case .invalidQuery(let field):
            return "The activity query has an invalid \(field) filter."
        case .invalidWatermark:
            return "The activity query watermark is not valid for this database. Reload the timeline."
        case .futureSchema:
            return "The activity database was created by a newer version of Sidewatch."
        case .unsupportedSchemaVersion:
            return "The activity database uses an unsupported schema version."
        case .unsupportedConfigurationFormat:
            return "The stored monitoring configuration uses an unsupported format."
        case .invalidActivity(let reason):
            return "The activity record is not valid for its mode: \(reason)."
        case .invalidConfiguration(let reason):
            return "The monitoring configuration is invalid: \(reason)."
        case .configurationRevisionConflict:
            return "The monitoring configuration revision has already been saved with different content."
        case .unknownCapture:
            return "The capture interval for this record is unknown."
        case .unknownExecution:
            return "The execution is no longer known to the activity database."
        case .storageConfiguration:
            return "The activity database could not be opened with the required durability settings."
        }
    }
}

/// The only component that opens the activity database. The extension chooses
/// and validates the path; this type performs no path, ownership, or symlink
/// policy of its own.
final class ActivityStore: @unchecked Sendable {
    private static let linkedSQLiteVersion: String = {
        let number = Int(Database.sqliteLibVersionNumber)
        return "\(number / 1_000_000).\((number / 1_000) % 1_000).\(number % 1_000)"
    }()

    private let pool: DatabasePool
    let storeID: String
    let schemaFormatVersion: Int

    /// The SQLite version actually linked into the extension, not the version
    /// reported by the command-line `sqlite3` tool.
    var sqliteVersion: String { Self.linkedSQLiteVersion }

    init(path: String) throws {
        Diagnostics.storage.notice("Activity store initialization started")

        var configuration = Configuration()
        configuration.label = "Sidewatch.ActivityStore"
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.journalMode = .wal
        configuration.maximumReaderCount = 4

        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: path, configuration: configuration)
        } catch {
            Self.logStorageFailure("initialization", error)
            throw error
        }

        do {
            let migrator = DatabaseMigrations.makeMigrator()

            // DatabasePool configures WAL and then sets synchronous=NORMAL on
            // the writer. Upgrade the writer connection to FULL before any
            // migration or activity batch is committed.
            try pool.barrierWriteWithoutTransaction { db in
                try db.execute(sql: "PRAGMA synchronous = FULL")

                let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode")?
                    .lowercased()
                guard journalMode == "wal" else {
                    throw ActivityStoreError.storageConfiguration
                }
                let synchronous: Int = try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? 0
                guard synchronous == 2 else {
                    throw ActivityStoreError.storageConfiguration
                }
                let foreignKeys: Int = try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0
                guard foreignKeys == 1 else {
                    throw ActivityStoreError.storageConfiguration
                }
            }

            // Reject a database produced by a newer build before any migration
            // can run. There is deliberately no erase or downgrade path.
            var isSuperseded = false
            try pool.read { db in
                if try db.tableExists("store_metadata") {
                    let formatVersion: Int = try Int.fetchOne(
                        db,
                        sql: "SELECT format_version FROM store_metadata WHERE id = 1") ?? 0
                    if formatVersion > DatabaseMigrations.latestFormatVersion {
                        throw ActivityStoreError.unsupportedSchemaVersion(formatVersion)
                    }
                }
                isSuperseded = try migrator.hasBeenSuperseded(db)
            }
            if isSuperseded {
                throw ActivityStoreError.futureSchema
            }

            try migrator.migrate(pool)

            let metadata = try pool.read { db in
                try HistoryQueries.metadata(db)
            }
            let appliedCount = try pool.read { db in
                try migrator.appliedIdentifiers(db).count
            }
            Diagnostics.storage.notice(
                "Database migrations completed; \(appliedCount, privacy: .public) applied")

            self.pool = pool
            self.storeID = metadata.storeID
            self.schemaFormatVersion = metadata.formatVersion

            Diagnostics.storage.notice(
                "Activity store initialized; schema \(metadata.formatVersion, privacy: .public); sqlite \(Self.linkedSQLiteVersion, privacy: .public); migrations \(appliedCount, privacy: .public)")
        } catch {
            Self.logStorageFailure("initialization", error)
            throw error
        }
    }

    func close() throws {
        do {
            try pool.close()
        } catch {
            Self.logStorageFailure("close", error)
            throw error
        }
    }

    // MARK: - Configuration

    func configuration() async throws -> MonitorConfiguration {
        do {
            return try await pool.read { db in
                try HistoryQueries.currentConfiguration(db)
            }
        } catch {
            Self.logStorageFailure("configuration read", error)
            throw error
        }
    }

    func saveConfiguration(_ configuration: MonitorConfiguration) async throws {
        try Self.validateConfiguration(configuration)
        let rulesJSON = try ConfigurationJSON.encodeRules(configuration.rules)
        let agentsJSON = try ConfigurationJSON.encodeAgents(configuration.agentDefinitions)

        do {
            try await pool.write { db in
                try Self.saveConfiguration(
                    db,
                    configuration: configuration,
                    rulesJSON: rulesJSON,
                    agentsJSON: agentsJSON,
                    committedAt: MicroTime.value(Date()))
            }
        } catch {
            Self.logStorageFailure("configuration save", error)
            throw error
        }
    }

    // MARK: - Ingestion

    /// Persists the graph, activities, endpoints, gaps, and capture interval in
    /// one transaction. Returns the new commit watermark.
    func ingest(_ batch: IngestionBatch) async throws -> Int64 {
        do {
            return try await pool.write { db in
                try Self.ingest(db, batch: batch)
            }
        } catch {
            Self.logStorageFailure("ingest", error)
            throw error
        }
    }

    // MARK: - Reads

    func graph() async throws -> GraphSnapshot {
        do {
            return try await pool.read { db in
                try HistoryQueries.graph(db)
            }
        } catch {
            Self.logStorageFailure("graph read", error)
            throw error
        }
    }

    func page(_ query: ActivityQuery) async throws -> ActivityPage {
        let storeID = self.storeID
        do {
            return try await pool.read { db in
                try HistoryQueries.page(db, storeID: storeID, query: query)
            }
        } catch {
            Self.logStorageFailure("activity page", error)
            throw error
        }
    }

    func snapshot(health: MonitorHealth) async throws -> MonitorSnapshot {
        let storageBytes = Self.storageBytes(path: pool.path)
        let storeID = self.storeID
        do {
            return try await pool.read { db in
                let metadata = try HistoryQueries.metadata(db)
                let graph = try HistoryQueries.graph(db)
                let endpoints = try HistoryQueries.activeEndpoints(db)
                let configuration = try HistoryQueries.currentConfiguration(db)
                let oldestActivity = try HistoryQueries.oldestActivity(db)

                var reportedHealth = health
                reportedHealth.sqliteVersion = Self.linkedSQLiteVersion

                return MonitorSnapshot(
                    graph: graph,
                    endpoints: endpoints,
                    configuration: configuration,
                    health: reportedHealth,
                    storeID: storeID,
                    watermark: metadata.watermark,
                    storageBytes: storageBytes,
                    oldestActivity: oldestActivity,
                    captures: try HistoryQueries.captures(db),
                    gaps: try HistoryQueries.gaps(db))
            }
        } catch {
            Self.logStorageFailure("snapshot read", error)
            throw error
        }
    }

    // MARK: - Control audit

    func recordControl(_ action: ControlAction) async throws {
        do {
            try await pool.write { db in
                var state = IngestState()
                guard let executionID = try Self.lookupExecution(
                    db, action.execution, state: &state)
                else {
                    throw ActivityStoreError.unknownExecution
                }
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO control_actions
                            (id, execution_id, operation, requested_at_us,
                             signal_sent, exit_confirmed, error_code)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        action.id,
                        executionID,
                        action.operation.rawValue,
                        MicroTime.value(action.requestedAt),
                        action.signalSent ? 1 : 0,
                        action.exitConfirmed ? 1 : 0,
                        action.errorCode.map { Int64($0) },
                    ])
            }
        } catch {
            Self.logStorageFailure("control audit", error)
            throw error
        }
    }

    // MARK: - History maintenance

    func clearHistory() async throws -> Int64 {
        do {
            let deleted = try await pool.write { db in
                try RetentionPolicy.clear(db: db)
            }
            Diagnostics.storage.notice(
                "History cleared; \(deleted, privacy: .public) activities removed")
            return deleted
        } catch {
            Self.logStorageFailure("history clear", error)
            throw error
        }
    }

    func retain(now: Date) async throws {
        do {
            let deleted = try await pool.write { db in
                let configuration = try HistoryQueries.currentConfiguration(db)
                return try RetentionPolicy.apply(
                    db: db, now: now, configuration: configuration)
            }
            Diagnostics.storage.notice(
                "History retention completed; \(deleted, privacy: .public) activities removed")
        } catch {
            Self.logStorageFailure("retention", error)
            throw error
        }
    }

    // MARK: - Test and diagnostics support

    func appliedMigrations() async throws -> [String] {
        try await pool.read { db in
            try DatabaseMigrations.makeMigrator().appliedMigrations(db)
        }
    }

    // MARK: - Configuration writes

    private static func validateConfiguration(_ configuration: MonitorConfiguration) throws {
        guard configuration.revision > 0 else {
            throw ActivityStoreError.invalidConfiguration("revision")
        }
        guard configuration.retentionDays > 0 else {
            throw ActivityStoreError.invalidConfiguration("retention")
        }
        guard configuration.storageBudgetBytes > 0 else {
            throw ActivityStoreError.invalidConfiguration("storage budget")
        }

        var ruleIDs = Set<String>()
        for rule in configuration.rules {
            guard ruleIDs.insert(rule.id).inserted else {
                throw ActivityStoreError.invalidConfiguration("duplicate rule identifier")
            }
        }

        var agentIDs = Set<String>()
        for agent in configuration.agentDefinitions {
            guard agentIDs.insert(agent.id).inserted else {
                throw ActivityStoreError.invalidConfiguration("duplicate agent identifier")
            }
        }
    }

    private static func saveConfiguration(
        _ db: Database,
        configuration: MonitorConfiguration,
        rulesJSON: String,
        agentsJSON: String,
        committedAt: Int64
    ) throws {
        let maxRevision: Int64 = try Int64.fetchOne(
            db, sql: "SELECT COALESCE(MAX(revision), 0) FROM configuration_versions") ?? 0

        if configuration.revision < maxRevision {
            throw ActivityStoreError.configurationRevisionConflict(configuration.revision)
        }

        if let row = try Row.fetchOne(
            db,
            sql: """
                SELECT mode, rules_json, agent_definitions_json,
                       retention_days, storage_budget_bytes
                FROM configuration_versions
                WHERE revision = ?
                """,
            arguments: [configuration.revision])
        {
            let mode: MonitoringMode = try RowMapping.enumValue(
                row, "mode", as: MonitoringMode.self)
            let storedRules: String = try RowMapping.required(row, "rules_json")
            let storedAgents: String = try RowMapping.required(row, "agent_definitions_json")
            let retainedDays: Int64 = try RowMapping.required(row, "retention_days")
            let budget: Int64 = try RowMapping.required(row, "storage_budget_bytes")

            let canonicalRules = try ConfigurationJSON.encodeRules(
                ConfigurationJSON.decodeRules(storedRules))
            let canonicalAgents = try ConfigurationJSON.encodeAgents(
                ConfigurationJSON.decodeAgents(storedAgents))

            guard mode == configuration.mode,
                  canonicalRules == rulesJSON,
                  canonicalAgents == agentsJSON,
                  retainedDays == Int64(configuration.retentionDays),
                  budget == configuration.storageBudgetBytes
            else {
                throw ActivityStoreError.configurationRevisionConflict(configuration.revision)
            }
        } else {
            try db.execute(
                sql: """
                    INSERT INTO configuration_versions
                        (revision, mode, format_version, rules_json, agent_definitions_json,
                         retention_days, storage_budget_bytes, committed_at_us)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    configuration.revision,
                    configuration.mode.rawValue,
                    HistoryQueries.configurationFormatVersion,
                    rulesJSON,
                    agentsJSON,
                    Int64(configuration.retentionDays),
                    configuration.storageBudgetBytes,
                    committedAt,
                ])
        }

        try db.execute(
            sql: """
                INSERT INTO preferences (id, current_revision) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET current_revision = excluded.current_revision
                """,
            arguments: [configuration.revision])
    }

    // MARK: - Ingestion state

    private struct IngestState {
        var bootIDs: [String: Int64] = [:]
        var processIDs: [String: Int64] = [:]
        var executionIDs: [String: Int64] = [:]
        var missingExecutions: Set<String> = []
        var projectIDs: [String: Int64] = [:]
        var captureIDs: [String: Int64] = [:]
        var sessionIDs: Set<String> = []
        var maxSourceSequences: [Int64: Int64] = [:]
    }

    private struct IngestBatch {
        var capture: CaptureRecord
        var captureID: Int64
    }

    private static func ingest(_ db: Database, batch: IngestionBatch) throws -> Int64 {
        var state = IngestState()
        let batchCapture = IngestBatch(
            capture: batch.capture,
            captureID: try ensureCapture(db, batch.capture, state: &state))

        // Base execution rows first so every batch identity is resolvable.
        for record in batch.graph.executions {
            _ = try ensureExecution(db, record, state: &state)
        }
        try closeSupersededSnapshotPlaceholders(db, graph: batch.graph)

        // Link parent and responsible identity columns to known nodes. Unknown
        // identities remain only as their recorded tokens; no parent node is
        // fabricated to satisfy a foreign key.
        for record in batch.graph.executions {
            guard let executionID = state.executionIDs[record.identity.stableID] else {
                throw ActivityStoreError.corruptRecord
            }
            let parentID = try lookupExecution(db, record.parent, state: &state)
            let responsibleID = try lookupExecution(db, record.responsible, state: &state)
            if parentID != nil || responsibleID != nil {
                try db.execute(
                    sql: """
                        UPDATE executions
                        SET parent_execution_id = COALESCE(?, parent_execution_id),
                            responsible_execution_id = COALESCE(?, responsible_execution_id)
                        WHERE id = ?
                        """,
                    arguments: [parentID, responsibleID, executionID])
            }
        }

        // Projects referenced by sessions are persisted before the sessions.
        for session in batch.graph.sessions {
            if let project = session.project, !project.root.isEmpty {
                _ = try ensureProject(
                    db,
                    root: project.root,
                    gitDirectory: project.gitDirectory,
                    state: &state)
            }
        }

        for session in batch.graph.sessions {
            _ = try ensureSession(db, session, state: &state)
        }

        for association in batch.graph.associations {
            guard let executionID = try lookupExecution(
                    db, association.execution, state: &state),
                  try sessionExists(db, id: association.sessionID, state: &state)
            else {
                continue
            }
            try db.execute(
                sql: """
                    INSERT INTO execution_sessions
                        (execution_id, session_id, evidence, observed_at_us)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(execution_id, session_id) DO UPDATE SET
                        evidence = excluded.evidence,
                        observed_at_us = MAX(execution_sessions.observed_at_us, excluded.observed_at_us)
                    """,
                arguments: [
                    executionID,
                    association.sessionID,
                    association.evidence.rawValue,
                    MicroTime.value(batch.capture.startedAt),
                ])
        }

        for edge in batch.graph.edges {
            guard let parentID = try lookupExecution(db, edge.parent, state: &state),
                  let childID = try lookupExecution(db, edge.child, state: &state),
                  parentID != childID
            else {
                continue
            }
            try db.execute(
                sql: """
                    INSERT INTO execution_edges
                        (parent_execution_id, child_execution_id, kind, evidence,
                         capture_id, observed_at_us)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(parent_execution_id, child_execution_id, kind) DO UPDATE SET
                        evidence = excluded.evidence,
                        observed_at_us = MAX(execution_edges.observed_at_us, excluded.observed_at_us)
                    """,
                arguments: [
                    parentID,
                    childID,
                    edge.kind.rawValue,
                    edge.evidence.rawValue,
                    batchCapture.captureID,
                    MicroTime.value(edge.observedAt),
                ])
        }

        var insertedActivityIDs: [Int64] = []
        for activity in batch.activities {
            if let id = try insertActivity(
                db,
                activity,
                batchCapture: batchCapture,
                state: &state)
            {
                insertedActivityIDs.append(id)
            }
        }

        for endpoint in batch.endpoints {
            try upsertEndpoint(db, endpoint, state: &state)
        }

        for gap in batch.gaps {
            try insertGap(db, gap, batchCapture: batchCapture, state: &state)
        }

        for (captureID, sequence) in state.maxSourceSequences {
            try db.execute(
                sql: """
                    UPDATE capture_runs
                    SET last_received_seq = MAX(COALESCE(last_received_seq, 0), ?),
                        last_committed_seq = MAX(COALESCE(last_committed_seq, 0), ?)
                    WHERE id = ?
                    """,
                arguments: [sequence, sequence, captureID])
        }

        let previousWatermark = try HistoryQueries.metadata(db).watermark
        let watermark = max(previousWatermark, insertedActivityIDs.max() ?? 0)
        if watermark > previousWatermark {
            try db.execute(
                sql: "UPDATE store_metadata SET watermark = ? WHERE id = 1",
                arguments: [watermark])
        }
        return watermark
    }

    // MARK: - Ingestion helpers

    private static func ensureBoot(
        _ db: Database,
        _ identifier: String,
        state: inout IngestState
    ) throws -> Int64 {
        if let id = state.bootIDs[identifier] {
            return id
        }
        try db.execute(
            sql: "INSERT OR IGNORE INTO boot_epochs (boot_identifier, started_at_us) VALUES (?, 0)",
            arguments: [identifier])
        guard let id: Int64 = try Int64.fetchOne(
            db, sql: "SELECT id FROM boot_epochs WHERE boot_identifier = ?", arguments: [identifier])
        else {
            throw ActivityStoreError.corruptRecord
        }
        state.bootIDs[identifier] = id
        return id
    }

    private static func ensureCapture(
        _ db: Database,
        _ capture: CaptureRecord,
        state: inout IngestState
    ) throws -> Int64 {
        let endedAt = capture.endedAt.map(MicroTime.value)
        if let id = state.captureIDs[capture.id] {
            if let endedAt {
                try db.execute(
                    sql: """
                        UPDATE capture_runs SET ended_at_us = COALESCE(ended_at_us, ?)
                        WHERE id = ?
                        """,
                    arguments: [endedAt, id])
            }
            return id
        }

        let bootID = try ensureBoot(db, capture.bootID, state: &state)
        try db.execute(
            sql: """
                INSERT INTO capture_runs
                    (capture_identifier, boot_id, started_at_us, ended_at_us)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(capture_identifier) DO UPDATE SET
                    ended_at_us = COALESCE(capture_runs.ended_at_us, excluded.ended_at_us)
                """,
            arguments: [capture.id, bootID, MicroTime.value(capture.startedAt), endedAt])

        guard let id: Int64 = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM capture_runs WHERE capture_identifier = ?",
            arguments: [capture.id])
        else {
            throw ActivityStoreError.corruptRecord
        }
        state.captureIDs[capture.id] = id
        return id
    }

    private static func ensureProcess(
        _ db: Database,
        _ process: ProcessIdentity,
        uid: UInt32,
        state: inout IngestState
    ) throws -> Int64 {
        if let id = state.processIDs[process.stableID] {
            return id
        }
        let bootID = try ensureBoot(db, process.bootID, state: &state)
        try db.execute(
            sql: """
                INSERT INTO process_instances (boot_id, pid, start_time_us, uid)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(boot_id, pid, start_time_us) DO UPDATE SET
                    uid = COALESCE(process_instances.uid, excluded.uid)
                """,
            arguments: [bootID, Int64(process.pid), process.startTimeMicros, Int64(uid)])

        guard let id: Int64 = try Int64.fetchOne(
            db,
            sql: """
                SELECT id FROM process_instances
                WHERE boot_id = ? AND pid = ? AND start_time_us = ?
                """,
            arguments: [bootID, Int64(process.pid), process.startTimeMicros])
        else {
            throw ActivityStoreError.corruptRecord
        }
        state.processIDs[process.stableID] = id
        return id
    }

    private static func ensureExecution(
        _ db: Database,
        _ record: ExecutionRecord,
        state: inout IngestState
    ) throws -> Int64 {
        let key = record.identity.stableID
        let cachedID = state.executionIDs[key]

        let processID = try ensureProcess(
            db, record.identity.process, uid: record.userID, state: &state)
        let argumentsJSON = try ConfigurationJSON.encodeArguments(record.arguments)
        let version = Int64(record.identity.version)
        let endedAt = record.endedAt.map(MicroTime.value)

        try db.execute(
            sql: """
                INSERT INTO executions
                    (process_id, pidversion, parent_pid, user_id, executable,
                     arguments_json, command_text, working_directory, signing_id,
                     team_id, started_at_us, ended_at_us, state, evidence,
                     parent_boot_identifier, parent_identity_pid,
                     parent_identity_start_us, parent_identity_pidversion,
                     responsible_boot_identifier, responsible_identity_pid,
                     responsible_identity_start_us, responsible_identity_pidversion)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(process_id, pidversion) DO UPDATE SET
                    parent_pid = excluded.parent_pid,
                    user_id = excluded.user_id,
                    executable = excluded.executable,
                    arguments_json = excluded.arguments_json,
                    command_text = excluded.command_text,
                    working_directory = COALESCE(
                        excluded.working_directory, executions.working_directory),
                    signing_id = COALESCE(excluded.signing_id, executions.signing_id),
                    team_id = COALESCE(excluded.team_id, executions.team_id),
                    -- A snapshot/metadata row's start is the process creation baseline, while a
                    -- directly observed execution start is the exec itself. The baseline must
                    -- not win over that observation, and a later refresh cannot move it back.
                    started_at_us = CASE
                        WHEN excluded.evidence = 'observed' AND executions.evidence <> 'observed'
                            THEN excluded.started_at_us
                        WHEN executions.evidence = 'observed' AND excluded.evidence <> 'observed'
                            THEN executions.started_at_us
                        ELSE MIN(executions.started_at_us, excluded.started_at_us)
                    END,
                    ended_at_us = COALESCE(executions.ended_at_us, excluded.ended_at_us),
                    state = CASE
                        WHEN excluded.state = 'exited' OR executions.state = 'exited' THEN 'exited'
                        WHEN excluded.state = 'running' OR executions.state = 'running' THEN 'running'
                        ELSE 'unknown'
                    END,
                    -- Reconciling a placeholder never relabels a directly observed execution.
                    evidence = CASE
                        WHEN executions.evidence = 'observed' THEN executions.evidence
                        ELSE excluded.evidence
                    END,
                    parent_boot_identifier = COALESCE(
                        excluded.parent_boot_identifier, executions.parent_boot_identifier),
                    parent_identity_pid = COALESCE(
                        excluded.parent_identity_pid, executions.parent_identity_pid),
                    parent_identity_start_us = COALESCE(
                        excluded.parent_identity_start_us, executions.parent_identity_start_us),
                    parent_identity_pidversion = COALESCE(
                        excluded.parent_identity_pidversion, executions.parent_identity_pidversion),
                    responsible_boot_identifier = COALESCE(
                        excluded.responsible_boot_identifier,
                        executions.responsible_boot_identifier),
                    responsible_identity_pid = COALESCE(
                        excluded.responsible_identity_pid, executions.responsible_identity_pid),
                    responsible_identity_start_us = COALESCE(
                        excluded.responsible_identity_start_us,
                        executions.responsible_identity_start_us),
                    responsible_identity_pidversion = COALESCE(
                        excluded.responsible_identity_pidversion,
                        executions.responsible_identity_pidversion)
                """,
            arguments: [
                processID,
                version,
                Int64(record.parentPID),
                Int64(record.userID),
                record.executable,
                argumentsJSON,
                record.executable + " " + record.command,
                record.workingDirectory,
                record.signingID,
                record.teamID,
                MicroTime.value(record.startedAt),
                endedAt,
                record.state.rawValue,
                record.evidence.rawValue,
                record.parent?.process.bootID,
                record.parent.map { Int64($0.process.pid) },
                record.parent?.process.startTimeMicros,
                record.parent.map { Int64($0.version) },
                record.responsible?.process.bootID,
                record.responsible.map { Int64($0.process.pid) },
                record.responsible?.process.startTimeMicros,
                record.responsible.map { Int64($0.version) },
            ])

        let id: Int64
        if let cachedID {
            id = cachedID
        } else {
            guard let fetched: Int64 = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM executions WHERE process_id = ? AND pidversion = ?",
                arguments: [processID, version])
            else {
                throw ActivityStoreError.corruptRecord
            }
            id = fetched
        }
        state.executionIDs[key] = id
        return id
    }

    /// Native polling installs a synthetic, snapshot-only identity for a process that was
    /// already running, and that identity stays the canonical session root: the exact
    /// Endpoint Security identity of the same process is associated with the same session.
    /// The placeholder only stops being live when the process is observed to exit, or when an
    /// observed image-replacing exec takes the process over. This keeps every stored session
    /// id stable and prevents a terminated placeholder from reopening as a live duplicate.
    ///
    /// Only live snapshot rows are inspected, so the cost stays proportional to the handful
    /// of synthetic placeholders rather than to the whole graph in every batch.
    private static func closeSupersededSnapshotPlaceholders(
        _ db: Database,
        graph: GraphSnapshot
    ) throws {
        let observedByProcess = Dictionary(
            grouping: graph.executions.filter { $0.evidence == .observed },
            by: \.identity.process)
        guard !observedByProcess.isEmpty else { return }
        let present = Set(graph.executions.map(\.identity.stableID))

        let rows: [Row] = try Row.fetchAll(db, sql: """
            SELECT e.id AS id, e.pidversion AS pidversion,
                   b.boot_identifier AS boot_identifier, pi.pid AS pid,
                   pi.start_time_us AS start_time_us
            FROM executions e
            JOIN process_instances pi ON pi.id = e.process_id
            JOIN boot_epochs b ON b.id = pi.boot_id
            WHERE e.evidence = 'snapshot' AND e.state <> 'exited'
            """)

        for row in rows {
            let boot: String = row["boot_identifier"]
            let pid: Int64 = row["pid"]
            let start: Int64 = row["start_time_us"]
            let version: Int64 = row["pidversion"]
            guard let pidValue = Int32(exactly: pid),
                  let identityVersion = UInt32(exactly: version)
            else { continue }

            let process = ProcessIdentity(
                bootID: boot, pid: pidValue, startTimeMicros: start)
            guard let observed = observedByProcess[process] else { continue }
            let identity = ExecutionIdentity(process: process, version: identityVersion)
            let exit = observed
                .filter { $0.state == .exited }
                .min { ($0.endedAt ?? $0.startedAt) < ($1.endedAt ?? $1.startedAt) }
            // The earliest point at which an exact observation replaced or ended this
            // process's original execution.
            let replacementEnd = observed
                .map { $0.state == .exited ? ($0.endedAt ?? $0.startedAt) : $0.startedAt }
                .min()

            if present.contains(identity.stableID) {
                // The engine still carries the canonical placeholder. Only an observed
                // exit of this process can end it; a promotion leaves it as the session
                // root while the exact identity is associated with that same session.
                if let exit {
                    let id: Int64 = row["id"]
                    try closeExecution(
                        db, id: id, endedAt: exit.endedAt.map(MicroTime.value))
                }
            } else if let replacementEnd {
                // An observed exec replaced the image while the engine dropped the
                // placeholder: the previous image ended when the new one started.
                let id: Int64 = row["id"]
                try closeExecution(
                    db, id: id, endedAt: MicroTime.value(replacementEnd))
            }
        }
    }

    private static func closeExecution(
        _ db: Database,
        id: Int64,
        endedAt: Int64?
    ) throws {
        try db.execute(
            sql: """
                UPDATE executions
                SET state = 'exited',
                    ended_at_us = CASE WHEN ? IS NULL THEN ended_at_us
                                       ELSE COALESCE(ended_at_us, ?) END
                WHERE id = ?
                """,
            arguments: [endedAt, endedAt, id])
    }

    private static func lookupExecution(
        _ db: Database,
        _ identity: ExecutionIdentity?,
        state: inout IngestState
    ) throws -> Int64? {
        guard let identity else { return nil }
        let key = identity.stableID
        if let id = state.executionIDs[key] {
            return id
        }
        if state.missingExecutions.contains(key) {
            return nil
        }

        let boot = identity.process.bootID
        let pid = Int64(identity.process.pid)
        let start = identity.process.startTimeMicros
        let version = Int64(identity.version)
        let id: Int64? = try Int64.fetchOne(
            db,
            sql: """
                SELECT e.id FROM executions e
                JOIN process_instances pi ON pi.id = e.process_id
                JOIN boot_epochs b ON b.id = pi.boot_id
                WHERE b.boot_identifier = ?
                  AND pi.pid = ?
                  AND pi.start_time_us = ?
                  AND e.pidversion = ?
                """,
            arguments: [boot, pid, start, version])

        if let id {
            state.executionIDs[key] = id
        } else {
            state.missingExecutions.insert(key)
        }
        return id
    }

    private static func ensureProject(
        _ db: Database,
        root: String,
        gitDirectory: String?,
        state: inout IngestState
    ) throws -> Int64 {
        if let id = state.projectIDs[root] {
            if let gitDirectory {
                try db.execute(
                    sql: """
                        UPDATE projects SET git_directory = COALESCE(git_directory, ?)
                        WHERE id = ?
                        """,
                    arguments: [gitDirectory, id])
            }
            return id
        }

        let component = URL(fileURLWithPath: root).lastPathComponent
        let displayName = component.isEmpty ? root : component
        try db.execute(
            sql: """
                INSERT INTO projects (canonical_root, git_directory, display_name)
                VALUES (?, ?, ?)
                ON CONFLICT(canonical_root) DO UPDATE SET
                    git_directory = COALESCE(excluded.git_directory, projects.git_directory)
                """,
            arguments: [root, gitDirectory, displayName])

        guard let id: Int64 = try Int64.fetchOne(
            db, sql: "SELECT id FROM projects WHERE canonical_root = ?", arguments: [root])
        else {
            throw ActivityStoreError.corruptRecord
        }
        state.projectIDs[root] = id
        return id
    }

    private static func ensureSession(
        _ db: Database,
        _ session: AgentSession,
        state: inout IngestState
    ) throws -> Bool {
        guard let rootID = try lookupExecution(db, session.root, state: &state) else {
            // The root execution is not known yet. Do not fabricate a node or
            // an Agent merely to satisfy the foreign key.
            return false
        }

        var projectID: Int64?
        if let project = session.project, !project.root.isEmpty {
            projectID = try ensureProject(
                db,
                root: project.root,
                gitDirectory: project.gitDirectory,
                state: &state)
        }

        let executableNames = try ConfigurationJSON.encodeStringArray(
            session.agent.executableNames)
        let scriptComponents = try ConfigurationJSON.encodeStringArray(
            session.agent.scriptPathComponents)
        let endedAt = session.endedAt.map(MicroTime.value)

        try db.execute(
            sql: """
                INSERT INTO agent_sessions
                    (id, root_execution_id, agent_id, agent_name,
                     executable_names_json, script_path_components_json,
                     project_id, started_at_us, ended_at_us, end_reason, evidence)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    root_execution_id = excluded.root_execution_id,
                    agent_id = excluded.agent_id,
                    agent_name = excluded.agent_name,
                    executable_names_json = excluded.executable_names_json,
                    script_path_components_json = excluded.script_path_components_json,
                    project_id = COALESCE(excluded.project_id, agent_sessions.project_id),
                    started_at_us = MIN(agent_sessions.started_at_us, excluded.started_at_us),
                    ended_at_us = COALESCE(agent_sessions.ended_at_us, excluded.ended_at_us),
                    end_reason = COALESCE(agent_sessions.end_reason, excluded.end_reason),
                    evidence = excluded.evidence
                """,
            arguments: [
                session.id,
                rootID,
                session.agent.id,
                session.agent.name,
                executableNames,
                scriptComponents,
                projectID,
                MicroTime.value(session.startedAt),
                endedAt,
                session.endReason,
                session.evidence.rawValue,
            ])

        state.sessionIDs.insert(session.id)
        return true
    }

    private static func sessionExists(
        _ db: Database,
        id: String,
        state: inout IngestState
    ) throws -> Bool {
        if state.sessionIDs.contains(id) {
            return true
        }
        let exists: Int64? = try Int64.fetchOne(
            db, sql: "SELECT 1 FROM agent_sessions WHERE id = ?", arguments: [id])
        return exists != nil
    }

    private static func insertActivity(
        _ db: Database,
        _ activity: ActivityRecord,
        batchCapture: IngestBatch,
        state: inout IngestState
    ) throws -> Int64? {
        try validateActivity(activity)

        guard let storedMode: String = try String.fetchOne(
            db,
            sql: "SELECT mode FROM configuration_versions WHERE revision = ?",
            arguments: [activity.configurationRevision])
        else {
            throw ActivityStoreError.invalidActivity("unknown configuration revision")
        }
        guard storedMode == activity.mode.rawValue else {
            throw ActivityStoreError.invalidActivity("mode does not match configuration revision")
        }

        let captureID: Int64
        if activity.captureID == batchCapture.capture.id {
            captureID = batchCapture.captureID
        } else if let known = state.captureIDs[activity.captureID] {
            captureID = known
        } else if let known: Int64 = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM capture_runs WHERE capture_identifier = ?",
            arguments: [activity.captureID])
        {
            captureID = known
        } else {
            throw ActivityStoreError.unknownCapture
        }

        let executionID = try lookupExecution(db, activity.execution, state: &state)

        var projectID: Int64?
        if let root = activity.projectRoot, !root.isEmpty {
            projectID = try ensureProject(db, root: root, gitDirectory: nil, state: &state)
        }

        let sourceSequence: Int64?
        if let sequence = activity.sourceSequence {
            guard let converted = Int64(exactly: sequence) else {
                throw ActivityStoreError.invalidActivity("source sequence")
            }
            sourceSequence = converted
        } else {
            sourceSequence = nil
        }

        let device: Int64?
        let inode: Int64?
        if let identity = activity.fileIdentity {
            guard let deviceValue = Int64(exactly: identity.device),
                  let inodeValue = Int64(exactly: identity.inode)
            else {
                throw ActivityStoreError.invalidActivity("file identity")
            }
            device = deviceValue
            inode = inodeValue
        } else {
            device = nil
            inode = nil
        }

        try db.execute(
            sql: """
                INSERT INTO activities
                    (capture_id, source_seq, execution_id, project_id,
                     occurred_at_us, kind, source_path, target_path, device, inode,
                     configuration_revision, mode, evidence, evaluation, response, detail)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(capture_id, source_seq) DO NOTHING
                """,
            arguments: [
                captureID,
                sourceSequence,
                executionID,
                projectID,
                MicroTime.value(activity.occurredAt),
                activity.kind.rawValue,
                activity.sourcePath,
                activity.targetPath,
                device,
                inode,
                activity.configurationRevision,
                activity.mode.rawValue,
                activity.evidence.rawValue,
                activity.evaluation.rawValue,
                activity.response.rawValue,
                activity.detail,
            ])

        guard db.changesCount == 1 else {
            return nil
        }
        let activityID = db.lastInsertedRowID

        if let sourceSequence {
            state.maxSourceSequences[captureID] = max(
                state.maxSourceSequences[captureID] ?? 0, sourceSequence)
        }

        for sessionID in Set(activity.sessionIDs) {
            guard try sessionExists(db, id: sessionID, state: &state) else { continue }
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO activity_sessions
                        (activity_id, session_id, evidence)
                    VALUES (?, ?, ?)
                    """,
                arguments: [activityID, sessionID, activity.evidence.rawValue])
        }

        for ruleID in Set(activity.matchedRuleIDs) {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO rule_matches (activity_id, rule_key)
                    VALUES (?, ?)
                    """,
                arguments: [activityID, ruleID])
        }

        return activityID
    }

    private static func validateActivity(_ activity: ActivityRecord) throws {
        switch activity.mode {
        case .recordOnly:
            guard activity.kind != .authorization else {
                throw ActivityStoreError.invalidActivity(
                    "Record Only does not subscribe to authorization")
            }
            guard activity.evaluation == .notEvaluated,
                  activity.response == .notApplicable,
                  activity.matchedRuleIDs.isEmpty
            else {
                throw ActivityStoreError.invalidActivity(
                    "Record Only cannot record a rule decision or system response")
            }

        case .dryRun:
            if activity.kind == .authorization {
                // Dry Run attempts Allow, but the OS boundary can still fail to
                // deliver that response. Record the failure truthfully instead
                // of fabricating an Allow, and never record a denial.
                guard activity.response == .allow || activity.response == .failed else {
                    throw ActivityStoreError.invalidActivity(
                        "Dry Run must record an attempted Allow response")
                }
                guard activity.evaluation == .allow || activity.evaluation == .deny else {
                    throw ActivityStoreError.invalidActivity(
                        "authorization activity requires an evaluation")
                }
            } else {
                guard activity.evaluation == .notEvaluated,
                      activity.response == .notApplicable,
                      activity.matchedRuleIDs.isEmpty
                else {
                    throw ActivityStoreError.invalidActivity(
                        "non-authorization activity carries no system response")
                }
            }

        case .protect:
            if activity.kind == .authorization {
                guard activity.response == .allow
                        || activity.response == .deny
                        || activity.response == .failed
                else {
                    throw ActivityStoreError.invalidActivity(
                        "authorization activity requires an actual response")
                }
                guard activity.evaluation == .allow || activity.evaluation == .deny else {
                    throw ActivityStoreError.invalidActivity(
                        "authorization activity requires an evaluation")
                }
            } else {
                guard activity.evaluation == .notEvaluated,
                      activity.response == .notApplicable,
                      activity.matchedRuleIDs.isEmpty
                else {
                    throw ActivityStoreError.invalidActivity(
                        "non-authorization activity carries no system response")
                }
            }
        }

        if activity.mode == .protect,
           activity.kind == .authorization,
           activity.evaluation == .deny,
           activity.response == .allow
        {
            throw ActivityStoreError.invalidActivity(
                "Protect must record the actual response for a denied operation")
        }

        if activity.evaluation == .allow, activity.response == .deny {
            throw ActivityStoreError.invalidActivity(
                "an allowed evaluation cannot record a denial")
        }
    }

    private static func upsertEndpoint(
        _ db: Database,
        _ endpoint: ListeningEndpoint,
        state: inout IngestState
    ) throws {
        guard let executionID = try lookupExecution(
            db, endpoint.execution, state: &state)
        else {
            return
        }

        let first = MicroTime.value(endpoint.firstObservedAt)
        let last = max(first, MicroTime.value(endpoint.lastObservedAt))
        let ended = endpoint.endedAt.map(MicroTime.value)

        let activeID: Int64? = try Int64.fetchOne(
            db,
            sql: """
                SELECT id FROM listener_intervals
                WHERE execution_id = ?
                  AND transport = ?
                  AND address_family = ?
                  AND address = ?
                  AND scope_id = ?
                  AND port = ?
                  AND ended_at_us IS NULL
                LIMIT 1
                """,
            arguments: [
                executionID,
                endpoint.transport.rawValue,
                Int64(endpoint.addressFamily),
                endpoint.address,
                Int64(endpoint.scopeID),
                Int64(endpoint.port),
            ])

        if let activeID {
            if let ended {
                try db.execute(
                    sql: """
                        UPDATE listener_intervals
                        SET first_observed_at_us = MIN(first_observed_at_us, ?),
                            last_observed_at_us = MAX(last_observed_at_us, ?),
                            ended_at_us = MAX(COALESCE(?, last_observed_at_us), last_observed_at_us)
                        WHERE id = ?
                        """,
                    arguments: [first, last, ended, activeID])
            } else {
                try db.execute(
                    sql: """
                        UPDATE listener_intervals
                        SET first_observed_at_us = MIN(first_observed_at_us, ?),
                            last_observed_at_us = MAX(last_observed_at_us, ?)
                        WHERE id = ?
                        """,
                    arguments: [first, last, activeID])
            }
            return
        }

        try db.execute(
            sql: """
                INSERT INTO listener_intervals
                    (execution_id, transport, address, address_family, scope_id, port,
                     first_observed_at_us, last_observed_at_us, ended_at_us)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                executionID,
                endpoint.transport.rawValue,
                endpoint.address,
                Int64(endpoint.addressFamily),
                Int64(endpoint.scopeID),
                Int64(endpoint.port),
                first,
                last,
                ended,
            ])
    }

    private static func insertGap(
        _ db: Database,
        _ gap: CollectionGap,
        batchCapture: IngestBatch,
        state: inout IngestState
    ) throws {
        let captureID: Int64
        if gap.captureID == batchCapture.capture.id {
            captureID = batchCapture.captureID
        } else if let known = state.captureIDs[gap.captureID] {
            captureID = known
        } else if let known: Int64 = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM capture_runs WHERE capture_identifier = ?",
            arguments: [gap.captureID])
        {
            captureID = known
        } else {
            throw ActivityStoreError.unknownCapture
        }

        let missingCount: Int64?
        if let count = gap.missingCount {
            guard let converted = Int64(exactly: count) else {
                throw ActivityStoreError.invalidActivity("gap count")
            }
            missingCount = converted
        } else {
            missingCount = nil
        }

        try db.execute(
            sql: """
                INSERT OR IGNORE INTO capture_gaps
                    (capture_id, occurred_at_us, reason, missing_count)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [
                captureID,
                MicroTime.value(gap.occurredAt),
                gap.reason,
                missingCount,
            ])
    }

    // MARK: - Filesystem reporting

    private static func storageBytes(path: String) -> Int64 {
        var total: Int64 = 0
        for candidate in [path, path + "-wal", path + "-shm"] {
            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: candidate),
                let size = attributes[.size] as? NSNumber
            else {
                continue
            }
            total += size.int64Value
        }
        return total
    }

    // MARK: - Diagnostics

    private static func logStorageFailure(_ operation: String, _ error: Error) {
        if let databaseError = error as? DatabaseError {
            Diagnostics.storage.error(
                "Storage \(operation, privacy: .public) failed; sqlite result \(Int(databaseError.resultCode.rawValue), privacy: .public)")
        } else {
            Diagnostics.storage.error(
                "Storage \(operation, privacy: .public) failed")
        }
    }
}
