import Foundation
import GRDB

/// Bounded history retention.
///
/// Time-based cleanup removes old activity detail. Graph metadata that explains
/// a still-live service (its execution, ancestor chain, and Agent session) is
/// pinned regardless of age; unreferenced dead graph and retired configuration
/// versions are then removed. Live means "no exit was ever observed", which is
/// deliberately conservative: an unobserved exit never causes a source chain to
/// be discarded.
enum RetentionPolicy {
    /// Returns the number of activity rows removed by time or budget pressure.
    static func apply(
        db: Database,
        now: Date,
        configuration: MonitorConfiguration
    ) throws -> Int64 {
        let retentionSeconds = Double(configuration.retentionDays) * 86_400
        let cutoff = MicroTime.value(now.addingTimeInterval(-retentionSeconds))

        var deleted: Int64 = 0
        try db.execute(
            sql: "DELETE FROM activities WHERE occurred_at_us < ?",
            arguments: [cutoff])
        deleted += Int64(db.changesCount)

        try db.execute(
            sql: "DELETE FROM capture_gaps WHERE occurred_at_us < ?",
            arguments: [cutoff])
        try db.execute(
            sql: """
                DELETE FROM listener_intervals
                WHERE ended_at_us IS NOT NULL AND ended_at_us < ?
                """,
            arguments: [cutoff])
        try db.execute(
            sql: "DELETE FROM control_actions WHERE requested_at_us < ?",
            arguments: [cutoff])

        let budgetDeleted = try enforceBudget(
            db: db, budget: configuration.storageBudgetBytes)
        deleted += budgetDeleted
        try pruneUnreferenced(db: db, cutoff: cutoff)
        return deleted
    }

    /// Manual clear. Removes activity history but preserves the current
    /// configuration, live services, and the necessary source chain. The
    /// metadata watermark and the AUTOINCREMENT sequence are never reset.
    static func clear(db: Database) throws -> Int64 {
        try db.execute(sql: "DELETE FROM activities")
        let deleted = Int64(db.changesCount)

        try db.execute(sql: "DELETE FROM capture_gaps")
        try db.execute(sql: "DELETE FROM listener_intervals WHERE ended_at_us IS NOT NULL")
        try db.execute(sql: "DELETE FROM control_actions")

        try pruneUnreferenced(db: db, cutoff: nil)
        return deleted
    }

