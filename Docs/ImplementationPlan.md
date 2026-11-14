# Sidewatch Implementation Plan

## Product goal

Build a macOS AI agent activity manager using pure AppKit and MVVM. Connect agents, projects, executed commands, file activity, listening ports, and background services. Users can start from a port, command, or file, inspect its origin and history, and stop services left behind.

The first version groups activity by agent and project. Chat titles and task contents require metadata from the agent; do not infer them from system events. Show file operation history separately from text differences, and provide a diff only when a Git baseline exists.

## Verified project and platform conditions

- At planning time, the project contained only a SwiftUI App and Hello World view, with no business logic. The Sidewatch target, Xcode 27.2, and Swift 6.4.2 are available.
- Replace the template with NSApplicationDelegate, NSWindowController, NSSplitViewController, NSTableView, and other native AppKit components. Do not embed SwiftUI.
- Apple recommends implementing the Endpoint Security client as a system extension installed and upgraded by the host through SystemExtensions. Provide Record Only, Dry Run, and Protect modes; default to Record Only on first launch.
- `es_new_client` requires the `com.apple.developer.endpoint-security.client` entitlement and Full Disk Access. Signing, system extension approval, and privacy authorization are runtime prerequisites that the project cannot grant itself.
- ES `(pid, pidversion)` identifies an execution; exec increments pidversion. PID alone cannot link history. The SDK provides start_time, parent_audit_token, responsible_audit_token, and original_ppid.
- AUTH_OPEN requires `es_respond_flags_result`; use `es_respond_auth_result` for the other selected AUTH events. Respond before each event's deadline.

## Interface and interactions

Use a sidebar, content list, and detail inspector. Support light/dark appearance, resizing, and keyboard navigation. Ship an English UI with English as the development language and a String Catalog ready for additional translations.

| Page | Information and actions |
| --- | --- |
| Agents | Agent name, project, state, start/end times, descendants, and listening services; selection links to details and timeline |
| Timeline | exec, fork, exit, open, create, write, rename, and delete; distinguish completed activity, Would Block, and Blocked; filter by agent, project, and event type |
| Ports & Services | TCP listeners and UDP bindings, address, port, PID, full launch command, project, runtime, and attribution evidence; Stop and Force Quit |
| Leftover Services | Services still alive after their agent exits, reminders, and individual cleanup; distinguish shared or uncertain attribution |
| Protection Rules | Create, edit, enable, disable, and delete rules; choose file/directory, operations, and agent scope; show actual mode, enforcement state, simulated matches, and blocking records |

Global search supports port numbers, commands, project paths, and file paths. The inspector shows the agent → shell/tool → service launch chain and related file activity. Empty data, missing permissions, disconnected extensions, and query failures have truthful states and actionable controls.

Put all user-visible strings, including menus, buttons, empty states, errors, notifications, and accessibility labels, in `Localizable.xcstrings`, accessed through Foundation localization APIs. Use plural rules for counts and locale-aware formatters for dates and durations. Avoid concatenating English sentences. Persistence, XPC, and event types use stable, nonlocalized identifiers that are translated only for display. Ship English resources first; adding translations must not require changing business models.

## MVVM and project structure

- `Models`: process/execution identities, agent sessions, projects, activities, endpoints, attribution evidence, and protection rules; independent of AppKit.
- `Services`: attribution, GRDB + SQLite persistence, agent/project recognition, process/port queries, process control, system extension lifecycle, and XPC.
- `ViewModels`: filtering, selection, search, state projection, and commands; drive AppKit through explicit update interfaces.
- `Views`: window, sidebar, lists, inspector, rule editor, and permission guidance; no collection or attribution logic.
- `Shared`: Codable messages, XPC interfaces, and identity models shared by host and extension.
- A separate Endpoint Security system extension target embedded in the host, with the required Info.plist, entitlements, frameworks, and build dependencies.

