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

Pure AppKit with MVVM (`Sidewatch/ViewModels`, `Sidewatch/Views`); no SwiftUI. The window has a sidebar (Agents, Timeline, Ports & Services, Leftover Services, Agent Disk, Protection Rules), a content list, and an inspector showing the launch chain, process details, related file activity, and a Git diff for the selected file. Search accepts port numbers, commands, project paths, and file paths. The toolbar shows only the mode the extension has acknowledged.

Without the extension, the app shows current processes and ports readable by your account, recognizes running agent CLIs from the process list (labeled Snapshot), and states that history and protection are inactive. Stop and Force Quit require the extension's live identity for the exact process. Leftover reminders use the Dock badge and, if permitted, a notification; a leftover is announced once, even across relaunches. Closing the window keeps Sidewatch running so reminders and scheduled cleanup continue; click the Dock icon to reopen it.

The inspector rebuilds only when something it shows changes, so the periodic refresh doesn't reset the Git diff's scroll position or move keyboard and VoiceOver focus. The host reads the monitor snapshot when a commit reports new history (throttled to one leading and one trailing refresh per 750 ms), and otherwise at most every 30 seconds.

All user-visible text is in `Sidewatch/Localizable.xcstrings` (English, with plural variants). Animations follow the system Reduce Motion setting.

Debug builds can render every page in light and dark appearance to PNG files using real data, then quit:

```sh
SIDEWATCH_UI_SNAPSHOT_DIR=/tmp/sidewatch-ui \
  /tmp/SidewatchDerivedData/Build/Products/Debug/Sidewatch.app/Contents/MacOS/Sidewatch
# Add -NSDoubleLocalizedStrings YES to check text expansion.
```

## Agent disk audit

**Agent Disk** reads Codex, Claude Code, omp, and pi session JSONL. Discovery includes native account homes, Codex archives, omp profiles, and the providers' configured session directories (`CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `XDG_DATA_HOME`, `PI_CODING_AGENT_DIR`, and `PI_CODING_AGENT_SESSION_DIR`). Pi's JSONC `sessionDir` and subagent `defaultSessionDir` settings are also honored. An app opened from the Dock doesn't see variables set only in a shell profile, so **Settings → Agent Disk** lists every folder that was searched and lets you add more, choosing the agent for each. A configuration folder maps to its session folders (for example `projects` for Claude Code). Add every folder an agent writes sessions to: files claimed by a session Sidewatch can't see don't wait for it. It correlates file-producing tool calls with successful results, measures surviving artifacts, and lists them in a tree under the session that wrote them, with each file's source log, tool, disk usage, and cleanup eligibility. This works without the system extension. Log text is never executed.

Candidates include paths touched by successful `Edit`/`edit`, writes, patches, and supported shell output operations in `/tmp`, `/var/tmp`, or the user's temporary directory (normally under `/var/folders`). Editing a file makes it visible in the audit; deletion additionally requires evidence that the agent created it. A file first created and later edited can retain its creation evidence. Ordinary reads and path mentions do not establish ownership.

Supported shell outputs include literal `>`/`>>` redirections, heredoc header redirections, `cp`/`mv`/`tee`, compiler `-o`, and Xcode build output directories. Random `mktemp` paths are resolved from a successful paired output matching the invocation's template. Shell code, heredoc bodies, variable substitutions, and embedded programs are never executed to reconstruct their effects; unsupported dynamic paths are reported as incomplete coverage. Patches include added and updated files, and omp hashline edit headers are recognized.

Scanning is read-only. **Clean Eligible** asks for confirmation with the count and size of the eligible files currently listed (search included), then rescans and deletes only those paths, and only if they haven't changed. A confirmation made while another scan is running waits for that scan instead of being dropped. Automatic cleanup is off by default; enable it on the audit page and choose a session inactivity timeout (72 hours initially). It checks once a minute while Sidewatch is running. These JSONL formats do not record session exit: Sidewatch can confirm an exit only for a process it previously observed writing that session log, using both PID and process start time. After a confirmed exit the files still wait for the idle timeout (at most 24 hours) in case the session is resumed; new records in the log after the exit start a new lease. A still-live observed writer renews the lease; old or unobserved sessions use inactivity expiry. Completing a turn does not end a session. A shared artifact waits for every claiming session, and a file that any of your running processes still has open waits until it is closed.

Automatic eligibility is restricted to current-user temporary files with corroborating creation times, no later changes, and a quiet period. Project files, symlinks, hardlinks, and directories remain for review. Directory sizes are measured without following symlinks. A file is deleted only after an earlier scan saw it with the same identity (device, inode, size, and timestamps), so a file seen for the first time is never deleted by the same pass. Missing files disappear from the audit; unreadable or malformed evidence is reported. Compressed Codex logs are reported as unsupported. Files created outside a session log are not discovered by this scan. The format handling follows the provider parsers and trace pairing in [magpie](https://github.com/yetone/magpie/tree/main/internal/sessions).

Cleanup permanently unlinks eligible files. Session logs and project files are retained. Changing the idle timeout or the session folders cancels a running automatic cleanup and rescans. Quitting Sidewatch stops scheduled cleanup; reopening it resumes the saved policy. Erase All Data resets the policy to automatic cleanup off and forgets added session folders.

Logs are parsed incrementally: a log that only grew resumes from the end of its last complete record, after confirming the bytes before that point are unchanged; a rewritten log is parsed again from the start. Scans run on their own queue and stop at the next 64 KB chunk when cancelled.

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

## Release

Release builds use manual signing: Developer ID Application with the Developer ID profiles "Sidewatch Main" (app, `system-extension.install`) and "Sidewatch Monitor" (extension, `endpoint-security.client`). Xcode's automatic signing cannot create Developer ID profiles for the Endpoint Security entitlement, so these profiles are created in the developer portal. Debug builds keep automatic Apple Development signing.

Store notarization credentials once, then build a notarized, stapled DMG in `build/release`:

```sh
xcrun notarytool store-credentials sidewatch-notary --apple-id <apple-id> --team-id <team-id>
Scripts/release.sh            # Scripts/release.sh --help lists the options
```

The script reads your team ID from `Config/Local.xcconfig` (or `TEAM_ID`), refuses to build from uncommitted changes, checks that the app and extension carry the version from `Config/Version.xcconfig`, and prints the DMG's SHA-256.

When archiving in Xcode instead, distribute with Custom → Developer ID and choose manual signing with the profiles above; Direct Distribution requests automatic signing and fails. Users must move Sidewatch to `/Applications` before macOS will activate the system extension.

## Configuration

Build settings shared by every target live in `Config/`:

- `Version.xcconfig` holds the version (`MARKETING_VERSION`) and build number (`CURRENT_PROJECT_VERSION`) for both the app and the extension.
- `Signing.xcconfig` includes `Local.xcconfig`, which is ignored by Git and holds your Apple Developer team ID:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then set DEVELOPMENT_TEAM
```

