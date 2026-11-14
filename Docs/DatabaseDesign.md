# Sidewatch Database Design

This document specifies the database portion of the [implementation plan](ImplementationPlan.md). It records design decisions and verified APIs; it is not evidence of a production database or completed runtime verification.

## Technology choice

Use **GRDB 7.12.0 + macOS system SQLite**. Pin the published version through Swift Package Manager and commit Package.resolved. Do not follow master or bundle a custom SQLite build.

The release requires Swift 6.1+, Xcode 16.3+, and macOS 10.15+; the project's toolchain meets these requirements. The system `sqlite3` command reports 3.54.0. Also inspect `sqlite3_libversion()` in the extension: the CLI version does not prove which library the extension links.

SwiftData supports ModelContainer, ModelActor, indexes, uniqueness, and SchemaMigrationPlan, and works with AppKit. Choose GRDB here to control origin graphs, joins, partial indexes, transactional batches, and reference-aware retention directly. Reuse its connections, migrations, records, and bound arguments; do not maintain a separate SQLite C wrapper, SwiftData/Core Data store, or host-side activity database.

## Ownership and location

- The ES extension exclusively manages activity databases. Partition by the authenticated user's UID at `/Library/Application Support/dev.shisheng.Sidewatch/Users/<uid>/activity.sqlite`. Clients cannot choose arbitrary database paths or UIDs.
- Use root-owned 0700 directories and 0600 data files. Protect WAL, SHM, and migration backups with the same directory permissions. Verify file types and ownership when creating/opening; reject symlink substitution.
- The App requests paginated DTOs over authenticated XPC. The extension selects the database from the connection UID rather than trusting a client filter. The host never opens the file directly.
- One database contains the user's activity, lineage, and protection configuration. UserDefaults may store window/display preferences. Without the extension, process snapshots are current observations and do not establish another history store.
- Keep data local, without CloudKit. Persist redacted arguments and path metadata, never environment variables, file contents, or secret values.

## GRDB integration and concurrency

- Keep one long-lived DatabasePool per open user database. It serializes writes; WAL permits concurrent paginated reads. Bound connections and do not open a pool per event/request/page.
- Configure foreign keys, a finite busy timeout, and `synchronous=FULL`; verify WAL activation. FULL prioritizes durability of committed transactions. Events not yet queued or committed are not guaranteed recoverable.
- Use async GRDB `read` / `write`. Database closures perform synchronous database work only; never retain connections, Rows, or cursors across await. Do not bypass transactions with unsafe/reentrant access.
- ES callbacks copy required data and maintain the memory attribution/decision index. **AUTH never waits for the database.** Use a bounded ingestion queue; commit at 256 records or 250 ms, subject to controlled-load verification.
- Persist process instances, executions, edges, associations, and the activity batch in one transaction. Insert referenced parents first; retain unknown evidence rather than inventing agents to satisfy foreign keys.
- Rules/modes form a small immutable configuration. Persist a new revision transactionally, switch the memory snapshot at the authorization serialization boundary, then acknowledge the active revision. Failed persistence must not appear as active Protect mode.
- Shared values, database records, and storage are not implicitly MainActor-isolated. AppKit and ViewModels explicitly use @MainActor. Keep GRDB records in the extension; transmit Codable, Sendable value DTOs over XPC.
- Queries cancel when appropriate. Notify clients after commit with a database watermark. Notifications are hints: reconnect by watermark rather than treating GRDB's process-local observation as cross-process delivery.

## Tables and relationships

Ordinary tables use `INTEGER PRIMARY KEY`. **activities.id uses `INTEGER PRIMARY KEY AUTOINCREMENT`**, so committed activity IDs are never reused. Retention/clear must not reset sqlite_sequence; migrations preserve its high-water mark. Persist a storeID on initial creation and include it in cursors. A different database instance invalidates old cursors. Store wall-clock timestamps as UTC integer microseconds and preserve ES sequence/capture boundaries separately. Structure important fields relationally rather than storing entire application state in JSON. Small versioned rule snapshots and redacted argv may use Codable JSON.