    /// Erase All Data. Removes every recorded row, including the source chains of
    /// running services and the control audit, and replaces the configuration with
    /// the built-in defaults committed as the next revision, so revisions stay
    /// monotonic. The metadata watermark and the AUTOINCREMENT sequences are never
    /// reset. Returns the new current configuration.
    static func eraseAll(db: Database) throws -> MonitorConfiguration {
        try db.execute(sql: "DELETE FROM activities")

        try db.execute(sql: """
            DELETE FROM capture_gaps;
            DELETE FROM listener_intervals;
            DELETE FROM control_actions;
            DELETE FROM execution_sessions;
            DELETE FROM agent_sessions;
            DELETE FROM execution_edges;
            UPDATE executions SET parent_execution_id = NULL, responsible_execution_id = NULL
                WHERE parent_execution_id IS NOT NULL OR responsible_execution_id IS NOT NULL;
            DELETE FROM executions;
            DELETE FROM process_instances;
            DELETE FROM projects;
            DELETE FROM capture_runs;
            DELETE FROM boot_epochs;
            """)

        let maxRevision: Int64 = try Int64.fetchOne(
            db, sql: "SELECT COALESCE(MAX(revision), 0) FROM configuration_versions") ?? 0
        var defaults = MonitorConfiguration()
        defaults.revision = maxRevision + 1
        try db.execute(
            sql: """
                INSERT INTO configuration_versions
                    (revision, mode, format_version, rules_json, agent_definitions_json,
                     retention_days, storage_budget_bytes, committed_at_us)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                defaults.revision,
                defaults.mode.rawValue,
                HistoryQueries.configurationFormatVersion,
                try ConfigurationJSON.encodeRules(defaults.rules),
                try ConfigurationJSON.encodeAgents(defaults.agentDefinitions),
                Int64(defaults.retentionDays),
                defaults.storageBudgetBytes,
                MicroTime.value(Date()),
            ])
        try db.execute(
            sql: "UPDATE preferences SET current_revision = ? WHERE id = 1",
            arguments: [defaults.revision])
        try db.execute(
            sql: "DELETE FROM configuration_versions WHERE revision <> ?",
            arguments: [defaults.revision])
        return defaults
    }

    // MARK: - Budget

    private static func enforceBudget(db: Database, budget: Int64) throws -> Int64 {
        let pageSize: Int = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4_096
        var deleted: Int64 = 0

        while try liveBytes(db: db, pageSize: pageSize) > budget {
            let remaining: Int = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM activities") ?? 0
            if remaining == 0 {
                break
            }

            // Delete in bounded chunks so old rows are reclaimed without
            // holding a long write transaction. File pages remain allocated
            // until SQLite reuses or vacuums them; this is a logical budget.
            try db.execute(sql: """
                DELETE FROM activities
                WHERE id IN (
                    SELECT id FROM activities
                    ORDER BY occurred_at_us, id
                    LIMIT 2_000)
                """)
            let batch = Int64(db.changesCount)
            if batch == 0 {
                break
            }
            deleted += batch
        }
        return deleted
    }

    private static func liveBytes(db: Database, pageSize: Int) throws -> Int64 {
        let pageCount: Int = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
        let freelistCount: Int = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
        return Int64(max(0, pageCount - freelistCount)) * Int64(pageSize)
    }

    // MARK: - Graph and configuration pruning

    private static func pruneUnreferenced(db: Database, cutoff: Int64?) throws {
        try db.execute(sql: """
            DROP TABLE IF EXISTS temp.retention_keep_executions;
            DROP TABLE IF EXISTS temp.retention_keep_sessions;
            CREATE TEMP TABLE retention_keep_executions (id INTEGER PRIMARY KEY);
            CREATE TEMP TABLE retention_keep_sessions (id TEXT PRIMARY KEY);
            """)

        // Executions that are live or directly referenced by retained history.
        try db.execute(sql: """
            INSERT OR IGNORE INTO retention_keep_executions(id)
            SELECT id FROM executions WHERE ended_at_us IS NULL
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO retention_keep_executions(id)
            SELECT execution_id FROM activities WHERE execution_id IS NOT NULL
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO retention_keep_executions(id)
            SELECT execution_id FROM listener_intervals
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO retention_keep_executions(id)
            SELECT execution_id FROM control_actions
            """)

        // Sessions that are live, recent, or pinned by retained activity.
        if let cutoff {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO retention_keep_sessions(id)
                    SELECT id FROM agent_sessions
                    WHERE ended_at_us IS NULL
                       OR ended_at_us >= ?
                       OR id IN (SELECT session_id FROM activity_sessions)
                    """,
                arguments: [cutoff])
        } else {
            try db.execute(sql: """
                INSERT OR IGNORE INTO retention_keep_sessions(id)
                SELECT id FROM agent_sessions
                WHERE ended_at_us IS NULL
                   OR id IN (SELECT session_id FROM activity_sessions)
                """)
        }

        // Pin roots, ancestors, and sessions transitively. The sets only grow,
        // so a small fixed point loop terminates on any finite graph.
        while true {
            var changed = 0

            let roots = try insertRootsOfKeptSessions(db)
            let edges = try insertEdgeAncestors(db)
            let parents = try insertParentAncestors(db)
            let rooted = try insertSessionsRootedInKeptExecutions(db)
            let associated = try insertSessionsAssociatedWithKeptExecutions(db)
            changed += roots + edges + parents + rooted + associated
            if changed == 0 {
                break
            }
        }

        // Clear associations before either side can disappear.
        try db.execute(sql: """
            DELETE FROM execution_sessions
            WHERE execution_id NOT IN (SELECT id FROM retention_keep_executions)
               OR session_id NOT IN (SELECT id FROM retention_keep_sessions)
            """)

        // A session that no retained activity references and that is neither
        // live nor pinned by a live chain is retired.
        try db.execute(sql: """
            DELETE FROM agent_sessions
            WHERE id NOT IN (SELECT id FROM retention_keep_sessions)
            """)

        try db.execute(sql: """
            DELETE FROM execution_edges
            WHERE child_execution_id NOT IN (SELECT id FROM retention_keep_executions)
               OR parent_execution_id NOT IN (SELECT id FROM retention_keep_executions)
            """)

        // Break self-references to executions that are about to be deleted so
        // deleting the remaining rows cannot trip an immediate RESTRICT check.
        try db.execute(sql: """
            UPDATE executions SET parent_execution_id = NULL
            WHERE parent_execution_id IS NOT NULL
              AND parent_execution_id NOT IN (SELECT id FROM retention_keep_executions)
            """)
        try db.execute(sql: """
            UPDATE executions SET responsible_execution_id = NULL
            WHERE responsible_execution_id IS NOT NULL
              AND responsible_execution_id NOT IN (SELECT id FROM retention_keep_executions)
            """)

