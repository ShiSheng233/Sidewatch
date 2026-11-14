import Foundation
import GRDB

/// Ordered, immutable schema migrations for the per-user activity database.
///
/// Migration identifiers are part of the on-disk contract. Never rename,
/// reorder, or edit a shipped migration: GRDB records applied identifiers in
/// the `grdb_migrations` table, and a database produced by a newer build is
/// rejected instead of being erased or downgraded.
enum DatabaseMigrations {
    /// First shipped schema. Pre-release development history is not preserved;
    /// later releases append migrations after this one.
    static let v1Initial = "v1_initial"

    /// Highest schema representation this build understands. Stored in
    /// `store_metadata.format_version` so a future build that changes only
    /// table content is also rejected.
    static let latestFormatVersion = 1

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Schema erasure is never enabled: a development build sharing this
        // extension's data directory must not destroy real history.
        migrator.eraseDatabaseOnSchemaChange = false

        migrator.registerMigration(v1Initial) { db in
            try db.execute(sql: """
                CREATE TABLE boot_epochs (
                    id INTEGER PRIMARY KEY,
                    boot_identifier TEXT NOT NULL UNIQUE,
                    started_at_us INTEGER NOT NULL
                );

                CREATE TABLE capture_runs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    capture_identifier TEXT NOT NULL UNIQUE,
                    boot_id INTEGER NOT NULL REFERENCES boot_epochs(id) ON DELETE RESTRICT,
                    started_at_us INTEGER NOT NULL,
                    ended_at_us INTEGER,
                    last_received_seq INTEGER,
                    last_committed_seq INTEGER
                );

                CREATE TABLE projects (
                    id INTEGER PRIMARY KEY,
                    canonical_root TEXT NOT NULL UNIQUE,
                    git_directory TEXT,
                    display_name TEXT NOT NULL
                );

                CREATE TABLE process_instances (
                    id INTEGER PRIMARY KEY,
                    boot_id INTEGER NOT NULL REFERENCES boot_epochs(id) ON DELETE RESTRICT,
                    pid INTEGER NOT NULL,
                    start_time_us INTEGER NOT NULL,
                    uid INTEGER,
                    UNIQUE(boot_id, pid, start_time_us)
                );

                CREATE TABLE executions (
                    id INTEGER PRIMARY KEY,
                    process_id INTEGER NOT NULL REFERENCES process_instances(id) ON DELETE RESTRICT,
                    pidversion INTEGER NOT NULL,
                    parent_execution_id INTEGER REFERENCES executions(id) ON DELETE RESTRICT,
                    responsible_execution_id INTEGER REFERENCES executions(id) ON DELETE RESTRICT,
                    parent_pid INTEGER NOT NULL,
                    user_id INTEGER NOT NULL,
                    executable TEXT NOT NULL,
                    arguments_json TEXT NOT NULL,
                    command_text TEXT NOT NULL,
                    working_directory TEXT,
                    signing_id TEXT,
                    team_id TEXT,
                    started_at_us INTEGER NOT NULL,
                    ended_at_us INTEGER,
                    state TEXT NOT NULL CHECK(state IN ('running', 'exited', 'unknown')),
                    evidence TEXT NOT NULL CHECK(evidence IN ('observed', 'snapshot', 'inferred', 'responsible')),
                    parent_boot_identifier TEXT,
                    parent_identity_pid INTEGER,
                    parent_identity_start_us INTEGER,
                    parent_identity_pidversion INTEGER,
                    responsible_boot_identifier TEXT,
                    responsible_identity_pid INTEGER,
                    responsible_identity_start_us INTEGER,
                    responsible_identity_pidversion INTEGER,
                    UNIQUE(process_id, pidversion)
                );

                CREATE TABLE execution_edges (
                    id INTEGER PRIMARY KEY,
                    parent_execution_id INTEGER NOT NULL REFERENCES executions(id) ON DELETE RESTRICT,
                    child_execution_id INTEGER NOT NULL REFERENCES executions(id) ON DELETE RESTRICT,
                    kind TEXT NOT NULL CHECK(kind IN ('fork', 'exec', 'responsible')),
                    evidence TEXT NOT NULL CHECK(evidence IN ('observed', 'snapshot', 'inferred', 'responsible')),
                    capture_id INTEGER REFERENCES capture_runs(id) ON DELETE RESTRICT,
                    observed_at_us INTEGER NOT NULL,
                    CHECK(parent_execution_id <> child_execution_id),
                    UNIQUE(parent_execution_id, child_execution_id, kind)
                );

                CREATE TABLE agent_sessions (
                    id TEXT PRIMARY KEY,
                    root_execution_id INTEGER NOT NULL REFERENCES executions(id) ON DELETE RESTRICT,
                    agent_id TEXT NOT NULL,
                    agent_name TEXT NOT NULL,
                    executable_names_json TEXT NOT NULL,
                    script_path_components_json TEXT NOT NULL,
                    project_id INTEGER REFERENCES projects(id) ON DELETE RESTRICT,
                    started_at_us INTEGER NOT NULL,
                    ended_at_us INTEGER,
                    end_reason TEXT,
                    evidence TEXT NOT NULL CHECK(evidence IN ('observed', 'snapshot', 'inferred', 'responsible'))
                );

                CREATE TABLE execution_sessions (
                    execution_id INTEGER NOT NULL REFERENCES executions(id) ON DELETE RESTRICT,
                    session_id TEXT NOT NULL REFERENCES agent_sessions(id) ON DELETE RESTRICT,
                    evidence TEXT NOT NULL CHECK(evidence IN ('observed', 'snapshot', 'inferred', 'responsible')),
                    observed_at_us INTEGER NOT NULL,
                    PRIMARY KEY(execution_id, session_id)
                );

                CREATE TABLE store_metadata (
                    id INTEGER PRIMARY KEY CHECK(id = 1),
                    store_identifier TEXT NOT NULL,
                    created_at_us INTEGER NOT NULL,
                    watermark INTEGER NOT NULL DEFAULT 0,
                    format_version INTEGER NOT NULL
                );

                CREATE TABLE configuration_versions (
                    revision INTEGER PRIMARY KEY,
                    mode TEXT NOT NULL CHECK(mode IN ('recordOnly', 'dryRun', 'protect')),
                    format_version INTEGER NOT NULL,
                    rules_json TEXT NOT NULL,
                    agent_definitions_json TEXT NOT NULL,
                    retention_days INTEGER NOT NULL CHECK(retention_days > 0),
                    storage_budget_bytes INTEGER NOT NULL CHECK(storage_budget_bytes > 0),
                    committed_at_us INTEGER NOT NULL
                );

                CREATE TABLE preferences (
                    id INTEGER PRIMARY KEY CHECK(id = 1),
                    current_revision INTEGER NOT NULL REFERENCES configuration_versions(revision) ON DELETE RESTRICT
                );

                CREATE TABLE activities (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    capture_id INTEGER NOT NULL REFERENCES capture_runs(id) ON DELETE RESTRICT,
                    source_seq INTEGER,
                    execution_id INTEGER REFERENCES executions(id) ON DELETE RESTRICT,
                    project_id INTEGER REFERENCES projects(id) ON DELETE RESTRICT,
                    occurred_at_us INTEGER NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN (
                        'exec', 'fork', 'exit', 'open', 'create', 'write', 'rename',
                        'unlink', 'authorization', 'modeChange', 'gap')),
                    source_path TEXT,
                    target_path TEXT,
                    device INTEGER,
                    inode INTEGER,
                    configuration_revision INTEGER NOT NULL
                        REFERENCES configuration_versions(revision) ON DELETE RESTRICT,
                    mode TEXT NOT NULL CHECK(mode IN ('recordOnly', 'dryRun', 'protect')),
                    evidence TEXT NOT NULL CHECK(evidence IN ('observed', 'snapshot', 'inferred', 'responsible')),
                    evaluation TEXT NOT NULL CHECK(evaluation IN ('notEvaluated', 'allow', 'deny')),
                    response TEXT NOT NULL CHECK(response IN ('notApplicable', 'allow', 'deny', 'failed')),
                    detail TEXT,
                    UNIQUE(capture_id, source_seq),
                    -- Record Only never evaluates AUTH and never records a system denial.
                    -- Dry Run may record a would-block decision but always records Allow.
                    CHECK(
                        (mode = 'recordOnly' AND evaluation = 'notEvaluated' AND response = 'notApplicable')
                        OR (mode = 'dryRun' AND response IN ('allow', 'notApplicable', 'failed'))
                        OR (mode = 'protect' AND response IN ('notApplicable', 'allow', 'deny', 'failed'))),
                    -- AUTH events carry a real response; NOTIFY-style events carry none.
                    CHECK(
                        (kind = 'authorization' AND response <> 'notApplicable')
                        OR (kind <> 'authorization' AND response = 'notApplicable')),
                    -- Only AUTH is evaluated, and only while Dry Run or Protect is subscribed.
                    CHECK(
                        (kind = 'authorization'
                            AND mode IN ('dryRun', 'protect')
                            AND evaluation IN ('allow', 'deny'))
                        OR (kind <> 'authorization' AND evaluation = 'notEvaluated')),
                    -- A permitted operation can never be recorded as a system denial.
                    CHECK(evaluation <> 'allow' OR response <> 'deny')
                );

                CREATE TABLE activity_sessions (
                    activity_id INTEGER NOT NULL REFERENCES activities(id) ON DELETE CASCADE,
                    session_id TEXT NOT NULL REFERENCES agent_sessions(id) ON DELETE RESTRICT,
                    evidence TEXT NOT NULL CHECK(evidence IN ('observed', 'snapshot', 'inferred', 'responsible')),
                    PRIMARY KEY(activity_id, session_id)
                );

                CREATE TABLE rule_matches (
                    activity_id INTEGER NOT NULL REFERENCES activities(id) ON DELETE CASCADE,
                    rule_key TEXT NOT NULL,
                    PRIMARY KEY(activity_id, rule_key)
                );

                CREATE TABLE listener_intervals (
                    id INTEGER PRIMARY KEY,
                    execution_id INTEGER NOT NULL REFERENCES executions(id) ON DELETE RESTRICT,
                    transport TEXT NOT NULL CHECK(transport IN ('tcp', 'udp')),
                    address TEXT NOT NULL,
                    address_family INTEGER NOT NULL,
                    scope_id INTEGER NOT NULL,
                    port INTEGER NOT NULL CHECK(port BETWEEN 0 AND 65535),
                    first_observed_at_us INTEGER NOT NULL,
                    last_observed_at_us INTEGER NOT NULL,
                    ended_at_us INTEGER,
                    CHECK(first_observed_at_us <= last_observed_at_us)
                );

                CREATE TABLE capture_gaps (
                    id INTEGER PRIMARY KEY,
                    capture_id INTEGER NOT NULL REFERENCES capture_runs(id) ON DELETE RESTRICT,
                    occurred_at_us INTEGER NOT NULL,
                    reason TEXT NOT NULL,
                    missing_count INTEGER,
                    UNIQUE(capture_id, occurred_at_us, reason)
                );

                CREATE TABLE control_actions (
                    id TEXT PRIMARY KEY,
                    execution_id INTEGER NOT NULL REFERENCES executions(id) ON DELETE RESTRICT,
                    operation TEXT NOT NULL CHECK(operation IN ('stop', 'forceQuit')),
                    requested_at_us INTEGER NOT NULL,
                    signal_sent INTEGER NOT NULL CHECK(signal_sent IN (0, 1)),
                    exit_confirmed INTEGER NOT NULL CHECK(exit_confirmed IN (0, 1)),
                    error_code INTEGER
                );

                CREATE UNIQUE INDEX listener_intervals_active
                    ON listener_intervals(execution_id, transport, address_family, address, scope_id, port)
                    WHERE ended_at_us IS NULL;

                CREATE INDEX listener_intervals_port
                    ON listener_intervals(port, transport, last_observed_at_us DESC);
                CREATE INDEX listener_intervals_execution
                    ON listener_intervals(execution_id);
                CREATE INDEX listener_intervals_ended
                    ON listener_intervals(ended_at_us)
                    WHERE ended_at_us IS NOT NULL;

                CREATE INDEX capture_gaps_capture
                    ON capture_gaps(capture_id, occurred_at_us);

                CREATE INDEX control_actions_execution
                    ON control_actions(execution_id, requested_at_us DESC);

                CREATE INDEX activities_order
                    ON activities(id DESC);
                CREATE INDEX activities_retention
                    ON activities(occurred_at_us, id);
                CREATE INDEX activities_project
                    ON activities(project_id, id DESC);
                CREATE INDEX activities_execution
                    ON activities(execution_id, id DESC);
                CREATE INDEX activities_source_path
                    ON activities(source_path, id DESC);
                CREATE INDEX activities_target_path
                    ON activities(target_path, id DESC);

                CREATE INDEX activity_sessions_session
                    ON activity_sessions(session_id, activity_id DESC);
                CREATE INDEX rule_matches_rule
                    ON rule_matches(rule_key, activity_id DESC);

                CREATE INDEX execution_edges_child
                    ON execution_edges(child_execution_id, kind);
                CREATE INDEX execution_edges_parent
                    ON execution_edges(parent_execution_id, kind);
                CREATE INDEX execution_sessions_session
                    ON execution_sessions(session_id, execution_id);

                CREATE INDEX agent_sessions_root
                    ON agent_sessions(root_execution_id);
                CREATE INDEX agent_sessions_project
                    ON agent_sessions(project_id);
                CREATE INDEX agent_sessions_ended
                    ON agent_sessions(ended_at_us)
                    WHERE ended_at_us IS NOT NULL;

                CREATE INDEX executions_ended
                    ON executions(ended_at_us)
                    WHERE ended_at_us IS NOT NULL;
                """)

            // Seed the initial configuration from the code's built-in definitions so the two
            // cannot drift apart.
            let defaultAgents = try ConfigurationJSON.encodeAgents(AgentDefinition.defaults)

            try db.execute(
                sql: """
                    INSERT INTO store_metadata
                        (id, store_identifier, created_at_us, watermark, format_version)
                    VALUES (1, ?, ?, 0, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    MicroTime.value(Date()),
                    1,
                ])

            try db.execute(
                sql: """
                    INSERT INTO configuration_versions
                        (revision, mode, format_version, rules_json, agent_definitions_json,
                         retention_days, storage_budget_bytes, committed_at_us)
                    VALUES (1, 'recordOnly', 1, '[]', ?, 7, ?, ?)
                    """,
                arguments: [
                    defaultAgents,
                    512 * 1024 * 1024,
                    MicroTime.value(Date()),
                ])

            try db.execute(sql: "INSERT INTO preferences (id, current_revision) VALUES (1, 1)")
        }

        return migrator
    }
}