| Table | Key fields and constraints | Purpose |
| --- | --- | --- |
| `boot_epochs` | id, boot_identifier UNIQUE, started_at_us | Separate system boots using a system identifier that survives App restarts |
| `capture_runs` | id, boot_id FK, started_at_us, ended_at_us, last received/committed sequence | One ES client connection per capture; never deduplicate across sequence-reset boundaries |
| `capture_gaps` | id, capture_id FK, reason, time range, missing sequence/count | ES loss, queue overflow, persistence errors, or abnormal termination |
| `projects` | id, canonical_root UNIQUE, git_directory, display_name | Project/worktree identity; unknown roots remain NULL |
| `process_instances` | id, boot_id FK, pid, start_time_us, uid, last observed state and exit evidence; UNIQUE(boot_id,pid,start_time_us) | PID reuse creates a new instance |
| `executions` | id, process_id FK, pidversion, start/end, executable/signing identity, cwd, redacted argv; UNIQUE(process_id,pidversion) | Preserve each exec image and original command |
| `execution_edges` | parent_execution_id FK, child_execution_id FK, kind, evidence_kind, capture_id FK, observation time/sequence; unique parent/child/kind | Fork/exec transitions and supplementary responsible evidence; forbid self edges and PID-only reconstruction |
| `agent_sessions` | id, root_execution_id FK, recognizer_key, project_id FK NULL, start/end, end reason | Identified agent activity; distinguish observed exit from uncertainty after collection interruption |
| `execution_sessions` | execution_id FK, session_id FK, evidence, observation time; composite PK | Multiple agents may relate to one execution; no single owner column |
| `configuration_versions` | revision PK, mode, format_version, rules_json, committed time | Immutable rules/modes; editing or deleting a current rule preserves historical interpretation |
| `preferences` | Singleton PK, selected configuration FK, retention days, storage budget | User preferences; the extension reports the actual applied revision separately |
| `activities` | id, capture_id FK, source_seq NULL, execution_id/project_id FK NULL, time, kind, source/target path, available dev/inode, configuration FK, mode, evaluation, actual response; UNIQUE(capture_id,source_seq) | Notifications, authorizations, and local state events; local events without source_seq do not participate in ES deduplication |
| `activity_sessions` | activity_id FK, session_id FK, attribution evidence at event time; composite PK | Freeze event-time attribution instead of silently rewriting it after later inference |
| `rule_matches` | activity_id FK, rule_key; composite PK | Multiple matching rules per authorization; resolve content from the referenced configuration revision |
| `listener_intervals` | id, execution_id FK, transport, address family/address, IPv6 scope, port, first/last/end observation, state | Endpoint observation intervals, separately associated to each holder; polling does not prove exact bind time |
| `control_actions` | id, execution_id FK, requester, Stop/Force Quit, request/completion time, signal result, exit confirmation, system error | Cleanup audit; sending a signal is distinct from confirming exit |

For unknown parent executions, retain available token identifiers and missing evidence without inventing parent nodes. Establish verified edges only when full identity is observed. Define deletion rules explicitly: deleting an activity may cascade to its activity_sessions and rule_matches. Process instances, executions, edges, sessions, and configurations use RESTRICT so event cleanup cannot erase needed launch history.

Historical executions **never authorize process termination**. A stop requires a freshly verified live audit token from the current boot. Old database rows must not authorize signals to exited or reused PIDs.

## Modes and outcomes

- Stable storage values are recordOnly, dryRun, and protect, independent of UI language. Initial revision 1 is Record Only with no rules.
- Store evaluation (not evaluated / allow / should deny), actual response (not applicable / allow / deny / failed), and configuration revision separately.
- CHECK constraints prohibit actual Deny in Record Only or Dry Run. AUTH responses cannot be marked not applicable. Validate that each event's mode agrees with its configuration snapshot.
- Dry Run may record should deny + actually allow. Protect may record should deny + deny, or response failed. A match alone does not prove successful prevention.
- Retain rule/mode history. For a denied operation, record the authorization without fabricating a subsequent NOTIFY mutation.

## Indexes and query entry points

| Query | Index or strategy |
| --- | --- |
| Latest timeline / load more | activities(id DESC), using a commit watermark and ID cursor so clock adjustments do not reorder pages |
| Project/execution history | activities(project_id,id DESC), activities(execution_id,id DESC) |
| Agent history | activity_sessions(session_id,activity_id DESC), joined in batches without per-row queries |
| File lookup | activities(source_path,id DESC), activities(target_path,id DESC); merge both results by activity ID |
| Port lookup | listener_intervals(port,protocol,last_seen_us DESC), joined to executions, sessions, and edges |
| Launch chain/descendants | execution_edges(child_execution_id,kind) and (parent_execution_id,kind); recursive CTE over fork/exec edges with cycle detection; responsible evidence is not direct launch evidence |
| Related agent services | execution_sessions(session_id,execution_id), combined with live process state and endpoints; a service need not have a port |
| Rule history | rule_matches(rule_key,activity_id DESC), joined to immutable configuration for deleted rules |
| Retention | activities(occurred_at_us,id), completed-session/endpoint end times, and indexes on child FK columns |

A partial unique index constrains each unfinished endpoint interval by execution, transport, address family/address, scope, and port. Do not merge distinct holders, protocols, or IPv4/IPv6 endpoints. Persist new/changed/ended/coalesced observations, not a complete appended snapshot on every poll.

Exact ports use numeric indexes. Command/path substring searches use bound values with literal treatment of `%` and `_`. Query the retained range with cancellation and pagination rather than silently limiting history. Short arbitrary fragments may scan: verify with real data and EXPLAIN QUERY PLAN. Do not maintain an additional full-text copy in the first version.

