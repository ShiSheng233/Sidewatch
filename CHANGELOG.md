# Changelog

## Unreleased

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
