# Sidewatch API Reference

This document describes the existing host-module API. Swift types are internal to the app target, with shared DTO sources compiled into the host, monitor extension, and tests. The host communicates with the extension through `MonitorConnection`; it does not open the extension's databases.

## Source locations

| Surface | Source | Isolation |
| --- | --- | --- |
| System extension lifecycle | [ExtensionManager.swift](../Sidewatch/Services/ExtensionManager.swift) | `@MainActor` |
| Typed monitor/XPC client | [MonitorConnection.swift](../Sidewatch/Services/MonitorConnection.swift) | `@MainActor` |
| Native process/socket capture | [ProcessSnapshotService.swift](../Sidewatch/Services/ProcessSnapshotService.swift) | Actor |
| Manual process control | [ProcessControlService.swift](../Sidewatch/Services/ProcessControlService.swift) | `@MainActor`; signal work runs off the main actor |
| Read-only Git diff | [GitDiffService.swift](../Sidewatch/Services/GitDiffService.swift) | `Sendable`; work runs on a detached task |
| Shared DTOs and constants | [ActivityModels.swift](../Shared/Models/ActivityModels.swift) | `Codable`, `Sendable` values |
| Raw XPC protocols | [MonitorProtocol.swift](../Shared/MonitorProtocol.swift) | Foundation XPC callbacks |

## ExtensionManager

```swift
@MainActor final class ExtensionManager: NSObject {
    override init()
    var availability: MonitorAvailability
    var errorCode: String?
    var onChange: (() -> Void)?

    func activate()
    func openFullDiskAccess()
    func openExtensionSettings()
}
```

Initialization submits an OS properties request. It does not request installation or activation. `activate()` submits an actual `OSSystemExtensionRequest` and reports its asynchronous result through the properties and `onChange`.

`openFullDiskAccess()` and `openExtensionSettings()` open System Settings. Returning from either method does not establish that authorization was granted. There is currently no public properties-refresh method.

`availability == .active` here means the OS reports the extension enabled/activation complete. It does not establish that the ES client is authorized or collecting; that status comes from `MonitorSnapshot.health` or `MonitorConnection.onHealth`.

Common lifecycle `errorCode` values include `missingEntitlement`, `extensionNotFound`, `unsupportedLocation`, `codeSignature`, `validation`, `systemPolicy`, `authorizationRequired`, `extensionDisabled`, `canceled`, and `oserror`. These are stable diagnostic identifiers, not display text.

## MonitorConnection

```swift
@MainActor final class MonitorConnection {
    var onCommit: ((String, Int64) -> Void)?
    var onHealth: ((MonitorHealth) -> Void)?
    var onDisconnect: (() -> Void)?

    func connect() async throws
    func disconnect()
    func snapshot() async throws -> MonitorSnapshot
    func activities(_ query: ActivityQuery) async throws -> ActivityPage
    func configure(_ value: MonitorConfiguration) async throws -> MonitorConfiguration
    func liveToken(_ identity: ExecutionIdentity) async throws -> Data
    func recordControl(_ action: ControlAction) async throws
    func clearHistory() async throws
}
```

`connect()` creates a signed-peer-constrained privileged Mach connection and completes a protocol-version handshake. Concurrent calls share the in-progress connection attempt. It returns only after the handshake succeeds. `snapshot`, `activities`, `configure`, `liveToken`, `recordControl`, and `clearHistory` require that handshake; they do not connect implicitly.

`disconnect()` invalidates the connection and fails pending requests. A later `connect()` creates a new connection. There is no automatic reconnect loop. Cancellation and disconnection complete pending client requests with errors; an operation already delivered to the server may still finish there.

Every callback property has one closure slot. Callbacks run on the main actor. They carry invalidation/status information, not a streamed copy of every activity.

| Callback | Arguments | Meaning |
| --- | --- | --- |
| `onCommit` | `storeID: String`, `watermark: Int64` | The user's persisted data/graph changed. The watermark is an activity-ID high-water mark, not an event count. A notification can carry an unchanged watermark after metadata changes or cleanup. |
| `onHealth` | `MonitorHealth` | Actual monitor availability and acknowledged configuration state. |
| `onDisconnect` | None | The usable monitor connection was lost or explicitly disconnected. Previously displayed data is historical until refreshed. |

The server derives user scope from the authenticated connection's effective UID. No client method accepts another user's UID or arbitrary database path/SQL.

### snapshot()

Returns the current user's persisted graph/configuration plus current monitor observations. A first snapshot can initialize that user's store and default Record Only policy when the ES client is active.

