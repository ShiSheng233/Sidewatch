# Backend Handover

This checkpoint covers backend source, native process/port services, and the existing API surface. The host entry point and view remain the original template. The API reference is [UIBuilderInterfaces.md](UIBuilderInterfaces.md); it contains signatures and contracts rather than a UI implementation plan.

## Verification boundary

The user explicitly deferred **backend test execution and host/system-extension builds** for this handover. Those commands have not been run against the final integrated backend. Added regression tests are source additions, not passing-test evidence.

Checks already observed before that instruction:

| Check | Observed result |
| --- | --- |
| Xcode project loading | `xcodebuild -list -json` recognized Sidewatch, SidewatchMonitor, and SidewatchTests. |
| Native C probe | Compiled with `-std=gnu17 -Wall -Wextra -Werror`. |
| Native services | Compiled as an isolated Swift 6 executable using the real C probe. |
| Real listener/control smoke | IPv4/IPv6 TCP listeners and UDP bindings matched identity, address, protocol, and port. SIGTERM, SIGKILL, and empty-argv scenarios each released all four ports for successful rebinding. Stale boot/start/version and malformed tokens were rejected. |
| Argument privacy | A real child with empty `argv[0]` and a controlled environment marker did not emit the environment value as an argument. Credential arguments were redacted. |
| IPv6 scope | A real link-local UDP socket matched `getsockname`: canonical `fe80::1` and interface scope `1`. |
| Shared/ES source type checking | Standalone Swift 6 type checking completed. This is not a project build or live ES test. |
| Extension lifecycle source | Standalone type checking of ExtensionManager against the installed SDK completed. |

The native signal proof used only helper processes created for verification. It exercised the common audit-token signal path, not an installed-extension-to-host end-to-end flow.

## Source modules

| Module | Main paths |
| --- | --- |
| Identities, attribution, recognition, rules | `Shared/Models`, `AttributionEngine.swift`, `AgentRecognizer.swift`, `ProjectResolver.swift`, `RuleMatcher.swift`, `SystemIdentity.swift` |
| GRDB history and retention | `SidewatchMonitor/Storage`, `UserStoreRegistry.swift`, `ActivityIngestion.swift` |
| Native process/socket inspection and signals | `Shared/ProcessProbe.c`, `ProcessProbe.h`, `SidewatchBridge.h`, `Sidewatch/Services/ProcessSnapshotService.swift`, `ProcessControlService.swift` |
| ES client and immutable policy | `SidewatchMonitor/EndpointSecurityClient.swift`, `ESMessageDecoding.swift`, `ESPolicy.swift` |
| XPC and extension lifecycle | `Shared/MonitorProtocol.swift`, `SidewatchMonitor/MonitorService.swift`, `MonitorMain.swift`, `Sidewatch/Services/MonitorConnection.swift`, `ExtensionManager.swift` |
| Diagnostics | `Shared/Diagnostics.swift`; operational text/counts/codes only |
| Project wiring | `Sidewatch.xcodeproj/project.xcproj`, shared test scheme, pinned Package.resolved, host/extension entitlements, extension Info.plist |

Databases use the single complete `v1_initial` migration and remain extension-owned under `/Library/Application Support/dev.shisheng.Sidewatch/Users/<uid>/activity.sqlite`. The host reads through authenticated XPC. Activity IDs and cursor watermarks are not row counts and are not reset by clearing history.

## Review and regression scope

The independent reviewer used the configured **slow** model role. Its eight findings concern:

1. Default UID dispatch incorrectly propagating as Agent ownership.
2. Startup native version-0 attribution failing to join the first live ES execution.
3. AUTH waiting on graph work beyond its response deadline.
4. Invalid UTF-8 being repaired into a different authorization path.
5. Unmatched AUTH response failures disappearing.
6. Failed AUTH subscription removal being acknowledged active.
7. PID/version mappings growing across exec churn.
8. Full in-memory graphs recreating history after clear/retention.

The source corrections address provenance routing, startup reconciliation, bounded AUTH acquisition/evaluation, strict path decoding, truthful failure gaps, subscription acknowledgment, index retirement, and synchronized storage/memory cleanup. Unconfirmed policy transitions expose no active mode/revision and remain fail-open; only the installed, acknowledged policy can participate in authorization.

