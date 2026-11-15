import Foundation

struct AgentDiskChange: OptionSet, Sendable {
    let rawValue: Int
    /// Scanning progress or cleanup feedback changed.
    static let state = AgentDiskChange(rawValue: 1 << 0)
    /// A scan or cleanup produced a new report.
    static let report = AgentDiskChange(rawValue: 1 << 1)
    /// Automatic cleanup or the idle timeout changed.
    static let policy = AgentDiskChange(rawValue: 1 << 2)
    static let all: AgentDiskChange = [.state, .report, .policy]
}

/// One session and the visible files it claimed. A file claimed by several sessions appears
/// under each of them; `bytes` counts it in each group.
struct AgentDiskSessionGroup: Identifiable, Sendable {
    var id: String { session.logPath }
    var session: AgentDiskSession
    var items: [AgentDiskItem]
    var bytes: Int64
    var eligibleCount: Int
}

/// Outcome line shown after a cleanup deletes files, or after a manual cleanup deletes nothing.
struct AgentDiskCleanupMessage: Equatable, Sendable {
    var text: String
    var deletedFiles: Bool
}

/// Owns the disk audit for agent temporary artifacts. Scanning and deletion happen in
/// `AgentDiskAuditService`; this model only chooses policy, keeps the last report, and filters
/// it for the page. The timer runs for as long as the window exists, independent of the
/// selected sidebar page.
@MainActor
final class AgentDiskViewModel {
    /// Fixed choices offered by the host. Other stored values fall back to the default.
    static let idleHourChoices = [1, 24, 72, 168]
    static var isSnapshotRun: Bool {
        ProcessInfo.processInfo.environment["SIDEWATCH_UI_SNAPSHOT_DIR"] != nil
    }

    private enum Key {
        static let automaticCleanup = "Sidewatch.agentDiskAutomaticCleanup"
        static let idleHours = "Sidewatch.agentDiskIdleHours"
        static let sessionFolders = "Sidewatch.agentDiskSessionFolders"
    }

    private let service: AgentDiskAuditService
    private let defaults: UserDefaults
    private var timer: Timer?
    private var scanTask: Task<Void, Never>?
    private var resetObserver: NSObjectProtocol?
    private var started = false
    /// Incremented for every scan and every cancellation, so a late result can't commit.
    private var scanGeneration = 0
    private var inFlightCleanup = false
    private var inFlightManualCleanup = false
    /// A Clean Eligible confirmed while another scan was running. It runs as soon as that scan
    /// finishes or is cancelled, still bounded by the paths the user reviewed.
    private var pendingManualCleanup: Set<String>?

    private(set) var policy: AgentDiskPolicy
    private(set) var report: AgentDiskReport?
    private(set) var isScanning = false
    /// True while the user is waiting on a scan: the first scan, Scan, or Clean Eligible.
    /// Minute refreshes run in the background and keep the previous numbers on screen.
    private(set) var isForegroundScan = false
    /// Message shown after a cleanup scan completes.
    private(set) var cleanupMessage: AgentDiskCleanupMessage?
    private(set) var searchText = ""

    /// When the UI snapshot harness is running, cleanup is disabled outright. Snapshots must
    /// never remove a user's files, even if automatic cleanup was left on.
    let cleanupSuppressed: Bool

    private var observers: [UUID: (AgentDiskChange) -> Void] = [:]

    init(service: AgentDiskAuditService = AgentDiskAuditService(), defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        cleanupSuppressed = Self.isSnapshotRun
        defaults.register(defaults: [
            Key.automaticCleanup: false,
            Key.idleHours: 72
        ])
        var policy = AgentDiskPolicy()
        policy.automaticCleanup = defaults.bool(forKey: Key.automaticCleanup)
        let storedHours = defaults.integer(forKey: Key.idleHours)
        policy.idleHours = Self.idleHourChoices.contains(storedHours) ? storedHours : 72
        policy.sessionFolders = Self.loadSessionFolders(defaults)
        if Self.isSnapshotRun { policy.automaticCleanup = false }
        self.policy = policy
    }