        try db.execute(sql: """
            DELETE FROM executions
            WHERE id NOT IN (SELECT id FROM retention_keep_executions)
            """)

        try db.execute(sql: """
            DELETE FROM process_instances
            WHERE id NOT IN (SELECT process_id FROM executions)
            """)

        try db.execute(sql: """
            DELETE FROM projects
            WHERE id NOT IN (
                    SELECT project_id FROM agent_sessions WHERE project_id IS NOT NULL)
              AND id NOT IN (
                    SELECT project_id FROM activities WHERE project_id IS NOT NULL)
            """)

        // Immutable configurations remain available while any retained activity
        // or the current preference still references them.
        try db.execute(sql: """
            DELETE FROM configuration_versions
            WHERE revision NOT IN (SELECT configuration_revision FROM activities)
              AND revision NOT IN (SELECT current_revision FROM preferences)
            """)

        // An active capture interval is still receiving data; ended capture
        // runs with no remaining references are history.
        try db.execute(sql: """
            DELETE FROM capture_runs
            WHERE ended_at_us IS NOT NULL
              AND id NOT IN (SELECT capture_id FROM activities)
              AND id NOT IN (SELECT capture_id FROM capture_gaps)
              AND id NOT IN (
                    SELECT capture_id FROM execution_edges WHERE capture_id IS NOT NULL)
            """)

        try db.execute(sql: """
            DELETE FROM boot_epochs
            WHERE id NOT IN (SELECT boot_id FROM capture_runs)
              AND id NOT IN (SELECT boot_id FROM process_instances)
            """)

        try db.execute(sql: """
            DROP TABLE IF EXISTS temp.retention_keep_executions;
            DROP TABLE IF EXISTS temp.retention_keep_sessions;
            """)
    }

    private static func insertRootsOfKeptSessions(_ db: Database) throws -> Int {
        try db.execute(sql: """
            INSERT OR IGNORE INTO retention_keep_executions(id)
            SELECT root_execution_id FROM agent_sessions
            WHERE id IN (SELECT id FROM retention_keep_sessions)
            """)
        return db.changesCount
    }

    private static func insertEdgeAncestors(_ db: Database) throws -> Int {
        try db.execute(sql: """
            WITH RECURSIVE ancestors(id) AS (
                SELECT ee.parent_execution_id
                FROM execution_edges ee
                WHERE ee.kind IN ('fork', 'exec')
                  AND ee.child_execution_id IN (SELECT id FROM retention_keep_executions)
                UNION
                SELECT ee.parent_execution_id
                FROM execution_edges ee
                JOIN ancestors a ON ee.child_execution_id = a.id
                WHERE ee.kind IN ('fork', 'exec')
            )
            INSERT OR IGNORE INTO retention_keep_executions(id)
            SELECT id FROM ancestors WHERE id IS NOT NULL
            """)
        return db.changesCount
    }

    private static func insertParentAncestors(_ db: Database) throws -> Int {
        try db.execute(sql: """
            WITH RECURSIVE ancestors(id) AS (
                SELECT e.parent_execution_id
                FROM executions e
                WHERE e.parent_execution_id IS NOT NULL
                  AND e.id IN (SELECT id FROM retention_keep_executions)
                UNION
                SELECT e.parent_execution_id
                FROM executions e
                JOIN ancestors a ON e.id = a.id
                WHERE e.parent_execution_id IS NOT NULL
            )
            INSERT OR IGNORE INTO retention_keep_executions(id)
            SELECT id FROM ancestors WHERE id IS NOT NULL
            """)
        return db.changesCount
    }

    private static func insertSessionsRootedInKeptExecutions(_ db: Database) throws -> Int {
        try db.execute(sql: """
            INSERT OR IGNORE INTO retention_keep_sessions(id)
            SELECT id FROM agent_sessions
            WHERE root_execution_id IN (SELECT id FROM retention_keep_executions)
            """)
        return db.changesCount
    }

    private static func insertSessionsAssociatedWithKeptExecutions(_ db: Database) throws -> Int {
        try db.execute(sql: """
            INSERT OR IGNORE INTO retention_keep_sessions(id)
            SELECT es.session_id FROM execution_sessions es
            WHERE es.execution_id IN (SELECT id FROM retention_keep_executions)
            """)
        return db.changesCount
    }
}