A startup snapshot can remain the canonical session root with unresolved version 0, while the fresh ES execution is associated with the same session. Fresh tokens come only from the ES message. Observed exit/image replacement closes or retires the corresponding startup root; no missing exec event is invented. Observed exec timestamps are distinguished from startup process-creation baselines.

`MonitorSnapshot.liveExecutions` supplies token-stripped, current-user ES identities for eligible services outside the Agent history graph. Native version-0 process rows alone do not establish a signal authority.

Regression sources include policy/truncation/arbitration, inactive activation, routing, startup promotion and reopening, identity/index bounds, retention/ingestion maintenance, capture completeness, and a real link-local IPv6 socket. They still require the deferred test run below.

## Deferred backend test command

Run from the repository root. The result-bundle directory must not already exist.

```sh
sidewatch_check_dir="$(mktemp -d /tmp/SidewatchChecks.XXXXXX)"
xcodebuild test -project Sidewatch.xcodeproj -scheme SidewatchTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/SidewatchDerivedData \
  -clonedSourcePackagesDirPath /tmp/SidewatchPackages \
  -resultBundlePath "$sidewatch_check_dir/BackendTests.xcresult" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

No current full-suite pass is claimed. The suite must establish that the final ES, storage, native, and transport sources compile and that their regressions pass together.

## Deferred host and extension build

The Sidewatch scheme depends on SidewatchMonitor and embeds its product; this command covers both products without signing:

```sh
xcodebuild build -project Sidewatch.xcodeproj -scheme Sidewatch \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/SidewatchDerivedData \
  -clonedSourcePackagesDirPath /tmp/SidewatchPackages \
  CODE_SIGNING_ALLOWED=NO
```

Expected product locations, to inspect after a successful build:

```text
/tmp/SidewatchDerivedData/Build/Products/Debug/Sidewatch.app
/tmp/SidewatchDerivedData/Build/Products/Debug/Sidewatch.app/Contents/Library/SystemExtensions/dev.shisheng.Sidewatch.Monitor.systemextension
```

Verify the embedded bundle, executable and plist, its Endpoint Security Mach service name, the host installation entitlement, extension ES entitlement, framework/library links, and matching bundle/team identifiers. An unsigned build cannot establish a valid signed installation or entitlement approval.

The monitor source includes `--diagnose`, which attempts the real ES client startup and prints structured health, then stops. Running that diagnostic after building does not install the system extension or prove successful interception. It has not been run on the final monitor product in this checkpoint.

## Deferred authorized-runtime checks

These remain unverified:

- Signed host/extension installation, OS approval, Full Disk Access, and actual `es_new_client` activation with Apple's ES entitlement.
- Real NOTIFY ingestion through persistence and XPC, including startup agents and fork/exec/exit relationships.
- Real AUTH_OPEN flags, rename source/destination and unlink matching, cache-disabled responses, deadline behavior under graph/config load, and response failures.
- Record Only/Dry Run/Protect transitions and acknowledgment, including subscription removal failures and no stale Protect denial after a confirmed downgrade.
- Multi-user provenance confinement, privilege changes, fresh-token refusal on stale execution/ownership, and the installed XPC-to-signal-to-audit path.
- Clear/retention concurrent with live callbacks, preservation of new work and live ancestry, and absence of resurrected completed history after reconnect/restart.
- Runtime Unified Logging output; source diagnostics are limited to operational information and must never include activity payloads, paths, commands, matches, tokens, or SQL arguments.

ES messages do not provide argv for every process metadata observation. A node/bun script Agent first seen through file activity can remain unidentified until native polling or restored metadata supplies its arguments. Chat titles/task contents and file contents are not provided by this backend API.

The app currently has no automatic activation/connection call wired into its template lifecycle. ExtensionManager and MonitorConnection are implemented services; launching the template alone does not exercise them.

The backend review baseline before module commits is `fda707b3a78f8af7945ce7a8c90ea2cabc16dd0d`.