| `MonitorSnapshot` field | Type | Meaning |
| --- | --- | --- |
| `graph` | `GraphSnapshot` | Executions, launch edges, Agent sessions, and many-to-many execution/session associations. |
| `endpoints` | `[ListeningEndpoint]` | Related endpoint observations; exact execution identity is included. |
| `liveExecutions` | `[ExecutionRecord]` | Current-user running executions with an observed ES identity and a current in-memory token. Includes eligible services outside Agent history; returned records contain no token bytes. |
| `configuration` | `MonitorConfiguration` | Persisted selected configuration. It can differ from the actively acknowledged configuration. |
| `health` | `MonitorHealth` | Actual monitor status and active mode/revision. |
| `storeID` | `String` | Persistent identity of this database, used to validate cursors. |
| `watermark` | `Int64` | Persisted activity-ID high-water mark. |
| `storageBytes` | `Int64` | Current SQLite/WAL/SHM storage size. |
| `oldestActivity` | `Date?` | Oldest retained activity timestamp, if any. |
| `captures` | `[CaptureRecord]` | Retained capture run identifiers, boot IDs, start times, and known end times. |
| `gaps` | `[CollectionGap]` | Recorded collection-integrity failures; an unknown missing count remains `nil`. |

Graph metadata is returned as a snapshot; activity history is paginated separately. Tokens are stripped from graph replies. A missing capture end time is not proof that collection was uninterrupted.

`liveExecutions` is transient current metadata, not an additional history stream. Its exact identities can correlate native process/port observations by the complete `ProcessIdentity`. The later token request and signal still revalidate the target; presence in this snapshot is not a permanent signal authorization.

### activities(_:)

```swift
struct ActivityQuery {
    var text: String = ""
    var sessionID: String?
    var projectRoot: String?
    var execution: ExecutionIdentity?
    var kind: ActivityKind?
    var outcome: String?
    var beforeID: Int64?
    var afterID: Int64?
    var watermark: Int64?
    var storeID: String?
    var limit: Int = 100
}

struct ActivityPage {
    var storeID: String
    var watermark: Int64
    var activities: [ActivityRecord]
    var nextBeforeID: Int64?
}
```

All supplied filters combine with AND. `text` is a case-insensitive literal substring search over paths, details, project roots, and commands. A numeric string in `0...65535` additionally matches an observed endpoint port for the activity's execution. `projectRoot` and `execution` are exact matches.

| Cursor form | Ordering | Continuation |
| --- | --- | --- |
| Neither `beforeID` nor `afterID` | Descending activity ID | `nextBeforeID` is the oldest returned ID. |
| `beforeID` | Descending IDs strictly below the cursor | Keep the returned `storeID` and `watermark`; use `nextBeforeID` for the next older page. |
| `afterID` | Ascending IDs strictly above the cursor | Despite its name, `nextBeforeID` is the last returned ID and is the next **afterID** continuation. |

`beforeID` and `afterID` are mutually exclusive. `beforeID` must be positive; `afterID` may be zero. The effective limit is clamped to `1...500`. A non-nil continuation is returned when the page fills the limit, so the next page can still be empty.

Omitting `watermark` fixes the page to the server's current high-water mark. Reusing the returned watermark keeps subsequent pages bounded to that history view. A later catch-up request can omit it to obtain a newer bound. A supplied watermark must be nonnegative and no greater than the current store watermark.

A cursor from another `storeID`, or an invalid watermark, produces `MonitorConnectionError.cursor`. Clearing history preserves the store identity and never resets the activity-ID sequence; the maximum ID is not the current row count.

Accepted `outcome` strings are case-insensitive:

| Value | Selection |
| --- | --- |
| `wouldblock` | `evaluation == .deny && response == .allow` |
| `blocked`, `denied`, `deny` | `response == .deny` |
| `allowed`, `allow` | `response == .allow` |
| `failed` | `response == .failed` |
| `notapplicable` | `response == .notApplicable` |

Other values return a query error. `nil` applies no outcome filter.

### configure(_:)

```swift
struct MonitorConfiguration {
    var revision: Int64 = 1
    var mode: MonitoringMode = .recordOnly
    var rules: [ProtectionRule] = []
    var agentDefinitions: [AgentDefinition] = AgentDefinition.defaults
    var retentionDays: Int = 7
    var storageBudgetBytes: Int64 = 512 * 1024 * 1024
}
```