    // MARK: Observation

    @discardableResult
    func observe(_ handler: @escaping (AgentDiskChange) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func notify(_ change: AgentDiskChange) {
        for handler in observers.values { handler(change) }
    }

    // MARK: Lifecycle

    /// Starts the first read-only scan and the minute timer. Called once when the page is
    /// constructed, so artifacts are audited while the app is open, not when the page is shown.
    func start() {
        guard !started else { return }
        started = true
        resetObserver = NotificationCenter.default.addObserver(
            forName: AppPreferences.didReset, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesReset() }
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.timerFired() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        scan(cleanup: false, foreground: true)
    }

    @discardableResult
    func timerFired() -> Task<Void, Never>? {
        // The minute tick always refreshes the page; only the stored policy turns it into cleanup.
        scan(cleanup: policy.automaticCleanup && !cleanupSuppressed, foreground: false)
    }

    private func preferencesReset() {
        // Erase All Data removed the defaults domain. Cancel any running cleanup, including a
        // queued manual one, and reset the live policy immediately so a timer tick can't keep
        // deleting files under the old setting. The registered defaults supply the new values.
        pendingManualCleanup = nil
        cancelScan()
        policy = AgentDiskPolicy()
        cleanupMessage = nil
        notify([.policy, .state])
        rescanAfterCancel()
    }

    // MARK: Policy

    func setAutomaticCleanup(_ enabled: Bool) {
        guard !cleanupSuppressed, enabled != policy.automaticCleanup else { return }
        policy.automaticCleanup = enabled
        defaults.set(enabled, forKey: Key.automaticCleanup)
        // Stop an automatic cleanup that is already running. Manual cleanup keeps its bounded
        // path set and is allowed to finish. The rescan replaces the report the cancelled
        // cleanup would have published, so files it already deleted leave the list.
        if !enabled, inFlightCleanup, !inFlightManualCleanup {
            cancelScan()
            rescanAfterCancel()
        }
        notify(.policy)
    }

    func setIdleHours(_ hours: Int) {
        guard Self.idleHourChoices.contains(hours), hours != policy.idleHours else { return }
        policy.idleHours = hours
        defaults.set(hours, forKey: Key.idleHours)
        notify(.policy)
        // Eligibility depends on the timeout, so the list must not keep showing the old lease.
        // A running automatic cleanup or read-only scan used the old policy: cancel it and
        // rescan. A manual cleanup keeps its reviewed paths and finishes first.
        if isScanning, !inFlightManualCleanup {
            cancelScan()
            rescanAfterCancel()
        } else if !isScanning {
            scan(cleanup: false, foreground: false)
        }
    }

    /// Adds a provider folder the automatic discovery can't see. The next scan covers it, and
    /// any cleanup still running under the old folder list is replaced, because a newly
    /// visible session may claim the same files.
    func addSessionFolder(_ folder: AgentSessionFolder) {
        guard !policy.sessionFolders.contains(folder) else { return }
        policy.sessionFolders.append(folder)
        sessionFoldersChanged()
    }

    func removeSessionFolder(_ folder: AgentSessionFolder) {
        guard let index = policy.sessionFolders.firstIndex(of: folder) else { return }
        policy.sessionFolders.remove(at: index)
        sessionFoldersChanged()
    }

    private func sessionFoldersChanged() {
        if let data = try? JSONEncoder().encode(policy.sessionFolders) {
            defaults.set(data, forKey: Key.sessionFolders)
        }
        notify(.policy)
        if isScanning, !inFlightManualCleanup {
            cancelScan()
            rescanAfterCancel()
        } else if !isScanning {
            scan(cleanup: false, foreground: false)
        }
    }

    private static func loadSessionFolders(_ defaults: UserDefaults) -> [AgentSessionFolder] {
        guard let data = defaults.data(forKey: Key.sessionFolders),
              let folders = try? JSONDecoder().decode([AgentSessionFolder].self, from: data) else { return [] }
        return folders.filter { AgentLogProvider(rawValue: $0.provider) != nil && $0.path.hasPrefix("/") }
    }

    func setSearchText(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        notify(.report)
    }

    // MARK: Commands

    /// Manual Scan never deletes anything. If a background refresh is already running, the
    /// page shows it as the user's scan instead of starting another.
    func scan() {
        cleanupMessage = nil
        if isScanning {
            isForegroundScan = true
            notify(.state)
        } else {
            scan(cleanup: false, foreground: true)
        }
    }

    /// Manual cleanup. The caller captures the eligible paths from the report it showed the
    /// user; the engine rescans but may only remove those reviewed paths. A confirmation that
    /// arrives during another scan is queued rather than dropped.
    func cleanEligible(allowedPaths: Set<String>) {
        guard !cleanupSuppressed, !allowedPaths.isEmpty else { return }
        if isScanning {
            pendingManualCleanup = allowedPaths
            isForegroundScan = true
            notify(.state)
        } else {
            scan(cleanup: true, allowedPaths: allowedPaths, foreground: true)
        }
    }

    /// The scan or cleanup currently in flight. Tests await it instead of sleeping.
    var activeScan: Task<Void, Never>? { scanTask }

    @discardableResult
    private func scan(cleanup: Bool, allowedPaths: Set<String>? = nil, foreground: Bool) -> Task<Void, Never>? {
        guard !isScanning else { return nil }
        isScanning = true
        isForegroundScan = foreground
        scanGeneration += 1
        let generation = scanGeneration
        inFlightCleanup = cleanup
        inFlightManualCleanup = cleanup && allowedPaths != nil
        notify(.state)
        let policy = self.policy
        scanTask = Task { [weak self] in
            guard let self else { return }
            let report = await self.service.audit(
                policy: policy,
                cleanup: cleanup,
                allowedPaths: allowedPaths
            )
            // A cancelled cleanup must not commit a stale report, and its cancellation path
            // already cleared the scanning state.
            guard !Task.isCancelled, !report.cancelled, generation == self.scanGeneration else { return }
            self.finish(report, cleanup: cleanup, allowedPaths: allowedPaths)
        }
        return scanTask
    }

    /// Cancels the current scan and lets the actor observe task cancellation before any unlink.
    private func cancelScan() {
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        inFlightCleanup = false
        inFlightManualCleanup = false
        if isScanning {
            isScanning = false
            isForegroundScan = false
            notify(.state)
        }
    }

    /// Replaces the report a cancelled scan would have published. A queued manual cleanup
    /// runs in its place; otherwise a read-only scan picks up the current policy.
    private func rescanAfterCancel() {
        if let paths = pendingManualCleanup {
            pendingManualCleanup = nil
            scan(cleanup: true, allowedPaths: paths, foreground: true)
        } else {
            scan(cleanup: false, foreground: false)
        }
    }

    private func finish(_ report: AgentDiskReport, cleanup: Bool, allowedPaths: Set<String>?) {
        scanTask = nil
        inFlightCleanup = false
        inFlightManualCleanup = false
        self.report = report
        isScanning = false
        isForegroundScan = false
        let manual = allowedPaths != nil
        if cleanup, report.removedCount > 0 {
            let bytes = Self.formattedBytes(report.reclaimedBytes)
            let text = manual
                ? String(localized: "Deleted \(report.removedCount) files and freed \(bytes).")
                : String(localized: "Automatic cleanup deleted \(report.removedCount) files and freed \(bytes).")
            cleanupMessage = AgentDiskCleanupMessage(text: text, deletedFiles: true)
        } else if cleanup, manual {
            cleanupMessage = AgentDiskCleanupMessage(
                text: String(localized: "No files were deleted. Files that changed after you reviewed them were kept."),
                deletedFiles: false
            )
        }
        // An automatic run that deleted nothing leaves the previous message in place.
        notify([.state, .report])
        if let paths = pendingManualCleanup {
            pendingManualCleanup = nil
            scan(cleanup: true, allowedPaths: paths, foreground: true)
        }
    }

    private static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Snapshot harness support: yield until the initial scan has a report. Bounded so a stuck
    /// scan can't hang the app capture; the page still renders its truthful scanning state.
    func awaitInitialScan(timeout: TimeInterval = 120) async {
        guard !hasScanned else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while !hasScanned, isScanning, !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Derived state

    var hasScanned: Bool { report != nil }
    var items: [AgentDiskItem] { report?.items ?? [] }
    var sessionCount: Int { report?.sessionCount ?? 0 }
    var issues: [String] { report?.issues ?? [] }
    var sessionRoots: [AgentDiskSessionRoot] { report?.sessionRoots ?? [] }
    var totalBytes: Int64 { report?.totalBytes ?? 0 }
    var eligibleBytes: Int64 { report?.eligibleBytes ?? 0 }
    var eligibleCount: Int { items.reduce(0) { $0 + ($1.state == .eligible ? 1 : 0) } }
    /// Clean stays available during a background refresh; a confirmation queues behind it.
    var canClean: Bool {
        !cleanupSuppressed && !isForegroundScan && pendingManualCleanup == nil && eligibleCount > 0
    }

    /// Newest-largest first; search matches paths, agents, tools, sessions, and logs.
    var visibleItems: [AgentDiskItem] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [AgentDiskItem]
        if needle.isEmpty {
            filtered = items
        } else {
            filtered = items.filter { item in
                if item.path.localizedCaseInsensitiveContains(needle) { return true }
                if item.agents.contains(where: { $0.localizedCaseInsensitiveContains(needle) }) { return true }
                if item.tools.contains(where: { $0.localizedCaseInsensitiveContains(needle) }) { return true }
                if item.logPaths.contains(where: { $0.localizedCaseInsensitiveContains(needle) }) { return true }
                if item.sessionIDs.contains(where: { $0.localizedCaseInsensitiveContains(needle) }) { return true }
                return item.reason.localizedCaseInsensitiveContains(needle)
            }
        }
        return filtered.sorted { lhs, rhs in
            lhs.bytes == rhs.bytes ? lhs.path < rhs.path : lhs.bytes > rhs.bytes
        }
    }

    /// `visibleItems` grouped under the session logs that claimed them, largest sessions first.
    var visibleGroups: [AgentDiskSessionGroup] {
        let sessions = Dictionary((report?.sessions ?? []).map { ($0.logPath, $0) }, uniquingKeysWith: { first, _ in first })
        var buckets: [String: [AgentDiskItem]] = [:]
        var order: [String] = []
        for item in visibleItems {
            for log in item.logPaths.isEmpty ? [""] : item.logPaths {
                if buckets[log] == nil { order.append(log) }
                buckets[log, default: []].append(item)
            }
        }
        let groups = order.map { log -> AgentDiskSessionGroup in
            let items = buckets[log] ?? []
            let session = sessions[log] ?? AgentDiskSession(
                logPath: log, sessionID: items.first?.sessionIDs.first ?? "",
                agent: items.first?.agents.first ?? "", projectRoot: nil,
                lastActivityAt: items.map(\.lastActivityAt).max() ?? .distantPast, endedAt: nil
            )
            return AgentDiskSessionGroup(
                session: session, items: items,
                bytes: items.reduce(0) { $1.state == .removed ? $0 : $0 + $1.bytes },
                eligibleCount: items.reduce(0) { $0 + ($1.state == .eligible ? 1 : 0) }
            )
        }
        return groups.sorted { lhs, rhs in
            lhs.bytes == rhs.bytes ? lhs.session.lastActivityAt > rhs.session.lastActivityAt : lhs.bytes > rhs.bytes
        }
    }
}