Remove the SwiftUI template entry/view and adjust sandbox and lifecycle settings. Preserve the existing host bundle ID and development team; derive the extension bundle ID from the host.

## Files to modify

These paths define the implementation targets. New source files did not exist at plan approval.

| Path | Change |
| --- | --- |
| `Sidewatch.xcodeproj/project.xcproj` | Host configuration, system extension and core test targets; GRDB 7.12.0 SPM dependency, shared sources, linking, dependencies, embedding, and committed Package.resolved |
| `Sidewatch/SidewatchApp.swift` | Replace SwiftUI lifecycle with the AppKit entry point and delegate |
| `Sidewatch/ContentView.swift` | Remove the superseded template |
| `Sidewatch/Views/MainWindowController.swift` | Window, sidebar, toolbar, and three-column layout |
| `Sidewatch/Views/ActivityViewController.swift` | Native lists, filters, and linked selection for agents, timeline, ports, and leftovers |
| `Sidewatch/Views/InspectorViewController.swift` | Launch chain, commands, file activity, and Git diff |
| `Sidewatch/Views/RuleEditorViewController.swift` | Rule list, file/directory selection, scope, and editing |
| `Sidewatch/ViewModels/ActivityViewModel.swift`, `RuleViewModel.swift` | Projections, search/filtering, selection, operations, and error feedback |
| `Sidewatch/Services/ExtensionManager.swift`, `MonitorConnection.swift` | Extension activation, authorization state, XPC client, and disconnection handling |
| `Sidewatch/Services/ProcessSnapshotService.swift`, `ProcessControlService.swift`, `GitDiffService.swift` | Real snapshots without the extension, audit-token signals for the current user's processes, and read-only Git diffs |
| `Shared/Models/ActivityModels.swift`, `Shared/MonitorProtocol.swift` | AppKit-independent contracts, versioned transport, and XPC interface |
| `Shared/AttributionEngine.swift`, `AgentRecognizer.swift`, `ProjectResolver.swift`, `RuleMatcher.swift` | Independently testable attribution, recognition, and rule matching |
| `Shared/ProcessProbe.c`, `ProcessProbe.h` | Narrow C interface for libproc process/socket inspection and audit-token signals |
| `SidewatchMonitor/MonitorMain.swift`, `EndpointSecurityClient.swift`, `MonitorService.swift` | Extension entry, ES callbacks, and authenticated XPC service |
| `SidewatchMonitor/Storage/ActivityStore.swift`, `DatabaseMigrations.swift`, `DatabaseRecords.swift`, `HistoryQueries.swift`, `RetentionPolicy.swift` | GRDB DatabasePool, versioned migrations, private records, pagination, and retention |
| `Sidewatch/Sidewatch.entitlements`, `SidewatchMonitor/SidewatchMonitor.entitlements`, `SidewatchMonitor/Info.plist` | Host installation permission, ES entitlement, and Mach service declaration |
| `Sidewatch/Localizable.xcstrings` | English strings, plural variants, translator context, and localization infrastructure |
| `SidewatchTests/AttributionEngineTests.swift`, `RuleMatcherTests.swift`, `MonitoringModeTests.swift`, `ActivityStoreTests.swift`, `DatabaseMigrationTests.swift`, `HistoryRetentionTests.swift` | Attribution, enforcement, modes, transactions/migrations, and retained lineage regressions |
| `README.md`, `CHANGELOG.md` | Build, signing, authorization, usage, data locations, and actual verification limits |
| `Shared/Diagnostics.swift` | Unified Logging for program lifecycle, connection, storage, and internal failures; never log agent activity, commands, paths, tokens, or SQL arguments |

## Reuse