This submits a complete configuration, not a patch. Failure codes include `configuration_conflict` (stale revision), `monitor_inactive`, `configuration_not_applied`, `invalid_configuration`, `rule_path_unavailable`, and `rule_target_mismatch`. The requested revision must be exactly the current persisted revision plus one. Revisions are immutable; a conflict requires reading the current configuration. The server prepares canonical rule paths and file identities and returns the prepared, acknowledged configuration.

A persisted configuration is selected intent. Only `health.activeMode` and `health.activeRevision` describe acknowledged runtime activation. A failed/disconnected request is not a successful activation, even if the selected configuration has already been persisted. A later snapshot resolves that distinction.

`MonitoringMode` raw values:

| Value | Semantics |
| --- | --- |
| `recordOnly` | Initial default; related NOTIFY collection, no rule evaluation for AUTH. |
| `dryRun` | Matching rules produce Would Block evaluation while the requested response allows. |
| `protect` | Supported matching AUTH operations can request denial. |

```swift
struct ProtectionRule {
    var id: String = UUID().uuidString
    var name: String
    var enabled: Bool = true
    var target: RuleTarget                  // file, directory
    var path: String
    var fileIdentity: FileIdentity?
    var operations: Set<ProtectedOperation> // open, delete, rename
    var agentIDs: Set<String> = []
}
```

An empty `agentIDs` set means all recognized Agents; unattributed processes do not match it. Paths are absolute filesystem paths, not glob expressions. A directory rule uses directory boundaries. Rename matching considers the source and destination. `fileIdentity` is server-prepared metadata, not an authorization token.

