import Darwin
import Foundation

/// Audits temporary artifacts claimed by agent session logs.
///
/// Discovery is read-only. Deletion happens only when `cleanup` is true, the target
/// is still eligible after a second scan, and every identity check passes. Logs are
/// never executed and their prose is never interpreted as a path.
actor AgentDiskAuditService {
    private struct TemporaryRoot: Equatable {
        var lexicalPath: String
        var realPath: String
    }

    private struct ProjectPath: Equatable {
        var lexicalPath: String
        var realPath: String
    }

    private struct InodeKey: Hashable {
        var device: UInt64
        var inode: UInt64
    }

    private struct FileIdentity: Equatable {
        var device: UInt64
        var inode: UInt64
        var size: Int64
        var blocks: Int64
        var mode: mode_t
        var uid: uid_t
        var nlink: UInt64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        var changedSeconds: Int64
        var changedNanoseconds: Int64
        var birth: Date
        var isDirectory: Bool

        var key: InodeKey { InodeKey(device: device, inode: inode) }
    }

    private struct Snapshot {
        var path: String
        var realPath: String
        var root: TemporaryRoot
        var identity: FileIdentity
    }

    private struct ClaimEntry {
        var claim: AgentArtifactClaim
        var sessionIndex: Int
    }

    private struct GroupBuilder {
        var realPath: String
        var root: TemporaryRoot
        var displayPaths: Set<String> = []
        var claims: [ClaimEntry] = []
        var claimKeys: Set<String> = []
        var sessionIndices: Set<Int> = []
        var toolNames: Set<String> = []
        var sessionIDs: Set<String> = []
        var agents: Set<String> = []
        var logPaths: Set<String> = []
        var firstClaim: Date = .distantFuture
        var lastActivity: Date = .distantPast
        var lastClaim: Date = .distantPast
    }

    private enum Inspection {
        case ignored
        case missing
        case reviewed(reason: String, identity: FileIdentity?, issue: String?)
        case file(FileIdentity)
    }

    private struct Evaluated {
        var path: String
        var group: GroupBuilder
        var inspection: Inspection
        var depth: Int
        var bytes: Int64 = 0
    }

    private struct ScanOutcome {
        var report = AgentDiskReport()
        var snapshots: [String: Snapshot] = [:]
        var providersByLog: [String: AgentLogProvider] = [:]
        var incompleteLogs: Set<String> = []
        var projects: [ProjectPath] = []
        /// Discovered session roots and logs. Anything at or below them is
        /// provider-owned evidence and is never eligible, even under a temporary root.
        var sessionPaths: [ProjectPath] = []
    }

    /// Writer liveness observed once per cleanup pass, with the log stat each
    /// observation was made against. A log that changes afterwards is observed again
    /// before its artifact is unlinked.
    private struct PassObservation {
        var sessions: [String: AgentArtifactSession] = [:]
        var stats: [String: AgentLogFileStat] = [:]
    }

    private enum Revalidation {
        case keepEligible
        case waiting(String, Date?)
        case review(String, String)
        case gone
    }

    private enum DeletionError: Error {
        case missing
        case changed
        case unsafe(String)
        case system(String)
    }

    private let home: URL
    private let temporaryRoots: [TemporaryRoot]
    private var reader = AgentSessionLogReader()
    private var liveness = AgentSessionLiveness()
    private var lastSnapshots: [String: Snapshot] = [:]

    /// The birthtime tolerance accounts for a tool record timestamp being written
    /// just before the filesystem creates the file.
    private static let birthtimeTolerance: TimeInterval = 5
    /// Every eligible artifact must have had no file activity for this long.
    private static let quietPeriod: TimeInterval = 5 * 60
    private static let idleHourSeconds: TimeInterval = 60 * 60

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         temporaryRoots: [URL]? = nil) {
        let standardHome = home.standardizedFileURL
        self.home = standardHome

        let candidates = temporaryRoots ?? [
            FileManager.default.temporaryDirectory,
            URL(fileURLWithPath: "/tmp", isDirectory: true),
            URL(fileURLWithPath: "/var/tmp", isDirectory: true),
        ]
        var seen = Set<String>()
        var roots: [TemporaryRoot] = []
        for candidate in candidates {
            let lexical = Self.standardizedPath(candidate.path)
            guard !lexical.isEmpty else { continue }
            let real = Self.realPath(lexical)
            let key = lexical + "\u{0}" + real
            guard seen.insert(key).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            roots.append(TemporaryRoot(lexicalPath: lexical, realPath: real))
        }
        self.temporaryRoots = roots
    }

    // MARK: - Public entry point

    /// Scans provider session logs for temporary artifacts.
    ///
    /// - Parameters:
    ///   - policy: Idle lease and cleanup policy.
    ///   - cleanup: When false, nothing is ever deleted.
    ///   - now: Audit clock.
    ///   - allowedPaths: When non-nil with `cleanup`, only these exact
    ///     `AgentDiskItem.path` values may be deleted. This binds manual cleanup
    ///     to the paths the user reviewed.
    func audit(policy: AgentDiskPolicy,
               cleanup: Bool = false,
               now: Date = Date(),
               allowedPaths: Set<String>? = nil) -> AgentDiskReport {
        let reviewedSnapshots = lastSnapshots
        let first = scan(policy: policy, now: now)
        var outcome = first

        if cleanup && !Task.isCancelled {
            outcome = scan(policy: policy, now: now)
            var report = outcome.report
            var seenIssues = Set(report.issues)
            var reclaimedBytes: Int64 = 0
            var removedCount = 0

            let candidates = report.items.filter { item in
                item.state == .eligible && (allowedPaths?.contains(item.path) ?? true)
            }
            let pass = Task.isCancelled ? PassObservation()
                : observeWriters(for: candidates, outcome: outcome, now: now)

            var index = 0
            while index < report.items.count {
                var item = report.items[index]
                guard item.state == .eligible else {
                    index += 1
                    continue
                }
                if let allowedPaths, !allowedPaths.contains(item.path) {
                    index += 1
                    continue
                }
                guard let snapshot = outcome.snapshots[item.path] else {
                    index += 1
                    continue
                }

                // A path the user reviewed must not have been replaced since.
                let baseline = reviewedSnapshots[item.path] ?? first.snapshots[item.path]
                if let baseline, baseline.identity != snapshot.identity {
                    item.state = .failed
                    item.reason = "failed.target-changed"
                    item.eligibleAt = nil
                    report.items[index] = item
                    Self.addIssue("Kept \(item.path) because it changed after it was reviewed.",
                                  to: &report, seen: &seenIssues)
                    index += 1
                    continue
                }

                switch revalidateLease(for: item, outcome: outcome, pass: pass, policy: policy,
                                       now: now, report: &report, seen: &seenIssues) {
                case .gone:
                    report.items.remove(at: index)
                    continue
                case .review(let reason, let issue):
                    item.state = .review
                    item.reason = reason
                    item.eligibleAt = nil
                    report.items[index] = item
                    Self.addIssue(issue, to: &report, seen: &seenIssues)
                    index += 1
                    continue
                case .waiting(let reason, let eligibleAt):
                    item.state = .waiting
                    item.reason = reason
                    item.eligibleAt = eligibleAt
                    report.items[index] = item
                    index += 1
                    continue
                case .keepEligible:
                    break
                }

                guard !Task.isCancelled else { break }
                do {
                    try delete(snapshot: snapshot)
                    item.state = .removed
                    item.reason = "removed"
                    item.eligibleAt = nil
                    report.items[index] = item
                    reclaimedBytes += item.bytes
                    removedCount += 1
                    index += 1
                } catch DeletionError.missing {
                    report.items.remove(at: index)
                } catch DeletionError.changed {
                    item.state = .failed
                    item.reason = "failed.target-changed"
                    item.eligibleAt = nil
                    report.items[index] = item
                    Self.addIssue("Kept \(item.path) because it was replaced before deletion.",
                                  to: &report, seen: &seenIssues)
                    index += 1
                } catch DeletionError.unsafe(let message) {
                    item.state = .failed
                    item.reason = "failed.delete"
                    item.eligibleAt = nil
                    report.items[index] = item
                    Self.addIssue("Could not delete \(item.path): \(message).",
                                  to: &report, seen: &seenIssues)
                    index += 1
                } catch DeletionError.system(let message) {
                    item.state = .failed
                    item.reason = "failed.delete"
                    item.eligibleAt = nil
                    report.items[index] = item
                    Self.addIssue("Could not delete \(item.path): \(message).",
                                  to: &report, seen: &seenIssues)
                    index += 1
                } catch {
                    item.state = .failed
                    item.reason = "failed.delete"
                    item.eligibleAt = nil
                    report.items[index] = item
                    Self.addIssue("Could not delete \(item.path): \(error.localizedDescription).",
                                  to: &report, seen: &seenIssues)
                    index += 1
                }
            }

            report.reclaimedBytes = reclaimedBytes
            report.removedCount = removedCount
            lastSnapshots = outcome.snapshots
            return report
        }

        lastSnapshots = outcome.snapshots
        return outcome.report
    }

    // MARK: - Scan

    private func scan(policy: AgentDiskPolicy, now: Date) -> ScanOutcome {
        var outcome = ScanOutcome()
        outcome.report.scannedAt = now
        var issues: [String] = []
        var seenIssues = Set<String>()

        func note(_ text: String) {
            if seenIssues.insert(text).inserted { issues.append(text) }
        }

        let logs = discoverLogs(sessionPaths: &outcome.sessionPaths, note: note)
        var sessions: [AgentArtifactSession] = []
        for log in logs {
            outcome.providersByLog[log.url.path] = log.provider
            switch reader.read(logURL: log.url, provider: log.provider, home: home) {
            case .parsed(let parse):
                for raw in parse.observedProjectRoots {
                    if let project = projectPath(raw) { outcome.projects.append(project) }
                }
                sessions.append(parse.session)
                if !parse.complete { outcome.incompleteLogs.insert(log.url.path) }
                for issue in parse.issues { note(issue) }
            case .missing:
                break
            case .skipped(let reason):
                note("Skipped agent log \(log.url.path): \(reason).")
            }
        }
        sessions = liveness.observe(sessions, now: now)
        if let issue = liveness.issue { note(issue) }
        outcome.report.sessionCount = Set(sessions.map { "\($0.agent)\u{0}\($0.id)" }).count


        var groups: [String: GroupBuilder] = [:]
        for (sessionIndex, session) in sessions.enumerated() {
            for claim in session.claims where claim.succeeded {
                guard let match = matchTemporaryRoot(for: claim.path) else { continue }
                var builder = groups[match.realPath] ?? GroupBuilder(realPath: match.realPath,
                                                                     root: match.root)
                let claimKey = "\(sessionIndex)\u{0}\(claim.path)\u{0}\(claim.tool)\u{0}\(claim.recordedAt.timeIntervalSince1970)"
                if builder.claimKeys.insert(claimKey).inserted {
                    builder.claims.append(ClaimEntry(claim: claim, sessionIndex: sessionIndex))
                }
                builder.displayPaths.insert(claim.path)
                builder.sessionIndices.insert(sessionIndex)
                builder.toolNames.insert(claim.tool)
                builder.sessionIDs.insert(session.id)
                builder.agents.insert(session.agent)
                builder.logPaths.insert(session.logPath)
                if claim.creationEvidence { builder.firstClaim = min(builder.firstClaim, claim.recordedAt) }
                builder.lastClaim = max(builder.lastClaim, claim.completedAt ?? claim.recordedAt)
                builder.lastActivity = max(builder.lastActivity, session.lastActivityAt)
                groups[match.realPath] = builder
            }
        }

        var evaluated: [Evaluated] = []
        for builder in groups.values {
            guard let path = builder.displayPaths.min() else { continue }
            let inspection = inspect(path: path, group: builder, projects: outcome.projects,
                                     sessionPaths: outcome.sessionPaths, now: now)
            switch inspection {
            case .ignored, .missing:
                continue
            case .file, .reviewed:
                evaluated.append(Evaluated(path: path, group: builder,
                                           inspection: inspection,
                                           depth: Self.depth(of: path)))
            }
        }

        // Deepest paths first so directory measurement never double-counts a
        // separately claimed descendant, and hardlinked inodes are counted once.
        evaluated.sort {
            if $0.depth != $1.depth { return $0.depth > $1.depth }
            return $0.path < $1.path
        }

        var counted = Set<InodeKey>()
        var measureIssues = Set<String>()
        for position in evaluated.indices {
            let entry = evaluated[position]
            let bytes: Int64
            switch entry.inspection {
            case .file(let identity):
                bytes = Self.countedBytes(identity, in: &counted)
            case .reviewed(_, let identity, _):
                if let identity, identity.isDirectory {
                    bytes = directorySize(path: entry.path, counted: &counted, issues: &measureIssues)
                } else if let identity {
                    bytes = Self.countedBytes(identity, in: &counted)
                } else {
                    bytes = 0
                }
            case .ignored, .missing:
                bytes = 0
            }
            evaluated[position].bytes = bytes
        }
        for issue in measureIssues { note(issue) }

        var items: [AgentDiskItem] = []
        for entry in evaluated {
            let path = entry.path
            let group = entry.group
            let sessionList = group.sessionIndices.compactMap {
                sessions.indices.contains($0) ? sessions[$0] : nil
            }

            var state: AgentDiskItemState
            var reason: String
            var eligibleAt: Date?
            var snapshot: Snapshot?

            switch entry.inspection {
            case .ignored, .missing:
                continue
            case .reviewed(let reviewReason, let identity, let issue):
                state = .review
                reason = reviewReason
                eligibleAt = nil
                if let issue { note(issue) }
                if let identity {
                    snapshot = Snapshot(path: path, realPath: group.realPath,
                                        root: group.root, identity: identity)
                }
            case .file(let identity):
                snapshot = Snapshot(path: path, realPath: group.realPath,
                                    root: group.root, identity: identity)
                if sessionList.contains(where: { outcome.incompleteLogs.contains($0.logPath) }) {
                    state = .review
                    reason = "review.log-incomplete"
                } else if sessionList.contains(where: { session in
                    guard let raw = session.projectRoot, !raw.isEmpty,
                          let normalized = ToolExtractor.normalize(path: raw, cwd: nil, home: home),
                          normalized.hasPrefix("/") else { return true }
                    return false
                }) {
                    state = .review
                    reason = "review.project-unknown"
                } else {
                    let lease = lease(for: sessionList, policy: policy, now: now)
                    eligibleAt = lease.eligibleAt
                    state = lease.state
                    reason = lease.reason
                }
            }

            items.append(AgentDiskItem(
                path: path,
                bytes: entry.bytes,
                sessionIDs: Array(group.sessionIDs).sorted(),
                agents: Array(group.agents).sorted(),
                logPaths: Array(group.logPaths).sorted(),
                tools: Array(group.toolNames).sorted(),
                lastActivityAt: group.lastActivity,
                eligibleAt: eligibleAt,
                state: state,
                reason: reason
            ))
            if let snapshot { outcome.snapshots[path] = snapshot }
        }

        items.sort { $0.path < $1.path }
        outcome.report.items = items
        let referencedLogs = Set(items.flatMap(\.logPaths))
        var seenLogs: Set<String> = []
        outcome.report.sessions = sessions.compactMap { session in
            guard referencedLogs.contains(session.logPath), seenLogs.insert(session.logPath).inserted else { return nil }
            return AgentDiskSession(logPath: session.logPath, sessionID: session.id, agent: session.agent,
                                    projectRoot: session.projectRoot, lastActivityAt: session.lastActivityAt,
                                    endedAt: session.endedAt)
        }
        outcome.report.issues = issues
        return outcome
    }

    private func inspect(path: String, group: GroupBuilder, projects: [ProjectPath],
                         sessionPaths: [ProjectPath], now: Date) -> Inspection {
        let components = componentChain(path: path, root: group.root, realPath: group.realPath)
        guard !components.isEmpty else { return .ignored }

        let base = Self.isDescendant(path, of: group.root.lexicalPath)
            ? group.root.lexicalPath
            : group.root.realPath
        var current = base
        var finalIdentity: FileIdentity?

        for (offset, component) in components.enumerated() {
            current = Self.join(current, component)
            var info = Darwin.stat()
            guard Darwin.lstat(current, &info) == 0 else {
                if errno == ENOENT { return .missing }
                return .reviewed(reason: "review.unsupported-type", identity: nil,
                                 issue: "Could not inspect \(current): \(Self.posixMessage(errno)).")
            }
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK {
                return .reviewed(reason: "review.symlink", identity: nil, issue: nil)
            }
            let isLast = offset == components.count - 1
            if !isLast && type != S_IFDIR {
                return .reviewed(reason: "review.unsupported-type", identity: nil, issue: nil)
            }
            if isLast {
                guard type == S_IFREG || type == S_IFDIR else {
                    return .reviewed(reason: "review.unsupported-type", identity: nil, issue: nil)
                }
                finalIdentity = Self.identity(info)
            }
        }

        guard let identity = finalIdentity else { return .missing }

        if Self.isWithin(path: path, realPath: group.realPath, any: sessionPaths) {
            return .reviewed(reason: "review.session-log", identity: identity, issue: nil)
        }

        if identity.uid != getuid() {
            return .reviewed(reason: "review.owner", identity: identity, issue: nil)
        }

        for project in projects {
            if Self.isDescendantOrEqual(group.realPath, project.realPath)
                || Self.isDescendantOrEqual(path, project.lexicalPath) {
                return .reviewed(reason: "review.project-cwd", identity: identity, issue: nil)
            }
        }

        if identity.isDirectory {
            return .reviewed(reason: "review.directory", identity: identity, issue: nil)
        }

        if identity.nlink > 1 {
            return .reviewed(reason: "review.hardlink", identity: identity, issue: nil)
        }

        guard group.firstClaim != .distantFuture else {
            return .reviewed(reason: "review.modified-only", identity: identity, issue: nil)
        }
        let creationMatches = group.claims.contains { entry in
            let claim = entry.claim
            return claim.creationEvidence
                && identity.birth >= claim.recordedAt.addingTimeInterval(-Self.birthtimeTolerance)
                && identity.birth <= (claim.completedAt ?? claim.recordedAt).addingTimeInterval(Self.birthtimeTolerance)
        }
        let latest = group.lastClaim.addingTimeInterval(Self.birthtimeTolerance)
        let modified = Date(timeIntervalSince1970: TimeInterval(identity.modifiedSeconds)
            + TimeInterval(identity.modifiedNanoseconds) / 1_000_000_000)
        if !creationMatches || modified > latest {
            return .reviewed(reason: "review.preexisting", identity: identity, issue: nil)
        }
        if now < modified.addingTimeInterval(Self.quietPeriod) {
            return .reviewed(reason: "review.preexisting", identity: identity, issue: nil)
        }

        return .file(identity)
    }

    // MARK: - Lease

    private struct Lease {
        var state: AgentDiskItemState
        var reason: String
        var eligibleAt: Date?
    }

    private func lease(for sessions: [AgentArtifactSession], policy: AgentDiskPolicy,
                       now: Date) -> Lease {
        guard !sessions.isEmpty else {
            return Lease(state: .waiting, reason: "waiting.session-active", eligibleAt: nil)
        }
        let idleSeconds = TimeInterval(max(1, policy.idleHours)) * Self.idleHourSeconds
        var latestBase = Date.distantPast
        var latestEligible = Date.distantPast
        var allEnded = true
        var idleOnly = true

        for session in sessions {
            let base: Date
            if let endedAt = session.endedAt {
                base = max(endedAt, session.lastActivityAt)
                allEnded = allEnded && true
                idleOnly = false
            } else {
                base = session.lastActivityAt.addingTimeInterval(idleSeconds)
                allEnded = false
            }
            let eligible = base.addingTimeInterval(Self.quietPeriod)
            latestBase = max(latestBase, base)
            latestEligible = max(latestEligible, eligible)
        }

        if now < latestEligible {
            let reason = latestBase > now ? "waiting.session-active" : "waiting.quiet-period"
            return Lease(state: .waiting, reason: reason, eligibleAt: latestEligible)
        }
        let reason: String
        if allEnded {
            reason = "eligible.session-ended"
        } else if idleOnly {
            reason = "eligible.idle-expired"
        } else {
            reason = "eligible.mixed"
        }
        return Lease(state: .eligible, reason: reason, eligibleAt: latestEligible)
    }

    /// One process probe covers every log behind this pass's eligible items,
    /// instead of one probe per item.
    private func observeWriters(for items: [AgentDiskItem], outcome: ScanOutcome,
                                now: Date) -> PassObservation {
        var sessions: [AgentArtifactSession] = []
        var pass = PassObservation()
        for logPath in Set(items.flatMap(\.logPaths)).sorted() {
            guard let provider = outcome.providersByLog[logPath],
                  case .parsed(let parse) = reader.read(logURL: URL(fileURLWithPath: logPath),
                                                        provider: provider, home: home),
                  parse.complete else { continue }
            sessions.append(parse.session)
            pass.stats[parse.session.logPath] = parse.stat
        }
        guard !sessions.isEmpty else { return pass }
        for session in liveness.observe(sessions, now: now, pruningMissingSessions: false) {
            pass.sessions[session.logPath] = session
        }
        return pass
    }

    private func revalidateLease(for item: AgentDiskItem, outcome: ScanOutcome,
                                 pass: PassObservation,
                                 policy: AgentDiskPolicy, now: Date,
                                 report: inout AgentDiskReport,
                                 seen: inout Set<String>) -> Revalidation {
        var sessions: [AgentArtifactSession] = []
        var unobserved: [AgentArtifactSession] = []
        let itemReal = matchTemporaryRoot(for: item.path)?.realPath

        if Self.isWithin(path: item.path, realPath: itemReal ?? item.path, any: outcome.sessionPaths) {
            return .review("review.session-log",
                           "Kept \(item.path) because it is inside an agent session log directory.")
        }

        for logPath in item.logPaths {
            guard let provider = outcome.providersByLog[logPath] else {
                return .review("review.log-incomplete",
                               "Kept \(item.path) because its agent log is no longer known.")
            }
            let url = URL(fileURLWithPath: logPath)
            switch reader.read(logURL: url, provider: provider, home: home) {
            case .missing, .skipped:
                return .review("review.log-incomplete",
                               "Kept \(item.path) because its agent log is no longer readable.")
            case .parsed(let parse):
                for issue in parse.issues { Self.addIssue(issue, to: &report, seen: &seen) }
                if !parse.complete {
                    return .review("review.log-incomplete",
                                   "Kept \(item.path) because its agent log scan is incomplete.")
                }
                let session = parse.session
                guard let root = session.projectRoot,
                      ToolExtractor.normalize(path: root, cwd: nil, home: home) != nil else {
                    return .review("review.project-unknown", "Kept \(item.path) because an agent project directory is unavailable.")
                }
                for raw in parse.observedProjectRoots {
                    if let project = projectPath(raw), let itemReal,
                       Self.isDescendantOrEqual(itemReal, project.realPath)
                        || Self.isDescendantOrEqual(item.path, project.lexicalPath) {
                        return .review("review.project-cwd", "Kept \(item.path) because it is inside an agent project directory.")
                    }
                }

                let stillClaims: Bool
                if let itemReal {
                    stillClaims = session.claims.contains { claim in
                        claim.path == item.path
                            || matchTemporaryRoot(for: claim.path)?.realPath == itemReal
                    }
                } else {
                    stillClaims = session.claims.contains { $0.path == item.path }
                }
                guard stillClaims else { continue }
                // The log was just re-read. Reuse this pass's writer observation
                // only if the log is byte-for-byte the one that was observed.
                if pass.stats[session.logPath] == parse.stat,
                   let observed = pass.sessions[session.logPath] {
                    sessions.append(observed)
                } else {
                    unobserved.append(session)
                }
            }
        }

        if !unobserved.isEmpty {
            sessions += liveness.observe(unobserved, now: now, pruningMissingSessions: false)
        }
        guard !sessions.isEmpty else { return .gone }
        let lease = lease(for: sessions, policy: policy, now: now)
        switch lease.state {
        case .eligible:
            return .keepEligible
        case .waiting:
            return .waiting(lease.reason, lease.eligibleAt)
        case .review:
            return .review(lease.reason, "Kept \(item.path) because its lease was renewed.")
        case .removed, .failed:
            return .waiting("waiting.session-active", lease.eligibleAt)
        }
    }

    // MARK: - Discovery

    private struct DiscoveredLog {
        var url: URL
        var provider: AgentLogProvider
    }

    private func discoverLogs(sessionPaths: inout [ProjectPath],
                              note: @escaping (String) -> Void) -> [DiscoveredLog] {
        let candidates = AgentSessionRoots.discover(home: home)

        var seenRoots = Set<String>()
        var seenLogs = Set<String>()
        var logs: [DiscoveredLog] = []

        for candidate in candidates {
            guard let provider = AgentLogProvider(rawValue: candidate.provider) else { continue }
            let root = candidate.directory
            let rootPath = Self.standardizedPath(root.path)
            guard seenRoots.insert(rootPath).inserted else { continue }
            sessionPaths.append(ProjectPath(lexicalPath: rootPath, realPath: Self.realPath(rootPath)))
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: rootPath),
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants],
                errorHandler: { url, error in
                    note("Could not read \(url.path) while discovering agent logs: \(error.localizedDescription)")
                    return true
                }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                ])
                if values?.isSymbolicLink == true {
                    note("Skipped symlinked agent log \(url.path).")
                    continue
                }
                if values?.isDirectory == true {
                    if ["btw-history", "subagent-artifacts"].contains(url.lastPathComponent) { enumerator.skipDescendants() }
                    continue
                }
                if url.lastPathComponent.hasSuffix(".jsonl.zst") || url.lastPathComponent.hasSuffix(".jsonl.zstd") {
                    note("Compressed agent log is unsupported: \(url.path)")
                    continue
                }
                guard url.pathExtension.lowercased() == "jsonl" else { continue }
                guard values?.isRegularFile == true || Self.isRegularFile(url.path) else { continue }
                let key = url.standardizedFileURL.path
                guard seenLogs.insert(key).inserted else { continue }
                sessionPaths.append(ProjectPath(lexicalPath: Self.standardizedPath(key),
                                                realPath: Self.realPath(key)))
                logs.append(DiscoveredLog(url: URL(fileURLWithPath: key), provider: provider))
            }
        }
        return logs.sorted { $0.url.path < $1.url.path }
    }

    // MARK: - Root matching

    private func projectPath(_ raw: String) -> ProjectPath? {
        guard let path = ToolExtractor.normalize(path: raw, cwd: nil, home: home) else { return nil }
        let real = Self.realPath(path)
        guard real != "/" else { return nil }
        // Starting an agent in /tmp does not make all of /tmp a project. A
        // repository rooted there is still protected, as are all nested projects.
        if temporaryRoots.contains(where: { $0.realPath == real }),
           !FileManager.default.fileExists(atPath: Self.join(real, ".git")),
           !FileManager.default.fileExists(atPath: Self.join(real, ".hg")) { return nil }
        return ProjectPath(lexicalPath: Self.standardizedPath(path), realPath: real)
    }

    private struct RootMatch {
        var root: TemporaryRoot
        var realPath: String
    }

    /// `realPath` is the group key, so every spelling of one directory entry must
    /// produce the same string. Darwin's realpath already returns each directory's
    /// stored name; the final component is replaced by its stored name too, so
    /// case and Unicode-normalization variants on APFS share one group and one
    /// lease. The final component is never followed: a symlink keeps its own name.
    private func matchTemporaryRoot(for path: String) -> RootMatch? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }
        let parentReal = Self.realPath(parent.isEmpty ? "/" : parent)
        let written = Self.standardizedPath(Self.join(parentReal, name))
        var real = written
        if name != ".", name != "..", let stored = Self.storedName(atPath: written),
           !stored.isEmpty, !stored.contains("/"), stored != ".", stored != ".." {
            real = Self.standardizedPath(Self.join(parentReal, stored))
        }

        for root in temporaryRoots {
            if Self.isDescendant(path, of: root.lexicalPath)
                || Self.isDescendant(real, of: root.realPath) {
                return RootMatch(root: root, realPath: real)
            }
        }
        return nil
    }

    private func componentChain(path: String, root: TemporaryRoot, realPath: String) -> [String] {
        let useLexical = Self.isDescendant(path, of: root.lexicalPath)
        let base = useLexical ? root.lexicalPath : root.realPath
        let target = useLexical ? path : realPath
        guard Self.isDescendant(target, of: base) else { return [] }
        let prefix = base == "/" ? 1 : base.count + 1
        guard target.count >= prefix else { return [] }
        return target.dropFirst(prefix).split(separator: "/").map(String.init)
    }

    // MARK: - Size

    private static func countedBytes(_ identity: FileIdentity, in counted: inout Set<InodeKey>) -> Int64 {
        guard identity.blocks > 0 else { return 0 }
        return counted.insert(identity.key).inserted ? identity.blocks * 512 : 0
    }

    /// Measures a directory tree without following symlinks. Hardlinked inodes are
    /// counted once. Directories are review-only, so a partial measurement never
    /// enables deletion.
    private func directorySize(path: String, counted: inout Set<InodeKey>,
                               issues: inout Set<String>, depth: Int = 0) -> Int64 {
        guard depth < 64 else {
            issues.insert("Skipped a deeply nested directory while measuring \(path).")
            return 0
        }
        var total: Int64 = 0
        var info = Darwin.stat()
        if Darwin.lstat(path, &info) == 0 {
            let identity = Self.identity(info)
            if identity.blocks > 0, counted.insert(identity.key).inserted {
                total += identity.blocks * 512
            }
        }

        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        } catch {
            issues.insert("Could not fully measure \(path): \(error.localizedDescription).")
            return total
        }

        for entry in entries {
            let child = Self.join(path, entry)
            var childInfo = Darwin.stat()
            guard Darwin.lstat(child, &childInfo) == 0 else { continue }
            let type = childInfo.st_mode & S_IFMT
            if type == S_IFLNK {
                issues.insert("Skipped a symbolic link while measuring \(path).")
                continue
            }
            if type == S_IFDIR {
                total += directorySize(path: child, counted: &counted, issues: &issues, depth: depth + 1)
            } else if type == S_IFREG {
                if childInfo.st_nlink > 1 {
                    issues.insert("Found a hard link while measuring \(path).")
                }
                let identity = Self.identity(childInfo)
                if identity.blocks > 0, counted.insert(identity.key).inserted {
                    total += identity.blocks * 512
                }
            } else {
                issues.insert("Skipped a non-regular entry while measuring \(path).")
            }
        }
        return total
    }

    // MARK: - Descriptor-relative deletion

    private func openDirectoryChain(_ path: String) throws -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw DeletionError.system(Self.posixMessage(errno)) }
        for component in path.split(separator: "/") {
            let next = String(component).withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            let error = errno
            close(descriptor)
            guard next >= 0 else { throw DeletionError.system(Self.posixMessage(error)) }
            descriptor = next
        }
        return descriptor
    }

    private func delete(snapshot: Snapshot) throws {
        let rootDescriptor = try openDirectoryChain(snapshot.root.realPath)
        defer { close(rootDescriptor) }

        let components = Self.relativeComponents(path: snapshot.realPath,
                                                 root: snapshot.root.realPath)
        guard let name = components.last else {
            throw DeletionError.unsafe("the path is the temporary root")
        }

        var currentDescriptor = rootDescriptor
        var openedDescriptors: [Int32] = []
        defer {
            for descriptor in openedDescriptors.reversed() { close(descriptor) }
        }

        for component in components.dropLast() {
            let descriptor = component.withCString {
                openat(currentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                let code = errno
                if code == ENOENT { throw DeletionError.missing }
                if code == ELOOP { throw DeletionError.unsafe("a symlink appeared in the path") }
                throw DeletionError.system(Self.posixMessage(code))
            }
            openedDescriptors.append(descriptor)
            currentDescriptor = descriptor
        }

        var info = Darwin.stat()
        let statResult = name.withCString {
            fstatat(currentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else {
            let code = errno
            if code == ENOENT { throw DeletionError.missing }
            throw DeletionError.system(Self.posixMessage(code))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw DeletionError.unsafe("the target is no longer a regular file")
        }
        guard info.st_uid == getuid() else {
            throw DeletionError.unsafe("the target is no longer owned by the current user")
        }
        guard info.st_nlink == 1 else {
            throw DeletionError.unsafe("the target gained another hard link")
        }
        guard Self.identity(info) == snapshot.identity else {
            throw DeletionError.changed
        }

        let result = name.withCString { unlinkat(currentDescriptor, $0, 0) }
        guard result == 0 else {
            let code = errno
            if code == ENOENT { throw DeletionError.missing }
            throw DeletionError.system(Self.posixMessage(code))
        }
    }

    // MARK: - Helpers

    private static func identity(_ info: Darwin.stat) -> FileIdentity {
        FileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            blocks: Int64(info.st_blocks),
            mode: info.st_mode,
            uid: info.st_uid,
            nlink: UInt64(info.st_nlink),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(info.st_ctimespec.tv_nsec),
            birth: Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec)
                + TimeInterval(info.st_birthtimespec.tv_nsec) / 1_000_000_000),
            isDirectory: (info.st_mode & S_IFMT) == S_IFDIR
        )
    }

    private static func isRegularFile(_ path: String) -> Bool {
        var info = Darwin.stat()
        guard Darwin.lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func relativeComponents(path: String, root: String) -> [String] {
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return [] }
        return path.dropFirst(prefix.count).split(separator: "/").map(String.init)
    }

    private static func standardizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
            } else {
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    private static func realPath(_ path: String) -> String {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(PATH_MAX)) { buffer in
            let resolved = path.withCString { Darwin.realpath($0, buffer.baseAddress!) }
            guard let resolved else { return standardizedPath(path) }
            return String(cString: resolved)
        }
    }

    /// The directory entry's name as stored by the filesystem, without following a
    /// final symlink. Nil when the entry does not exist.
    private static func storedName(atPath path: String) -> String? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_NAME)
        let headerSize = MemoryLayout<UInt32>.size
        let capacity = headerSize + MemoryLayout<attrreference_t>.size + Int(NAME_MAX) * 4 + 1
        return withUnsafeTemporaryAllocation(byteCount: capacity, alignment: 8) { buffer -> String? in
            guard let base = buffer.baseAddress else { return nil }
            let status = path.withCString {
                getattrlist($0, &request, base, capacity, UInt32(FSOPT_NOFOLLOW))
            }
            guard status == 0 else { return nil }
            let returned = Int(base.load(as: UInt32.self))
            let referenceOffset = headerSize
            guard returned <= capacity,
                  returned >= referenceOffset + MemoryLayout<attrreference_t>.size else { return nil }
            let reference = base.load(fromByteOffset: referenceOffset, as: attrreference_t.self)
            let start = referenceOffset + Int(reference.attr_dataoffset)
            let length = Int(reference.attr_length)
            guard length > 1, start >= 0, start + length <= returned else { return nil }
            let bytes = UnsafeRawBufferPointer(start: base + start, count: length)
            // attr_length includes the terminating NUL.
            return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private static func join(_ base: String, _ component: String) -> String {
        if base == "/" { return "/" + component }
        return base + "/" + component
    }

    private static func isDescendant(_ path: String, of root: String) -> Bool {
        guard path != root else { return false }
        if root == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(root + "/")
    }

    private static func isDescendantOrEqual(_ path: String, _ root: String) -> Bool {
        path == root || isDescendant(path, of: root)
    }

    private static func isWithin(path: String, realPath: String, any roots: [ProjectPath]) -> Bool {
        roots.contains {
            isDescendantOrEqual(realPath, $0.realPath) || isDescendantOrEqual(path, $0.lexicalPath)
        }
    }

    private static func depth(of path: String) -> Int {
        path.split(separator: "/").count
    }

    private static func posixMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    private static func addIssue(_ text: String, to report: inout AgentDiskReport,
                                 seen: inout Set<String>) {
        if seen.insert(text).inserted {
            report.issues.append(text)
        }
    }
}