- Reuse the host target, bundle ID, development team, Debug/Release configurations, and synchronized folders in `Sidewatch.xcodeproj/project.xcproj`. Do not create a parallel project or introduce a project generator.
- Keep AppIcon and AccentColor in `Sidewatch/Assets.xcassets`; use AppKit system colors, SF Symbols, and standard controls.
- The original `SidewatchApp.swift` and `ContentView.swift` contain only lifecycle and Hello World templates, with no reusable business logic. Models, MVVM, and system collection require new implementations.
- Use system AppKit, EndpointSecurity, SystemExtensions, Foundation XPC, SQLite3, and libproc. Reuse [GRDB 7.12.0](https://github.com/groue/GRDB.swift/tree/v7.12.0) for connections, transactions, records, and migrations. Pin the release; do not build a SQLite C wrapper or maintain a parallel SwiftData store.

## Steps

- [x] Define shared identities, process edges, activities, ports, attribution evidence, rules, modes, simulated/actual decisions, and XPC contracts; distinguish snapshot from live-event evidence.
- [x] Integrate GRDB following the [database design](DatabaseDesign.md); implement attribution, agent/project recognition, and transactional persistence; verify identities, migrations, pagination, and live-service lineage after retention.
- [x] Implement the system extension, ES subscriptions/authorization callbacks, rule snapshots, user isolation, and XPC; configure modes, acknowledged transitions, installation, and embedding. Backend source is complete; full tests, product builds, and authorized runtime checks are deferred as recorded in BackendHandover.md.
- [x] Implement native process/socket inspection, runtimes, and audit-token signals; preserve query and permission errors.
- [ ] Switch the host to AppKit and connect ViewModels; implement five English pages, search/filtering, inspector, rules, modes, and permissions; localize every display string through the String Catalog.
- [ ] Connect leftover reminders, surviving descendants without ports, individual cleanup, and file history; identify shared and uncertain attribution.
- [ ] Run acceptance checks below, complete runtime/change documentation, and submit the actual code diff for Plannotator review.

## Current execution checkpoint

The current backend source checkpoint is complete, including the requested independent slow ES review and corrections. Native process/socket and audit-token signal scenarios were exercised. The user's latest instruction explicitly defers backend test execution and host/extension builds to the [handover](BackendHandover.md); no final integrated test/build or live ES interception pass is claimed. Stop before step 5. The existing [API reference](UIBuilderInterfaces.md) documents interfaces only. Commit the delivered source by module. The remaining UI, integration, and final acceptance scope stays pending, and this checkpoint does not complete the overall goal.

## Attribution invariants

1. Identify a process by boot identifier, PID, and start time; identify each execution additionally by pidversion. Preserve fork edges and exec transitions to prevent PID reuse and image replacement from corrupting attribution.
2. Recognize agents from executable identity, signing information, and structured arguments of known CLIs. Provide configurable definitions for Codex, Claude Code, and other common agents; never recognize an agent from an arbitrary command substring.
3. Inherit origins on fork and retain evidence on exec. Preserve recorded origins when the parent exits or launchd adopts descendants.
4. Processes already running at startup provide snapshot evidence, labeled as inferred; missing history means unknown origin. responsible token and original_ppid supplement recorded launch chains.
5. Identify projects from launch cwd and Git roots, recording directory/worktree changes separately. Do not force every accessed file into one project.
6. Preserve multiple attribution relationships. A service accessed by another agent was not necessarily launched by it. Show known sharing evidence without claiming to discover every consumer. Do not automatically clean up ambiguous services or those with active associations.
7. Record ES sequence gaps, capture boundaries, and reconnection intervals. Mark incomplete periods instead of fabricating events.

## Modes and Dry Run

Persist modes per user; they govern automatic protection rules. Manual Stop / Force Quit remains a separate explicit operation. All modes use real system data and require the applicable extension/ES permissions. Dry Run does not substitute mock data or bypass authorization.

| Mode | Activity collection | Rule evaluation and system response |
| --- | --- | --- |
| Record Only (initial default) | Process/file NOTIFY events, attribution, timeline, and leftover relationships | No AUTH subscriptions or blocking; notifications are not described as pre-operation enforcement |
| Dry Run | Real activity plus matching rules, target, time, and Would Block | Apply the same AUTH matching logic as Protect, but actually allow every request; evaluation errors must also allow |
| Protect | Real activity, decisions, and actual responses | Explicit user activation; deny only supported AUTH operations matching enabled rules, otherwise allow; record response failures separately |

The toolbar always shows the extension-confirmed actual mode. Switch modes on the rules page. Apply modes/rules as one versioned immutable snapshot; display them as active only after extension acknowledgment. Represent pending, disconnected, and unauthorized states explicitly. After switching to Record Only or Dry Run, newly processed authorizations must not deny under an old Protect snapshot. Completed operations are not undone.

Store evaluation (including Would Block), actual response (Allow / Deny / Response Failed), mode, and rule revision separately. Dry Run matches never count as actual blocks. Support separate timeline filters and record mode transitions and restoration of confirmed configuration after restart.

## Endpoint Security collection and protection

- Subscribe to fork, exec, exit, open, create, write/modified close, rename, and unlink notifications. Copy required scalar/string data before leaving the callback; never retain invalid message pointers.
- Maintain a small synchronous attribution index so authorizations immediately following fork/exec have the right origin.
- Use AUTH_OPEN, AUTH_UNLINK, and AUTH_RENAME for supported prevention. Handle directory removal through unlink; check both rename endpoints to cover moving out and replacing protected paths.
- Match exact files or directory boundaries; handle vnode identity, canonical paths, and symlinks. `/project-old` must not match `/project`.
- Authorization uses memory indexes and immutable rules only, with no UI, filesystem, network, or database waits. Disable response caching so configuration changes take effect, and respond within the deadline.
- Record Only has no AUTH subscriptions. Dry Run and Protect subscribe only to operations needed by enabled rules. Unavailable extensions mean inactive rules; describe uncovered operations accurately.
- Limit file collection to related agents; retain execution relationships needed for attribution. Do not save file contents, environment variables, or secret values; redact common credential arguments.
- The extension's GRDB DatabasePool batches sessions, edges, events, and configuration. The App queries through paginated XPC. AUTH never waits for persistence; write failures and queue overflow become collection gaps.

## Database construction

Use **GRDB 7.12.0 + system SQLite**. [DatabaseDesign.md](DatabaseDesign.md) specifies tables, fields, uniqueness, indexes, queries, migrations, and retention. SwiftData's ModelActor, indexes, and migration support work with AppKit; GRDB provides direct control over recursive launch-chain queries, multiple attribution relationships, batches, and reference-aware cleanup.

The extension manages a separate database per user UID, with one long-lived DatabasePool per file; the host never opens it directly. Separate process instances, exec versions, origin edges, agent sessions, activities, endpoint observations, and configuration history rather than overwriting a single owner field.

DatabaseMigrator manages ordered immutable migrations without erasing data on failure. Verify WAL and reopening using actual files. Retention preserves ancestry needed by live services, and Dry Run evaluations remain distinct from actual responses. Shared/storage work is not implicitly MainActor-isolated; AppKit and ViewModels explicitly use @MainActor.

## System extension and communication

- Install/upgrade with OSSystemExtensionRequest. Show approval pending, reboot required, missing entitlement, and missing Full Disk Access.
- A named XPC service supplies events/status and applies configuration. Before activation, both endpoints use `NSXPCConnection.setCodeSigningRequirement` to constrain bundle ID and team. Scope requests by effectiveUserIdentifier; prevent arbitrary processes from changing rules or reading other users' activity.
- Separate collection from AppKit lifecycle. Collection continues after the App exits; reconnection restores current status and history.
- Before extension authorization, show only real process/port snapshots readable by the current user, clearly marking historical collection and protection inactive.

## Port queries and service cleanup

- Use libproc process enumeration, PROC_PIDLISTFDS, and PROC_PIDFDSOCKETINFO to distinguish IPv4/IPv6, TCP LISTEN, and UDP bindings. Refresh off the main thread; handle process exits and permission failures.
- Link endpoints to process instances, not PIDs alone. Distinct addresses, protocols, and multiple holders of the same port remain distinct.
- Revalidate process identity, start time, and execution before stopping; refuse stale targets. Send SIGTERM only to the selected process, or explicit SIGKILL for Force Quit; never accidentally signal a process group.
- The SDK provides `proc_signal_with_audittoken`. Use it for processes with an ES token so the kernel validates execution identity. On stale identity or permission failure, report the error without falling back to PID signaling. Snapshot-only processes without a verifiable token remain inspectable, but stopping requires the extension connection. Do not implicitly elevate privileges.
- A leftover requires a known agent exit and a related process still alive, including processes without listening ports. Missing exit observations, disconnected collection, and unknown origins are not confirmed leftovers. Revalidate each cleanup target and report individual results.

## File history

Record path, operation, time, and initiating process; preserve old/new paths for renames. Reveal existing files in Finder, copy paths, and inspect activity from the same origin.

For Git projects, show the selected file's current workspace diff against HEAD, explaining that it may include other actors' edits. File events do not prove which agent changed an individual line. Do not offer restoration without a content baseline.

## Verification and evidence

- Build host and extension; inspect embedding, Info.plist, entitlements, and links.
- Verify parallel agents, fork/exec chains, surviving descendants after parent exit, PID reuse, startup snapshots, missing events, multiple origins, and cross-boot history.
- Verify directory boundaries, both rename endpoints, rule toggles, unrelated-process allowance, and correct AUTH_OPEN responses. The same match must allow + Would Block in Dry Run and deny only in Protect. Record Only must not authorize/block. Cover mode transitions, acknowledgment, restart restoration, and Dry Run evaluation errors allowing.
- Launch a real local listener, verify port/address/PID/start time, and prove that stopping it releases the port. Stop only processes created for verification.
- Run the actual AppKit App and inspect every English page, menu, search/filter, inspector, rule editor, mode, permission/error/empty state. Capture actual UI evidence and use pseudolocalization to inspect text expansion, plurals, date/duration formatting, and accessibility labels.
- Use controlled events to verify ingestion → persistence → ViewModel → display. Test data must not become product runtime data.
- Follow the database design to verify empty initialization, each migration, future-schema refusal, rollback, foreign keys, user isolation, page watermarks, WAL reopen/concurrency, retained origins after cleanup, and storage failure not blocking AUTH.
- Without Apple's ES entitlement, report compilation/offline checks separately and leave actual collection, blocking, and activation awaiting authorized runtime verification. Keep the overall goal incomplete; offline evidence is not successful on-device enforcement.
- Document build/signing/installation/authorization/data locations and actual checks; submit the implementation diff through Plannotator.
- Record operational diagnostics in macOS Unified Logging, separate from the activity database. Verify that diagnostic messages do not serialize commands, paths, rule matches, tokens, event payloads, or bound SQL arguments.
- After implementation and verification, run the requested independent slow-agent review, resolve its findings, then submit the code diff for human review.

## References

- [Endpoint Security: extension and authorization model](https://developer.apple.com/documentation/endpointsecurity)
- macOS SDK `EndpointSecurity/ESClient.h`: es_new_client requirements, responses, and lifecycle.
- macOS SDK `EndpointSecurity/ESMessageCore.h`: es_process_t, pidversion, and start-time semantics.
- macOS SDK `EndpointSecurity/ESMessage.h`: deadlines, seq_num, and global_seq_num.
- macOS SDK `sys/proc_info.h` and `libproc.h`: process/socket queries.
- [GRDB 7.12.0](https://github.com/groue/GRDB.swift/tree/v7.12.0): system SQLite, DatabasePool, async transactions, and DatabaseMigrator; linked primary documentation is in the database design.
- [SwiftData ModelContainer](https://developer.apple.com/documentation/swiftdata/modelcontainer) and [concurrency](https://developer.apple.com/documentation/swiftdata/concurrencysupport): persistence evaluation.
