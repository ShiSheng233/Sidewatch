# Sidewatch

A macOS project for connecting AI agent activity to projects, commands, file operations, background processes, and listening ports.

Current checkpoint: AppKit host and backend implemented; `SidewatchTests` passes and the host builds with the extension embedded. Live Endpoint Security collection and protection still need a signed, entitled installation; see [BackendHandover.md](Docs/BackendHandover.md).

## Architecture

The design uses an AppKit host with MVVM. An Endpoint Security system extension maintains process provenance and collects related activity. The extension owns per-user GRDB/SQLite databases; the host requests typed results over authenticated XPC. Process inspection and port queries use libproc.

Process identity includes the boot identifier, PID, and start time. Execution identity also includes pidversion. Recorded origins survive parent exit and reparenting. Snapshot-derived relationships remain explicitly inferred.

## Requirements

- Xcode 27.2 and the macOS 27 SDK.
- GRDB 7.12.0, pinned in the project's Package.resolved.
- For live Endpoint Security collection: an Apple-approved `com.apple.developer.endpoint-security.client` entitlement, matching signing/provisioning, system extension approval, and Full Disk Access.

An unsigned build can inspect data accessible to the current user. It cannot establish live ES collection or enforce protection rules without the required system authorization.

## Protection modes

- **Record Only**: real process/file notifications, no AUTH subscriptions or blocking. Initial default.
- **Dry Run**: evaluate enabled protection rules, record Would Block, and actually allow operations.
- **Protect**: deny supported operations matching enabled rules. The interface shows only the mode acknowledged by the extension.

Manual process controls are separate explicit actions. A stop requires a current audit token and sends a signal only to that execution; it never falls back to an unchecked PID.

## Data

The extension stores each user's history under:

```text
/Library/Application Support/dev.shisheng.Sidewatch/Users/<uid>/activity.sqlite
```

Directories are root-owned and private. The host does not open these databases directly. The initial complete schema is `v1_initial`. Activity IDs use AUTOINCREMENT; clearing history never resets their sequence. Cursors also carry a database storeID.

Operational diagnostics use macOS Unified Logging with subsystem `dev.shisheng.Sidewatch`. Agent commands, file paths, rule matches, audit tokens, event payloads, SQL arguments, and file contents must not be written to these logs. Activity history belongs in the database.

## Interface

Pure AppKit with MVVM (`Sidewatch/ViewModels`, `Sidewatch/Views`); no SwiftUI. The window has a sidebar (Agents, Timeline, Ports & Services, Leftover Services, Protection Rules), a content list, and an inspector showing the launch chain, process details, related file activity, and a Git diff for the selected file. Search accepts port numbers, commands, project paths, and file paths. The toolbar shows only the mode the extension has acknowledged.

Without the extension, the app shows current processes and ports readable by your account, recognizes running agent CLIs from the process list (labeled Snapshot), and states that history and protection are inactive. Stop and Force Quit require the extension's live identity for the exact process. Leftover reminders use the Dock badge and, if permitted, a notification.

All user-visible text is in `Sidewatch/Localizable.xcstrings` (English, with plural variants). Animations follow the system Reduce Motion setting.

Debug builds can render every page in light and dark appearance to PNG files using real data, then quit:

```sh
SIDEWATCH_UI_SNAPSHOT_DIR=/tmp/sidewatch-ui \
  /tmp/SidewatchDerivedData/Build/Products/Debug/Sidewatch.app/Contents/MacOS/Sidewatch
# Add -NSDoubleLocalizedStrings YES to check text expansion.
```

## Design and verification

- [Implementation plan](Docs/ImplementationPlan.md)
- [Database design](Docs/DatabaseDesign.md)
- [API reference](Docs/UIBuilderInterfaces.md)
- [Backend handover and deferred verification](Docs/BackendHandover.md)

The project has a standalone `SidewatchTests` scheme for provenance, protection modes, rule matching, and database regression checks. Runtime validation of ES interception requires the entitlement and approvals above; compilation and offline tests do not prove successful system enforcement.

## Build

```sh
xcodebuild build -project Sidewatch.xcodeproj -scheme Sidewatch \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/SidewatchDerivedData \
  -clonedSourcePackagesDirPath /tmp/SidewatchPackages CODE_SIGNING_ALLOWED=NO
```

## Backend verification checkpoint

Native process/socket services were compiled with Swift 6 and C `-Wall -Wextra -Werror`. Real isolated helper processes verified IPv4/IPv6 TCP listeners and UDP bindings, process start identity, credential-argument redaction, and rejection of stale start times, exec versions, previous-boot identities, and malformed tokens. Both SIGTERM and SIGKILL used the audit-token signal path; all four ports became bindable after each helper exited. An empty `argv[0]` case verified that environment values were not emitted as arguments.

A separate real IPv6 link-local UDP binding verified the canonical address and interface scope. Darwin's socket-info export embeds the zone in the address even though its `in6_ifindex` field is zero; the probe recovers the scope in the same way as the kernel's [socket address conversion](https://github.com/apple/darwin-xnu/blob/master/bsd/netinet6/in6_pcb.c).

These checks exercise native collection and signaling. Live ES interception, system extension activation, and the host interface still require their own runtime verification.

Run the standalone backend suite with:

```sh
xcodebuild test -project Sidewatch.xcodeproj -scheme SidewatchTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/SidewatchDerivedData \
  -clonedSourcePackagesDirPath /tmp/SidewatchPackages \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```