`AgentDefinition` contains `id`, `name`, exact executable names, supported script-path components, and optional `installDirectoryComponents`: trailing directory names that identify a versioned install, where the binary is named by version (Claude Code's native installer uses `claude/versions/<version>`). Current defaults are Codex, Claude Code, Gemini CLI, OpenCode, and omp. Recognition does not search arbitrary command substrings and never uses `argv[0]`.

Accepted configuration bounds: positive revision, retention of `1...3650` days, storage budget of at least `1 MiB`, at most `512` rules and `64` Agent definitions. IDs are unique within each collection. Rule IDs/names are nonempty, paths contain no NUL and are at most `4096` UTF-8 bytes, and operation sets are nonempty. Agent IDs/names are nonempty; each definition supplies executable names, script components, or install-directory components. Install-directory components are at most 8 single names without `/`, NUL, `.`, or `..`. Executable names are nonempty basenames without `/` or NUL; script components contain no NUL.

### clearHistory()

Returns `Void` after acknowledged cleanup. It clears historical detail while preserving current configuration and lineage needed by live/unknown services. It is not a process-control operation. Snapshot/graph and timeline contents can change without increasing the activity watermark.

### liveToken(_:) and recordControl(_:)

`liveToken` accepts the full `ExecutionIdentity` and returns exactly 32 bytes only after the extension validates a current ES observation and current effective-user ownership. A snapshot, persisted token, PID alone, or previous boot is not sufficient. The returned bytes must not be displayed, logged, persisted, or reused as a long-lived credential.

`recordControl` stores a `ControlAction` audit result. It does not send a signal. The higher-level manual-control API below performs both operations and keeps their failures separate.

## ProcessSnapshotService

```swift
actor ProcessSnapshotService {
    func snapshot() throws -> NativeProcessSnapshot
}

struct NativeProcessSnapshot {
    var capturedAt: Date
    var executions: [ExecutionRecord]
    var endpoints: [ListeningEndpoint]
    var issues: [ProcessQueryIssue]
    var socketInspectedProcesses: Set<ProcessIdentity>
}
```

Call with `try await probe.snapshot()`. The synchronous libproc capture runs on the actor executor. It requires no monitor connection and returns only data readable with the host's own privileges. It supplies current observations, not historical events or active protection.

Native executions have `.snapshot` evidence, execution version `0` (unknown ES pidversion), and `auditToken == nil`. Arguments are credential-redacted; environment values are not returned. Working directories and executables may be unavailable. Parent relationships are inferred from observed process instances, not recorded fork events.

`ProcessSnapshotError: CustomNSError` has domain `dev.shisheng.Sidewatch.ProcessSnapshot` and the real errno in `code: Int32`. It is thrown when the whole capture cannot enumerate processes. Partial failures remain in the returned `issues`:

```swift
struct ProcessQueryIssue {
    var pid: Int32
    var stage: ProcessQueryStage
    var code: Int32
}
// stages: enumeration, identity, executable, arguments, cwd, sockets, unknown
```

An empty result and a failed query are different outcomes. A missing socket can establish closure only for an exact process in `socketInspectedProcesses`; absence during an incomplete scan does not establish closure or process exit.

```swift
RuntimeDetector.runtime(forExecutable: String) -> RuntimeKind
// python, node, bun, deno, ruby, java, dotnet, unknown
```

Runtime detection uses the exact executable basename, with numeric Python version suffixes supported. It does not inspect arbitrary command substrings.

## ProcessControlService

```swift
@MainActor final class ProcessControlService {
    init(connection: MonitorConnection)
    func perform(_ request: ControlRequest) async -> ProcessControlResult
}

struct ControlRequest {
    var execution: ExecutionIdentity
    var operation: ControlOperation // stop, forceQuit
}

struct ProcessControlResult {
    var action: ControlAction
    var auditErrorCode: String?
}

struct ControlAction {
    var id: String = UUID().uuidString
    var execution: ExecutionIdentity
    var operation: ControlOperation
    var requestedAt: Date
    var signalSent: Bool
    var exitConfirmed: Bool
    var errorCode: Int32?
}
```

`stop` sends SIGTERM; `forceQuit` sends SIGKILL. Both target one exact process execution through `proc_signal_with_audittoken`, with boot, positive/nonself PID, start time, version, token size, and effective-UID checks. There is no PID-signal fallback or implicit privilege elevation. Snapshot-only processes require a verified live token from the extension before signaling.

`perform` returns a result rather than throwing. `action.signalSent` reports whether the signal call succeeded; `action.errorCode` is the signal/precheck/token errno on failure. The immediate result has `exitConfirmed == false`: it does not wait for an ES exit or prove that SIGTERM ended the process.

`auditErrorCode` reports failure to persist the audit independently. A successful signal can coexist with a non-nil audit error. Audit failure does not mean the signal was not sent.

Typical errno meanings include `EINVAL` for malformed/self/unsupported requests, `ESTALE` for an outdated boot/start/version, `ESRCH` for a gone execution, `EPERM`/`EACCES` for ownership/permission failure, and `ENOTCONN` for a missing usable monitor connection. Concrete errno values remain authoritative.

## Shared identity and graph values

| Type | Fields and semantics |
| --- | --- |
| `ProcessIdentity` | `bootID: String`, `pid: Int32`, `startTimeMicros: Int64`; `stableID` combines all three. Start time is Unix microseconds. |
| `ExecutionIdentity` | `process: ProcessIdentity`, `version: UInt32`; `stableID` also includes pidversion. Version `0` in native snapshots represents an unresolved ES execution identity. |
| `ExecutionRecord` | Identity, parent/responsible identities, parent PID, effective UID, executable, redacted arguments, optional cwd/signing/team metadata, dates, state, evidence, optional token field. Public graph/native replies strip tokens. `command` is display text derived from arguments, not a process-launch API. |
| `ExecutionState` | `running`, `exited`, `unknown`. Persisted live state is restored as unknown until supported by fresh observation. Missing observations do not establish an exit. |
| `EvidenceKind` | `observed`, `snapshot`, `inferred`, `responsible`; responsible identity is auxiliary evidence, not proof of a direct launch. |
| `ExecutionEdge` | `parent`, `child`, `kind` (`fork`, `exec`, `responsible`), `evidence`, `observedAt`. |
| `AgentSession` | `id`, `agent: AgentDefinition`, root execution, optional project, start/end dates, optional end reason, evidence. |
| `ExecutionAssociation` | Execution identity, session ID, evidence. Multiple sessions can be associated with one execution. |
| `ProjectRecord` | `root`, optional `gitDirectory`, derived `name`. A nil project is a valid unknown, not an empty default project. |
| `GraphSnapshot` | `executions`, `edges`, `sessions`, `associations`. No exclusive-owner field or precomputed leftover-service list is supplied. |

A startup snapshot can retain a canonical session root with version `0` after its real ES identity becomes known. The observed execution is associated with the same session; this does not create a second Agent session or an observed exec edge. A known exit closes the canonical startup session. A session root is therefore not necessarily the execution identity eligible for a fresh control token.

Observed exec activity provides an execution-start timestamp. Startup-only metadata can retain a process-creation baseline because the earlier exec was not observed. Resolving the exact ES identity does not manufacture that missing exec time.

`ListeningEndpoint` contains execution identity, `transport` (`tcp`/`udp`), address, address family, interface `scopeID`, port, first/last observation dates, and optional end date. Its `id` includes the full execution identity plus protocol/family/address/scope/port. Different holders of the same port remain distinct. TCP records are listeners; UDP records are bound sockets, not necessarily connected services.

## Activity and integrity values

`ActivityRecord` contains store-assigned `id`, `captureID`, optional ES `sourceSequence`, optional execution, timestamp, kind, source/target paths, optional file/project metadata, session IDs, evidence, configuration revision, mode, evaluation, response, matched rule IDs, and optional detail.

Activity kinds: `exec`, `fork`, `exit`, `open`, `create`, `write`, `rename`, `unlink`, `authorization`, `modeChange`, `gap`. Modified closes can be represented as write activity. Source sequence numbers are capture-scoped evidence; they are not database cursors.

Evaluation and actual response are separate:

| Field | Values |
| --- | --- |
| `RuleEvaluation` | `notEvaluated`, `allow`, `deny` |
| `SystemResponse` | `notApplicable`, `allow`, `deny`, `failed` |

A deny evaluation alone is not an actual block. A Dry Run match normally has deny evaluation plus allow response. Failed responses remain failures. File activity records contain operations and paths, not file contents or per-line authorship.

`CaptureRecord` has `id`, `bootID`, `startedAt`, and optional `endedAt`. `CollectionGap` has `captureID`, `occurredAt`, stable `reason`, and optional `missingCount`; nil means the count is unknown. Integrity information is independent of the number of returned activity rows.

## MonitorHealth and errors

```swift
struct MonitorHealth {
    var availability: MonitorAvailability
    var message: String?
    var storageError: String?
    var droppedEvents: UInt64 = 0
    var activeRevision: Int64?
    var activeMode: MonitoringMode?
    var sqliteVersion: String?
}
```

Availability raw values are `connecting`, `active`, `awaitingApproval`, `needsRestart`, `notInstalled`, `notEntitled`, `fullDiskAccessRequired`, and `unavailable`. `message` and `storageError` provide diagnostic state. Collection availability, storage health, and acknowledged mode are independent fields; selected configuration is not a substitute for them.

`MonitorConnectionError` cases:

| Case | Meaning |
| --- | --- |
| `notConnected` | No usable handshaken connection. |
| `serviceUnavailable(Int32)` | XPC/service failure, preserving its code. |
| `encoding`, `decoding`, `invalidReply` | Invalid request representation or malformed/incomplete reply. |
| `remote(String)` | Sanitized stable server error code. |
| `cursor` | Store identity or watermark no longer matches the query. |
| `protocolVersion` | Handshake version mismatch. |
| `invalidToken(Int32)`, `malformedToken` | Token refusal with real errno, or invalid token size. Token refusal is not always process exit; permission errno matters. |
| `cancelled` | Client request cancellation. |

The error exposes `errorCode: String` and localized `errorDescription`. Server codes are diagnostic identifiers, not raw SQLite error strings, paths, or rule payloads. Operational logging must not serialize Agent activity, commands, file paths, matches, tokens, event payloads, or SQL values.

## Wire contract

`MonitorWire.version == 1`. Current identifiers are host `dev.shisheng.Sidewatch`, extension/Mach service `dev.shisheng.Sidewatch.Monitor`, and signing team `YOURTEAMID`. Both endpoints constrain the peer's code-signing identity before accepting a usable connection.

The raw `MonitorRemote` methods are handshake, snapshot, activities, configure, liveToken, recordControl, and clearHistory. Codable DTOs are JSON-encoded `Data`; ordinary replies and health notifications use `WireEnvelope<Value>` with optional `value`, `error`, and `errorCode`. `liveToken` has the separate `(Data?, Int32 errno)` reply. A failure envelope may have no value. An empty/malformed response is not success.

`MonitorClient.databaseDidCommit(_:watermark:)` and `monitorHealthChanged(_:)` are adapted to the typed main-actor callbacks above. Database objects, SQL, and caller-selected user scopes are not part of the transport.

## GitDiffService

```swift
struct GitDiffService: Sendable {
    func diff(forFile path: String) async -> GitDiffResult
}
// GitDiffResult: diff(repository:text:truncated:), noChanges, noBaseline, notInRepository, gitUnavailable, failed(status:)
```

Compares one file's working copy with `HEAD` using `/usr/bin/git` with read-only options: no optional locks, no external diff or text conversion, literal pathspecs, a 10 s timeout, and a 1 MB output cap. A file absent from `HEAD`, or a repository without commits, has no baseline. A diff may include edits by other actors and never attributes lines to an agent. Restoration is not offered.

There is no file-restore, chat-title/task-content, or bulk-cleanup API in this surface. Leftover reminders are derived in the host from `MonitorSnapshot` (see `ActivityProjection`). The current APIs provide real history/graph values, current native observations, per-execution control, configuration, and health.