XPC accepts typed filters, page size, and cursor, never arbitrary SQL. Bound per-page transfer size. The first page establishes a commit watermark; subsequent pages remain at that watermark while newer events are signaled separately, avoiding duplicates/omissions during scrolling. Stale query results do not prove a process is alive; revalidate before acting.

## Initialization and migrations

Run one DatabaseMigrator before starting writes. Published migration identifiers and ordering are immutable. Use GRDB's migration table rather than maintaining a second version authority in PRAGMA user_version.

Register one initial migration, `v1_initial`, containing all tables, constraints, indexes, storeID, activity AUTOINCREMENT, and the initial Record Only configuration. The complete current schema is the first shipped version; do not preserve artificial migration stages from development. Future released schema changes introduce new immutable migrations.

New databases apply v1_initial once; reopening v1 is idempotent. Future upgrades apply only new published migrations, with GRDB transactions and FK checking. Verify empty initialization, reopening, failed-initial-migration rollback, and refusal of future schemas. Failure preserves the database and reports Storage Unavailable instead of erasing data. Never enable eraseDatabaseOnSchemaChange, including development configurations that may encounter real history.

Before a migration rebuilds a large table, create one equally protected migration backup with GRDB's backup API, then remove it after verified success. Do not copy only a live .sqlite file and omit its WAL. Migrations/backups never run in authorization callbacks.

## Retention and capacity

- Initial policy: retain activity details for 7 days with a configurable 512 MiB storage budget. Count database, WAL, and associated history. This budget triggers cleanup; it is not a promise of immediate physical file shrinkage.
- Delete old activities, rule matches, event associations, and expired completed endpoint intervals in small transactions. Then remove sessions, executions, and configuration revisions no retained data references.
- **Preserve live background processes, their originating agent sessions, and necessary ancestry**, even if the agent exited before the retention cutoff. This does not retain expired file events forever.
- Display retained-lineage usage and the earliest available history. If necessary lineage exceeds budget, report it instead of deleting origins or silently stopping collection.
- Explain that clearing history preserves current live services and necessary origin state. It does not delete rules or modes.
- Keep read transactions short and bounded so browsing cannot pin WAL snapshots indefinitely. Coordinate checkpoints through the pool and reclaim free pages while idle. Do not VACUUM after every event batch or describe logical deletion as forensic erasure.

## Failure semantics and verification

Bound the queue. Busy/full/error/overflow conditions must not block AUTH. Preserve health information in memory, mark unpersisted ranges incomplete, and write gap records first when storage recovers. A crash may lose an uncommitted batch; recover unclosed captures as incomplete rather than claiming zero loss. Report storage availability separately from in-memory protection state.

Implementation acceptance:

- Distinguish PID reuse, exec version changes, system boots, and ES reconnect sequence resets.
- Retain surviving-service launch chains after agent exit; preserve multiple associations and immutable event-time attribution.
- Persist Dry Run Would Block/Allow separately from actual Protect responses; reject invalid mode/response combinations.
- Rollback leaves no partial launch chain or orphan event. Foreign keys prevent deleting referenced origins.
- Verify empty creation of the complete v1 schema, idempotent reopening, future-schema refusal, failed-initial-migration rollback, backup/restore, and foreign_key_check.
- Paginated reads remain complete during collection; reconnect by commit watermark; isolate users by UID.
- Clear history, insert a new event, then reconnect with the previous watermark: the new event must be delivered. Reject cursors with a different storeID and request a reset.
- Verify WAL, reopening, concurrent reads/writes, and checkpointing using real files. An in-memory database cannot prove these properties.
- After retention removes old activity, live-service origins remain queryable. Full disk/queue overflow produce accurate gap records without AUTH waiting for persistence.
- Run these checks against GRDB/SQLite actually linked in the extension. API/documentation checks and the system CLI alone do not establish an implemented or benchmarked store.

## References

- [GRDB 7.12.0 Package.swift](https://github.com/groue/GRDB.swift/blob/v7.12.0/Package.swift)
- [GRDB connections](https://github.com/groue/GRDB.swift/blob/v7.12.0/GRDB/Documentation.docc/DatabaseConnections.md)
- [GRDB concurrency and transactions](https://github.com/groue/GRDB.swift/blob/v7.12.0/GRDB/Documentation.docc/Concurrency.md)
- [GRDB migrations](https://github.com/groue/GRDB.swift/blob/v7.12.0/GRDB/Documentation.docc/Migrations.md)
- [SwiftData](https://developer.apple.com/documentation/swiftdata), [ModelContainer/migrations](https://developer.apple.com/documentation/swiftdata/modelcontainer), [ModelActor concurrency](https://developer.apple.com/documentation/swiftdata/concurrencysupport)
- [SQLite WAL](https://www.sqlite.org/wal.html) and [foreign keys](https://www.sqlite.org/foreignkeys.html)
