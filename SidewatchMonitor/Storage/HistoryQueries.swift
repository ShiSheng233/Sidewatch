import Foundation
import GRDB

/// Read-side queries. Everything here runs inside a GRDB read transaction and
/// returns Shared DTOs only; no GRDB row or connection escapes the closure.
enum HistoryQueries {
    static func metadata(_ db: Database) throws -> StoreMetadata {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT store_identifier, watermark, format_version FROM store_metadata WHERE id = 1")
        else {
            throw ActivityStoreError.corruptRecord
        }
        return StoreMetadata(
            storeID: try RowMapping.required(row, "store_identifier"),
            watermark: try RowMapping.required(row, "watermark"),
            formatVersion: try RowMapping.required(row, "format_version"))
    }

    // MARK: - Graph

    static func graph(_ db: Database) throws -> GraphSnapshot {
        var snapshot = GraphSnapshot()
        snapshot.executions = try executions(db)
        snapshot.edges = try edges(db)
        snapshot.sessions = try sessions(db)
        snapshot.associations = try associations(db)
        return snapshot
    }

    private static func executions(_ db: Database) throws -> [ExecutionRecord] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.pidversion, e.parent_pid, e.user_id, e.executable, e.arguments_json,
                   e.working_directory, e.signing_id, e.team_id, e.started_at_us, e.ended_at_us,
                   e.evidence,
                   e.parent_boot_identifier, e.parent_identity_pid,
                   e.parent_identity_start_us, e.parent_identity_pidversion,
                   e.responsible_boot_identifier, e.responsible_identity_pid,
                   e.responsible_identity_start_us, e.responsible_identity_pidversion,
                   b.boot_identifier, pi.pid, pi.start_time_us
            FROM executions e
            JOIN process_instances pi ON pi.id = e.process_id
            JOIN boot_epochs b ON b.id = pi.boot_id
            ORDER BY e.id
            """)
        return try rows.map { try RowMapping.execution(from: $0) }
    }

    private static func edges(_ db: Database) throws -> [ExecutionEdge] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT ee.kind, ee.evidence, ee.observed_at_us,
                   pb.boot_identifier AS parent_boot,
                   pp.pid AS parent_pid,
                   pp.start_time_us AS parent_start,
                   pe.pidversion AS parent_version,
                   cb.boot_identifier AS child_boot,
                   cp.pid AS child_pid,
                   cp.start_time_us AS child_start,
                   ce.pidversion AS child_version
            FROM execution_edges ee
            JOIN executions pe ON pe.id = ee.parent_execution_id
            JOIN process_instances pp ON pp.id = pe.process_id
            JOIN boot_epochs pb ON pb.id = pp.boot_id
            JOIN executions ce ON ce.id = ee.child_execution_id
            JOIN process_instances cp ON cp.id = ce.process_id
            JOIN boot_epochs cb ON cb.id = cp.boot_id
            ORDER BY ee.id
            """)
        return try rows.map { row in
            let parentBoot: String = try RowMapping.required(row, "parent_boot")
            let parentPid: Int64 = try RowMapping.required(row, "parent_pid")
            let parentStart: Int64 = try RowMapping.required(row, "parent_start")
            let parentVersion: Int64 = try RowMapping.required(row, "parent_version")
            let childBoot: String = try RowMapping.required(row, "child_boot")
            let childPid: Int64 = try RowMapping.required(row, "child_pid")
            let childStart: Int64 = try RowMapping.required(row, "child_start")
            let childVersion: Int64 = try RowMapping.required(row, "child_version")

            guard let parent = try RowMapping.identity(
                    boot: parentBoot, pid: parentPid, start: parentStart, version: parentVersion),
                  let child = try RowMapping.identity(
                    boot: childBoot, pid: childPid, start: childStart, version: childVersion)
            else {
                throw ActivityStoreError.corruptRecord
            }

            let evidence: EvidenceKind = try RowMapping.enumValue(
                row, "evidence", as: EvidenceKind.self)
            return ExecutionEdge(
                parent: parent,
                child: child,
                kind: try RowMapping.enumValue(row, "kind", as: EdgeKind.self),
                evidence: evidence,
                observedAt: MicroTime.date(try RowMapping.required(row, "observed_at_us")))
        }
    }

    private static func sessions(_ db: Database) throws -> [AgentSession] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.id, s.agent_id, s.agent_name, s.executable_names_json,
                   s.script_path_components_json, s.started_at_us, s.ended_at_us,
                   s.end_reason, s.evidence,
                   b.boot_identifier AS root_boot, pi.pid AS root_pid,
                   pi.start_time_us AS root_start, e.pidversion AS root_version,
                   p.canonical_root AS project_root, p.git_directory AS project_git
            FROM agent_sessions s
            JOIN executions e ON e.id = s.root_execution_id
            JOIN process_instances pi ON pi.id = e.process_id
            JOIN boot_epochs b ON b.id = pi.boot_id
            LEFT JOIN projects p ON p.id = s.project_id
            ORDER BY s.started_at_us, s.id
            """)
        return try rows.map { row in
            let rootBoot: String = try RowMapping.required(row, "root_boot")
            let rootPid: Int64 = try RowMapping.required(row, "root_pid")
            let rootStart: Int64 = try RowMapping.required(row, "root_start")
            let rootVersion: Int64 = try RowMapping.required(row, "root_version")
            guard let root = try RowMapping.identity(
                boot: rootBoot, pid: rootPid, start: rootStart, version: rootVersion)
            else {
                throw ActivityStoreError.corruptRecord
            }

            let executableNamesJSON: String = try RowMapping.required(
                row, "executable_names_json")
            let scriptComponentsJSON: String = try RowMapping.required(
                row, "script_path_components_json")
            let agent = AgentDefinition(
                id: try RowMapping.required(row, "agent_id"),
                name: try RowMapping.required(row, "agent_name"),
                executableNames: try ConfigurationJSON.decodeStringArray(executableNamesJSON),
                scriptPathComponents: try ConfigurationJSON.decodeStringArray(scriptComponentsJSON))

            let projectRoot: String? = try RowMapping.optional(row, "project_root")
            let projectGit: String? = try RowMapping.optional(row, "project_git")
            let project = projectRoot.map {
                ProjectRecord(root: $0, gitDirectory: projectGit)
            }
            let endedAtMicros: Int64? = try RowMapping.optional(row, "ended_at_us")
            let evidence: EvidenceKind = try RowMapping.enumValue(
                row, "evidence", as: EvidenceKind.self)

            return AgentSession(
                id: try RowMapping.required(row, "id"),
                agent: agent,
                root: root,
                project: project,
                startedAt: MicroTime.date(try RowMapping.required(row, "started_at_us")),
                endedAt: endedAtMicros.map(MicroTime.date),
                endReason: try RowMapping.optional(row, "end_reason"),
                evidence: evidence)
        }
    }

    private static func associations(_ db: Database) throws -> [ExecutionAssociation] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT es.session_id, es.evidence,
                   b.boot_identifier, pi.pid, pi.start_time_us, e.pidversion
            FROM execution_sessions es
            JOIN executions e ON e.id = es.execution_id
            JOIN process_instances pi ON pi.id = e.process_id
            JOIN boot_epochs b ON b.id = pi.boot_id
            ORDER BY es.execution_id, es.session_id
            """)
        return try rows.map { row in
            let boot: String = try RowMapping.required(row, "boot_identifier")
            let pid: Int64 = try RowMapping.required(row, "pid")
            let start: Int64 = try RowMapping.required(row, "start_time_us")
            let version: Int64 = try RowMapping.required(row, "pidversion")
            guard let execution = try RowMapping.identity(
                boot: boot, pid: pid, start: start, version: version)
            else {
                throw ActivityStoreError.corruptRecord
            }
            return ExecutionAssociation(
                execution: execution,
                sessionID: try RowMapping.required(row, "session_id"),
                evidence: try RowMapping.enumValue(row, "evidence", as: EvidenceKind.self))
        }
    }

    // MARK: - Endpoints

    static func activeEndpoints(_ db: Database) throws -> [ListeningEndpoint] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT b.boot_identifier, pi.pid, pi.start_time_us, e.pidversion,
                   li.transport, li.address, li.address_family, li.scope_id, li.port,
                   li.first_observed_at_us, li.last_observed_at_us, li.ended_at_us
            FROM listener_intervals li
            JOIN executions e ON e.id = li.execution_id
            JOIN process_instances pi ON pi.id = e.process_id
            JOIN boot_epochs b ON b.id = pi.boot_id
            WHERE li.ended_at_us IS NULL
            ORDER BY li.port, li.transport, li.address, li.execution_id
            """)
        return try rows.map { row in
            let boot: String = try RowMapping.required(row, "boot_identifier")
            let pid: Int64 = try RowMapping.required(row, "pid")
            let start: Int64 = try RowMapping.required(row, "start_time_us")
            let version: Int64 = try RowMapping.required(row, "pidversion")
            guard let execution = try RowMapping.identity(
                boot: boot, pid: pid, start: start, version: version)
            else {
                throw ActivityStoreError.corruptRecord
            }
            let portValue: Int64 = try RowMapping.required(row, "port")
            guard let port = UInt16(exactly: portValue) else {
                throw ActivityStoreError.corruptRecord
            }
            let endedAtMicros: Int64? = try RowMapping.optional(row, "ended_at_us")
            return ListeningEndpoint(
                execution: execution,
                transport: try RowMapping.enumValue(row, "transport", as: TransportProtocol.self),
                address: try RowMapping.required(row, "address"),
                addressFamily: try RowMapping.int32(row, "address_family"),
                scopeID: try RowMapping.uint32(row, "scope_id"),
                port: port,
                firstObservedAt: MicroTime.date(
                    try RowMapping.required(row, "first_observed_at_us")),
                lastObservedAt: MicroTime.date(
                    try RowMapping.required(row, "last_observed_at_us")),
                endedAt: endedAtMicros.map(MicroTime.date))
        }
    }

    // MARK: - Configuration

    static let configurationFormatVersion = 1

    static func currentConfiguration(_ db: Database) throws -> MonitorConfiguration {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT revision, mode, format_version, rules_json, agent_definitions_json,
                   retention_days, storage_budget_bytes
            FROM configuration_versions
            WHERE revision = COALESCE(
                (SELECT current_revision FROM preferences WHERE id = 1),
                (SELECT MAX(revision) FROM configuration_versions))
            """)
        else {
            throw ActivityStoreError.corruptRecord
        }

        let formatVersion: Int64 = try RowMapping.required(row, "format_version")
        guard formatVersion <= Int64(configurationFormatVersion) else {
            throw ActivityStoreError.unsupportedConfigurationFormat(Int(formatVersion))
        }

        let rulesJSON: String = try RowMapping.required(row, "rules_json")
        let agentsJSON: String = try RowMapping.required(row, "agent_definitions_json")
        let retention: Int64 = try RowMapping.required(row, "retention_days")
        guard let retentionDays = Int(exactly: retention), retentionDays > 0 else {
            throw ActivityStoreError.corruptRecord
        }
        let budget: Int64 = try RowMapping.required(row, "storage_budget_bytes")
        guard budget > 0 else {
            throw ActivityStoreError.corruptRecord
        }

        return MonitorConfiguration(
            revision: try RowMapping.required(row, "revision"),
            mode: try RowMapping.enumValue(row, "mode", as: MonitoringMode.self),
            rules: try ConfigurationJSON.decodeRules(rulesJSON),
            agentDefinitions: try ConfigurationJSON.decodeAgents(agentsJSON),
            retentionDays: retentionDays,
            storageBudgetBytes: budget)
    }

    static func oldestActivity(_ db: Database) throws -> Date? {
        guard let micros: Int64 = try Int64.fetchOne(
            db, sql: "SELECT MIN(occurred_at_us) FROM activities")
        else {
            return nil
        }
        return MicroTime.date(micros)
    }

    static func captures(_ db: Database) throws -> [CaptureRecord] {
        try Row.fetchAll(db, sql: """
            SELECT c.capture_identifier, b.boot_identifier, c.started_at_us, c.ended_at_us
            FROM capture_runs c JOIN boot_epochs b ON b.id = c.boot_id
            ORDER BY c.started_at_us, c.id
            """).map { row in
                let ended: Int64? = row["ended_at_us"]
                return CaptureRecord(id: try RowMapping.required(row, "capture_identifier"),
                                     bootID: try RowMapping.required(row, "boot_identifier"),
                                     startedAt: MicroTime.date(try RowMapping.required(row, "started_at_us")),
                                     endedAt: ended.map(MicroTime.date))
            }
    }

    static func gaps(_ db: Database) throws -> [CollectionGap] {
        try Row.fetchAll(db, sql: """
            SELECT c.capture_identifier, g.occurred_at_us, g.reason, g.missing_count
            FROM capture_gaps g JOIN capture_runs c ON c.id = g.capture_id
            ORDER BY g.occurred_at_us, g.id
            """).map { row in
                let count: Int64? = row["missing_count"]
                if let count, count < 0 { throw ActivityStoreError.corruptRecord }
                return CollectionGap(captureID: try RowMapping.required(row, "capture_identifier"),
                                     occurredAt: MicroTime.date(try RowMapping.required(row, "occurred_at_us")),
                                     reason: try RowMapping.required(row, "reason"),
                                     missingCount: count.map(UInt64.init))
            }
    }

    // MARK: - Activity pages

    static func page(
        _ db: Database,
        storeID: String,
        query: ActivityQuery
    ) throws -> ActivityPage {
        if let requested = query.storeID, requested != storeID {
            throw ActivityStoreError.storeIdentifierMismatch
        }
        if query.beforeID != nil && query.afterID != nil {
            throw ActivityStoreError.invalidQuery("beforeID and afterID")
        }
        if let beforeID = query.beforeID, beforeID <= 0 {
            throw ActivityStoreError.invalidQuery("beforeID")
        }
        if let afterID = query.afterID, afterID < 0 {
            throw ActivityStoreError.invalidQuery("afterID")
        }

        let storeMetadata = try metadata(db)
        if let watermark = query.watermark {
            guard watermark >= 0, watermark <= storeMetadata.watermark else {
                throw ActivityStoreError.invalidWatermark(watermark)
            }
        }
        let pageWatermark = query.watermark ?? storeMetadata.watermark

        var conditions: [String] = ["a.id <= ?"]
        var arguments: [(any DatabaseValueConvertible)?] = [pageWatermark]

        if !query.text.isEmpty {
            let text = query.text
            var textGroup = """
                (instr(lower(COALESCE(a.source_path, '')), lower(?)) > 0
                 OR instr(lower(COALESCE(a.target_path, '')), lower(?)) > 0
                 OR instr(lower(COALESCE(a.detail, '')), lower(?)) > 0
                 OR EXISTS (
                     SELECT 1 FROM projects p2
                     WHERE p2.id = a.project_id
                       AND instr(lower(p2.canonical_root), lower(?)) > 0)
                 OR EXISTS (
                     SELECT 1 FROM executions e2
                     WHERE e2.id = a.execution_id
                       AND instr(lower(e2.command_text), lower(?)) > 0)
                """
            var textArguments: [(any DatabaseValueConvertible)?] = [
                text, text, text, text, text,
            ]

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let port = Int(trimmed), (0...65535).contains(port) {
                // A numeric search also enters through the execution's observed
                // endpoints. This is an alternative to the literal text match,
                // not an additional requirement on the same row.
                textGroup += """
                     OR EXISTS (
                         SELECT 1 FROM listener_intervals li
                         WHERE li.execution_id = a.execution_id AND li.port = ?)
                    """
                textArguments.append(port)
            }

            textGroup += ")"
            conditions.append(textGroup)
            arguments.append(contentsOf: textArguments)
        }

        if let sessionID = query.sessionID {
            conditions.append("""
                EXISTS (
                    SELECT 1 FROM activity_sessions ax
                    WHERE ax.activity_id = a.id AND ax.session_id = ?)
                """)
            arguments.append(sessionID)
        }

        if let projectRoot = query.projectRoot {
            conditions.append("""
                EXISTS (
                    SELECT 1 FROM projects p3
                    WHERE p3.id = a.project_id AND p3.canonical_root = ?)
                """)
            arguments.append(projectRoot)
        }

        if let execution = query.execution {
            conditions.append("""
                a.execution_id IN (
                    SELECT e3.id
                    FROM executions e3
                    JOIN process_instances pi3 ON pi3.id = e3.process_id
                    JOIN boot_epochs b3 ON b3.id = pi3.boot_id
                    WHERE b3.boot_identifier = ?
                      AND pi3.pid = ?
                      AND pi3.start_time_us = ?
                      AND e3.pidversion = ?)
                """)
            arguments.append(execution.process.bootID)
            arguments.append(Int64(execution.process.pid))
            arguments.append(execution.process.startTimeMicros)
            arguments.append(Int64(execution.version))
        }

        if let kind = query.kind {
            conditions.append("a.kind = ?")
            arguments.append(kind.rawValue)
        }

        if let outcome = query.outcome {
            switch outcome.lowercased() {
            case "wouldblock":
                conditions.append("a.evaluation = 'deny' AND a.response = 'allow'")
            case "blocked", "denied", "deny":
                conditions.append("a.response = 'deny'")
            case "allowed", "allow":
                conditions.append("a.response = 'allow'")
            case "failed":
                conditions.append("a.response = 'failed'")
            case "notapplicable":
                conditions.append("a.response = 'notApplicable'")
            default:
                throw ActivityStoreError.invalidQuery("outcome")
            }
        }

        let ascending = query.afterID != nil
        if let afterID = query.afterID {
            conditions.append("a.id > ?")
            arguments.append(afterID)
        }
        if let beforeID = query.beforeID {
            conditions.append("a.id < ?")
            arguments.append(beforeID)
        }

        let limit = min(max(query.limit, 1), 500)
        let order = ascending ? "ASC" : "DESC"
        let sql = """
            SELECT a.id AS activity_id, c.capture_identifier, a.source_seq,
                   a.occurred_at_us, a.kind, a.source_path, a.target_path,
                   a.device, a.inode, a.configuration_revision, a.mode,
                   a.evidence, a.evaluation, a.response, a.detail,
                   a.execution_id, a.project_id,
                   b.boot_identifier AS execution_boot,
                   pi.pid AS execution_pid,
                   pi.start_time_us AS execution_start,
                   e.pidversion AS execution_version,
                   p.canonical_root AS project_root
            FROM activities a
            JOIN capture_runs c ON c.id = a.capture_id
            LEFT JOIN executions e ON e.id = a.execution_id
            LEFT JOIN process_instances pi ON pi.id = e.process_id
            LEFT JOIN boot_epochs b ON b.id = pi.boot_id
            LEFT JOIN projects p ON p.id = a.project_id
            WHERE \(conditions.joined(separator: "\n  AND "))
            ORDER BY a.id \(order)
            LIMIT ?
            """
        arguments.append(limit)

        let rows = try Row.fetchAll(
            db, sql: sql, arguments: StatementArguments(arguments))
        var records = try rows.map { try activity(from: $0) }

        let activityIDs = records.map(\.id)
        let sessionIDs = try sessionsByActivity(db, activityIDs: activityIDs)
        let ruleIDs = try rulesByActivity(db, activityIDs: activityIDs)
        for index in records.indices {
            let id = records[index].id
            records[index].sessionIDs = sessionIDs[id] ?? []
            records[index].matchedRuleIDs = ruleIDs[id] ?? []
        }

        // In beforeID/first-page mode this is the oldest returned id for the
        // next older page. In afterID reconnect mode the rows ascend and the
        // last id is the continuation cursor for the next catch-up page.
        let nextCursor = records.count == limit ? records.last?.id : nil
        return ActivityPage(
            storeID: storeID,
            watermark: pageWatermark,
            activities: records,
            nextBeforeID: nextCursor)
    }

    private static func activity(from row: Row) throws -> ActivityRecord {
        let id: Int64 = try RowMapping.required(row, "activity_id")
        let rawSourceSequence: Int64? = try RowMapping.optional(row, "source_seq")
        let sourceSequence: UInt64?
        if let rawSourceSequence {
            guard let converted = UInt64(exactly: rawSourceSequence) else {
                throw ActivityStoreError.corruptRecord
            }
            sourceSequence = converted
        } else {
            sourceSequence = nil
        }

        let device: Int64? = try RowMapping.optional(row, "device")
        let inode: Int64? = try RowMapping.optional(row, "inode")
        let fileIdentity: FileIdentity?
        if device != nil || inode != nil {
            guard let device, let inode,
                  let deviceValue = UInt64(exactly: device),
                  let inodeValue = UInt64(exactly: inode)
            else {
                throw ActivityStoreError.corruptRecord
            }
            fileIdentity = FileIdentity(device: deviceValue, inode: inodeValue)
        } else {
            fileIdentity = nil
        }

        let executionID: Int64? = try RowMapping.optional(row, "execution_id")
        let execution: ExecutionIdentity?
        if executionID != nil {
            let boot: String = try RowMapping.required(row, "execution_boot")
            let pid: Int64 = try RowMapping.required(row, "execution_pid")
            let start: Int64 = try RowMapping.required(row, "execution_start")
            let version: Int64 = try RowMapping.required(row, "execution_version")
            guard let identity = try RowMapping.identity(
                boot: boot, pid: pid, start: start, version: version)
            else {
                throw ActivityStoreError.corruptRecord
            }
            execution = identity
        } else {
            execution = nil
        }

        return try makeActivity(
            id: id,
            row: row,
            fileIdentity: fileIdentity,
            execution: execution,
            sourceSequence: sourceSequence)
    }

    private static func makeActivity(
        id: Int64,
        row: Row,
        fileIdentity: FileIdentity?,
        execution: ExecutionIdentity?,
        sourceSequence: UInt64?
    ) throws -> ActivityRecord {
        let occurredAtMicros: Int64 = try RowMapping.required(row, "occurred_at_us")
        let configurationRevision: Int64 = try RowMapping.required(
            row, "configuration_revision")
        let sourcePath: String? = try RowMapping.optional(row, "source_path")
        let targetPath: String? = try RowMapping.optional(row, "target_path")
        let projectRoot: String? = try RowMapping.optional(row, "project_root")
        let detail: String? = try RowMapping.optional(row, "detail")
        let evidence: EvidenceKind = try RowMapping.enumValue(
            row, "evidence", as: EvidenceKind.self)

        return ActivityRecord(
            id: id,
            captureID: try RowMapping.required(row, "capture_identifier"),
            sourceSequence: sourceSequence,
            execution: execution,
            occurredAt: MicroTime.date(occurredAtMicros),
            kind: try RowMapping.enumValue(row, "kind", as: ActivityKind.self),
            sourcePath: sourcePath,
            targetPath: targetPath,
            fileIdentity: fileIdentity,
            projectRoot: projectRoot,
            sessionIDs: [],
            evidence: evidence,
            configurationRevision: configurationRevision,
            mode: try RowMapping.enumValue(row, "mode", as: MonitoringMode.self),
            evaluation: try RowMapping.enumValue(row, "evaluation", as: RuleEvaluation.self),
            response: try RowMapping.enumValue(row, "response", as: SystemResponse.self),
            matchedRuleIDs: [],
            detail: detail)
    }

    private static func sessionsByActivity(
        _ db: Database,
        activityIDs: [Int64]
    ) throws -> [Int64: [String]] {
        guard !activityIDs.isEmpty else { return [:] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT activity_id, session_id
                FROM activity_sessions
                WHERE activity_id IN (\(placeholders(activityIDs.count)))
                ORDER BY activity_id, session_id
                """,
            arguments: StatementArguments(activityIDs))
        var result: [Int64: [String]] = [:]
        for row in rows {
            let activityID: Int64 = try RowMapping.required(row, "activity_id")
            let sessionID: String = try RowMapping.required(row, "session_id")
            result[activityID, default: []].append(sessionID)
        }
        return result
    }

    private static func rulesByActivity(
        _ db: Database,
        activityIDs: [Int64]
    ) throws -> [Int64: [String]] {
        guard !activityIDs.isEmpty else { return [:] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT activity_id, rule_key
                FROM rule_matches
                WHERE activity_id IN (\(placeholders(activityIDs.count)))
                ORDER BY activity_id, rule_key
                """,
            arguments: StatementArguments(activityIDs))
        var result: [Int64: [String]] = [:]
        for row in rows {
            let activityID: Int64 = try RowMapping.required(row, "activity_id")
            let ruleKey: String = try RowMapping.required(row, "rule_key")
            result[activityID, default: []].append(ruleKey)
        }
        return result
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}
