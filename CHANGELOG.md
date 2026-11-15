# Changelog

## Unreleased

- Agent Disk: an observed agent exit now waits for the idle timeout (at most 24 hours) before files become eligible, so resuming a session keeps its scratch files. Files any running process still has open, and files no earlier scan saw unchanged, are never deleted.
- Agent Disk: added Settings → Agent Disk, which lists every session folder searched and lets you add folders the app can't discover (for example `CLAUDE_CONFIG_DIR` set only in a shell profile).
- Agent Disk: logs are parsed incrementally, the parse cache drops logs that disappeared, scans run on their own queue, and cancelling stops a scan mid-log.
- The monitor persists graph deltas instead of the whole in-memory graph on every batch, and copies the engine graph only when it changed. Removed a redundant activities index from `v1_initial`.
- The monitor no longer subscribes to NOTIFY_WRITE, mutes its own process and `/dev/` open/close noise, and skips unrelated file notifications without copying their paths.
- The host reads the monitor snapshot only when history changed (or every 30 seconds), throttles commit refreshes instead of debouncing them so the timeline updates during sustained activity, and ignores late catch-up replies for a replaced timeline.
- The inspector no longer rebuilds on every refresh, keeping the diff's scroll position and keyboard/VoiceOver focus; Git diff lines are tinted.
- Tables reload only changed rows on refresh; timeline filter menus are rebuilt only when their choices change and list the 100 most recent sessions.
- Closing the main window keeps Sidewatch running, and announced leftovers are remembered across launches.
- An older Sidewatch no longer replaces a newer installed monitor. The monitor caps concurrent requests per connection.
- Added plural variants for day/hour counts and dropped-event status.

- Added Agent Disk for agent session JSONL, account/profile discovery, artifact disk usage and provenance, manual eligible cleanup, and opt-in scheduled cleanup after an observed log-writer process exits or an inactivity timeout. Cleanup validates temporary-file ownership, creation evidence, project exclusions, and filesystem identity; uncertain artifacts and directories remain for review.
- Changing Agent Disk's idle timeout cancels an in-flight automatic cleanup and rescans, so a scan captured under a shorter timeout can't delete files after the timeout is extended.
- Added shared process/execution identities, Agent provenance, project recognition, configurable protection rules, and per-user GRDB history using one complete `v1_initial` schema.
- Added capture boundaries and collection gaps to history snapshots, preserving completeness information across database reopening.
- Added the Endpoint Security system extension, immutable per-user modes/rules, authenticated XPC, and host lifecycle services. Corrected provenance routing, startup identity reconciliation, deadline handling, response/subscription failure state, bounded indexes, and storage/memory retention synchronization.
- Added real libproc process, executable, working-directory, argument, TCP listener, and UDP binding queries with structured partial errors.
- Added IPv4/IPv6 endpoint identity, including recovery of Darwin's embedded IPv6 interface scope.
- Added exact audit-token SIGTERM/SIGKILL control with boot, start-time, execution-version, and effective-UID validation. Signal outcomes and audit-persistence failures remain separate.
- Verified native queries and signaling using isolated real listeners, stale identity/token rejection, empty-argument privacy boundaries, process exit, and successful port rebinding.
- Replaced the SwiftUI template with an AppKit host: sidebar, five pages, global search, timeline filters and paging, inspector with launch chain, related file activity and read-only Git diff, protection rule editor with acknowledged mode state, and Stop/Force Quit with confirmation.
- Added leftover-service detection (confirmed agent exit plus a process still observed alive), shared/uncertain attribution flags, Dock badge, and notifications.
- Added `Localizable.xcstrings` with English plural variants for every user-visible string.
- Fixed a crash when the monitor service was unreachable: XPC callbacks no longer inherit main-actor isolation.
- Fixed restored history reporting exited executions as unknown, EndpointSecurity linking, and the error code returned for unpreparable rule paths.

Live ES interception and protection require signed, authorized runtime verification; offline tests and native checks do not establish successful ES enforcement.
