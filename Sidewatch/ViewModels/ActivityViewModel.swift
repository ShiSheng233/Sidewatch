import Foundation
import Darwin

enum SidewatchPage: String, CaseIterable, Sendable {
    case agents, timeline, ports, leftovers, rules
}

/// Connection to the monitor service as observed by the host.
enum MonitorLinkState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    /// The connection was lost; displayed history is from before the loss.
    case disconnected
    case failed(code: String, message: String)
}

/// A truthful, actionable state message shown above the content.
struct StatusNotice: Hashable, Sendable {
    enum Severity: Int, Sendable { case info, warning, error }
    enum Action: Hashable, Sendable {
        case installExtension, openExtensionSettings, openFullDiskAccess, reconnect, refresh
    }
    var severity: Severity
    var message: String
    var action: Action?
    /// Short headline; `message` carries the detail.
    var title: String?
}

enum TimelineOutcomeFilter: String, CaseIterable, Sendable {
    case all, wouldBlock, blocked, allowed, failed
    var queryValue: String? {
        switch self {
        case .all: return nil
        case .wouldBlock: return "wouldblock"
        case .blocked: return "blocked"
        case .allowed: return "allowed"
        case .failed: return "failed"
        }
    }
}

struct TimelineFilter: Equatable, Sendable {
    var sessionID: String?
    var projectRoot: String?
    var kind: ActivityKind?
    var outcome: TimelineOutcomeFilter = .all
    var execution: ExecutionIdentity?
}

enum TimelineLoadState: Equatable, Sendable {
    case idle, loading, complete
    case failed(String)
    case unavailable
}

enum InspectorSubject: Equatable, Sendable {
    case none
    case agent(AgentRow)
    case port(PortRow)
    case leftover(LeftoverRow)
    case activity(ActivityRecord)
}

enum RelatedActivityState: Equatable, Sendable {
    case idle, loading
    case loaded([ActivityRecord])
    case unavailable
    case failed(String)
}

enum DiffState: Equatable, Sendable {
    case idle, loading
    case loaded(GitDiffResult)
}

/// Result of a manual Stop / Force Quit, kept separate from audit persistence.
struct ControlFeedback: Equatable, Sendable {
    var processKey: String
    var operation: ControlOperation
    var signalSent: Bool
    var errorCode: Int32?
    var auditErrorCode: String?
    var exitObserved: Bool
}

struct ViewModelChange: OptionSet, Sendable {
    let rawValue: Int
    static let status = ViewModelChange(rawValue: 1 << 0)
    static let rows = ViewModelChange(rawValue: 1 << 1)
    static let timeline = ViewModelChange(rawValue: 1 << 2)
    static let inspector = ViewModelChange(rawValue: 1 << 3)
    static let page = ViewModelChange(rawValue: 1 << 4)
    static let configuration = ViewModelChange(rawValue: 1 << 5)
    static let all: ViewModelChange = [.status, .rows, .timeline, .inspector, .page, .configuration]
}

/// Main projection/command model. Views read state and call commands; they receive explicit
/// change notifications and never perform collection, attribution, or XPC themselves.
@MainActor
final class ActivityViewModel {
    // MARK: Dependencies
    let extensionManager: ExtensionManager
    let connection: MonitorConnection
    private let probe: ProcessSnapshotService
    private let control: ProcessControlService
    private let gitDiff: GitDiffService

    // MARK: State
    private(set) var page: SidewatchPage = .agents
    private(set) var searchText = ""
    private(set) var link: MonitorLinkState = .idle
    private(set) var health: MonitorHealth?
    private(set) var monitorSnapshot: MonitorSnapshot?
    private(set) var nativeSnapshot: NativeProcessSnapshot?
    private(set) var nativeErrorCode: Int32?
    private(set) var monitorRefreshErrorMessage: String?
    private(set) var projection = ActivityProjection.empty
    private(set) var lastRefresh: Date?

    private(set) var timeline: [ActivityRecord] = []
    private(set) var timelineState: TimelineLoadState = .unavailable
    private(set) var timelineFilter = TimelineFilter()
    private var timelineCursor: (storeID: String, watermark: Int64, nextBeforeID: Int64?)?

    private(set) var inspector: InspectorSubject = .none
    private(set) var relatedActivity: RelatedActivityState = .idle
    private(set) var diff: DiffState = .idle
    private(set) var controlFeedback: ControlFeedback?
    private(set) var pendingControls: Set<String> = []

    var configuration: MonitorConfiguration? { monitorSnapshot?.configuration }
    var definitions: [AgentDefinition] { configuration?.agentDefinitions ?? AgentDefinition.defaults }
    var isHistoryAvailable: Bool { link == .connected && monitorSnapshot != nil }

    var visibleAgents: [AgentRow] { ProjectionSearch.filter(projection.agents, searchText) }
    private(set) var agentServicesOnly = false
    var visiblePorts: [PortRow] {
        let rows = agentServicesOnly ? projection.ports.filter { !$0.attributions.isEmpty } : projection.ports
        return ProjectionSearch.filter(rows, searchText)
    }

    func setAgentServicesOnly(_ value: Bool) {
        guard value != agentServicesOnly else { return }
        agentServicesOnly = value
        notify(.rows)
    }
    var visibleLeftovers: [LeftoverRow] { ProjectionSearch.filter(projection.leftovers, searchText) }

    // MARK: Observation
    private var observers: [UUID: (ViewModelChange) -> Void] = [:]

    @discardableResult
    func observe(_ handler: @escaping (ViewModelChange) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func notify(_ change: ViewModelChange) {
        for handler in observers.values { handler(change) }
    }

    // MARK: Lifecycle

    private var refreshTimer: Timer?
    private var refreshInFlight = false
    private var refreshQueued = false
    private var commitDebounce: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 2
    private var relatedTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var timelineTask: Task<Void, Never>?
    private var started = false

    init(
        extensionManager: ExtensionManager,
        connection: MonitorConnection,
        probe: ProcessSnapshotService = ProcessSnapshotService(),
        gitDiff: GitDiffService = GitDiffService()
    ) {
        self.extensionManager = extensionManager
        self.connection = connection
        self.probe = probe
        self.control = ProcessControlService(connection: connection)
        self.gitDiff = gitDiff
    }

    func start() {
        guard !started else { return }
        started = true
        extensionManager.onChange = { [weak self] in self?.extensionStateChanged() }
        connection.onCommit = { [weak self] storeID, watermark in self?.monitorCommitted(storeID: storeID, watermark: watermark) }
        connection.onHealth = { [weak self] health in self?.healthChanged(health) }
        connection.onDisconnect = { [weak self] in self?.monitorDisconnected() }

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        refresh()
        connect()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        reconnectTask?.cancel()
        commitDebounce?.cancel()
        connection.disconnect()
    }

    // MARK: Commands — navigation and filtering

    func setPage(_ page: SidewatchPage) {
        guard page != self.page else { return }
        self.page = page
        clearInspector()
        if page == .timeline, timeline.isEmpty, isHistoryAvailable { reloadTimeline() }
        notify([.page, .inspector])
    }

    func setSearchText(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        notify(.rows)
        if isHistoryAvailable { reloadTimeline() }
    }

    func setTimelineFilter(_ filter: TimelineFilter) {
        guard filter != timelineFilter else { return }
        timelineFilter = filter
        notify(.timeline)
        reloadTimeline()
    }

    /// Opens the timeline filtered to an exact execution or session.
    func showTimeline(sessionID: String? = nil, execution: ExecutionIdentity? = nil) {
        var filter = TimelineFilter()
        filter.sessionID = sessionID
        filter.execution = execution
        timelineFilter = filter
        page = .timeline
        clearInspector()
        notify([.page, .timeline, .inspector])
        reloadTimeline()
    }

    // MARK: Commands — extension and connection

    func activateExtension() { extensionManager.activate() }
    func openFullDiskAccess() { extensionManager.openFullDiskAccess() }
    func openExtensionSettings() { extensionManager.openExtensionSettings() }

    /// True while the system is asked for the extension state or the service is being reached.
    var isCheckingMonitor: Bool { extensionManager.operation == .checking || link == .connecting }
    private(set) var isRemovingMonitor = false
    private(set) var isErasingData = false

    /// Asks the system for the extension state again and re-establishes the service connection.
    func checkMonitorStatus() {
        extensionManager.refreshStatus()
        reconnectDelay = 2
        switch link {
        case .connected: refresh()
        case .connecting: break
        case .idle, .disconnected, .failed: connect()
        }
        notify(.status)
    }

    /// Uninstalls the extension. With `eraseData`, the monitor first erases this user's data and
    /// deletes its store when it stops, and this app's preferences are reset.
    func uninstallMonitor(eraseData: Bool) async -> MonitorRemovalOutcome {
        guard !isRemovingMonitor else { return .failed(String(localized: "The monitor is already being removed.")) }
        isRemovingMonitor = true
        notify(.status)
        defer {
            isRemovingMonitor = false
            notify(.all)
        }
        var armed = false
        if eraseData, link == .connected {
            do {
                try await connection.eraseAllData()
                try await connection.prepareForRemoval(true)
                armed = true
            } catch {
                return .failed(Self.message(for: error))
            }
        }
        reconnectTask?.cancel()
        let outcome = await extensionManager.deactivate()
        switch outcome {
        case .removed:
            connection.disconnect()
            link = .idle
            discardMonitorState()
            if eraseData { resetLocalState() }
        case .afterRestart:
            if eraseData { resetLocalState() }
        case .canceled, .failed:
            if armed { try? await connection.prepareForRemoval(false) }
        }
        refresh()
        return outcome
    }

    func perform(_ action: StatusNotice.Action) {
        switch action {
        case .installExtension: activateExtension()
        case .openExtensionSettings: openExtensionSettings()
        case .openFullDiskAccess: openFullDiskAccess()
        case .reconnect: reconnectDelay = 2; connect()
        case .refresh: refresh()
        }
    }

    func connect() {
        guard link != .connecting, link != .connected else { return }
        reconnectTask?.cancel()
        link = .connecting
        notify(.status)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await connection.connect()
                link = .connected
                reconnectDelay = 2
                notify(.status)
                refresh()
                reloadTimeline()
            } catch {
                let failure = error as? MonitorConnectionError
                link = .failed(
                    code: failure?.errorCode ?? "operation",
                    message: failure?.errorDescription ?? String(localized: "The Sidewatch monitor service is unavailable.")
                )
                notify(.status)
                scheduleReconnect()
            }
        }
    }

    /// Retries only while the OS reports the extension as enabled; install and approval stay explicit.
    private func scheduleReconnect() {
        guard extensionManager.availability == .active, extensionManager.operation != .uninstalling else { return }
        reconnectTask?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 60)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func extensionStateChanged() {
        if extensionManager.availability == .active, extensionManager.operation == nil,
           link != .connected, link != .connecting {
            reconnectDelay = 2
            connect()
        }
        notify(.status)
    }

    private func monitorDisconnected() {
        link = .disconnected
        health = nil
        timelineCursor = nil
        notify(.status)
        scheduleReconnect()
    }

    private func healthChanged(_ health: MonitorHealth) {
        self.health = health
        notify([.status, .configuration])
    }

    private func monitorCommitted(storeID: String, watermark: Int64) {
        commitDebounce?.cancel()
        commitDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            refresh()
            catchUpTimeline()
        }
    }

    // MARK: Commands — refresh

    func refresh() {
        guard !refreshInFlight else {
            refreshQueued = true
            return
        }
        refreshInFlight = true
        Task { [weak self] in
            guard let self else { return }
            await performRefresh()
            refreshInFlight = false
            if refreshQueued {
                refreshQueued = false
                refresh()
            }
        }
    }

    private func performRefresh() async {
        var native: NativeProcessSnapshot?
        do {
            native = try await probe.snapshot()
            nativeErrorCode = nil
        } catch let error as ProcessSnapshotError {
            nativeErrorCode = error.code
        } catch {
            nativeErrorCode = EIO
        }
        nativeSnapshot = native

        if link == .connected {
            do {
                let snapshot = try await connection.snapshot()
                if let previous = monitorSnapshot, previous.storeID != snapshot.storeID {
                    timeline = []
                    timelineCursor = nil
                }
                monitorSnapshot = snapshot
                health = snapshot.health
                monitorRefreshErrorMessage = nil
            } catch {
                monitorRefreshErrorMessage = (error as? MonitorConnectionError)?.errorDescription
                    ?? String(localized: "The monitor service reply could not be read.")
            }
        }

        let input = ProjectionInput(
            graph: monitorSnapshot?.graph ?? GraphSnapshot(),
            monitorEndpoints: link == .connected ? monitorSnapshot?.endpoints ?? [] : [],
            liveExecutions: link == .connected ? monitorSnapshot?.liveExecutions ?? [] : [],
            native: native,
            definitions: definitions,
            historyAvailable: isHistoryAvailable
        )
        projection = await Task.detached(priority: .userInitiated) {
            ActivityProjection.make(input)
        }.value
        lastRefresh = Date()
        reconcileSelection()
        reconcileControlFeedback()
        notify([.rows, .status, .configuration])
    }

    /// Keeps the inspector subject current; a vanished row clears the inspector.
    private func reconcileSelection() {
        switch inspector {
        case .agent(let row):
            if let updated = projection.agents.first(where: { $0.id == row.id }) {
                if updated != row { inspector = .agent(updated); notify(.inspector) }
            } else { clearInspector(); notify(.inspector) }
        case .port(let row):
            if let updated = projection.ports.first(where: { $0.id == row.id }) {
                if updated != row { inspector = .port(updated); notify(.inspector) }
            } else { clearInspector(); notify(.inspector) }
        case .leftover(let row):
            if let updated = projection.leftovers.first(where: { $0.id == row.id }) {
                if updated != row { inspector = .leftover(updated); notify(.inspector) }
            } else { clearInspector(); notify(.inspector) }
        case .activity, .none:
            break
        }
    }

    private func reconcileControlFeedback() {
        guard var feedback = controlFeedback, feedback.signalSent, !feedback.exitObserved,
              nativeSnapshot != nil else { return }
        let stillAlive = nativeSnapshot?.executions.contains { $0.identity.process.stableID == feedback.processKey } ?? true
        if !stillAlive {
            feedback.exitObserved = true
            controlFeedback = feedback
            notify(.inspector)
        }
    }

    // MARK: Commands — timeline

    func reloadTimeline() {
        guard isHistoryAvailable else {
            timeline = []
            timelineCursor = nil
            timelineState = .unavailable
            notify(.timeline)
            return
        }
        timelineTask?.cancel()
        timeline = []
        timelineCursor = nil
        timelineState = .loading
        notify(.timeline)
        let query = makeQuery()
        timelineTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await connection.activities(query)
                guard !Task.isCancelled else { return }
                timeline = page.activities
                timelineCursor = (page.storeID, page.watermark, page.nextBeforeID)
                timelineState = page.nextBeforeID == nil ? .complete : .idle
            } catch {
                guard !Task.isCancelled else { return }
                timelineState = .failed(Self.message(for: error))
            }
            notify(.timeline)
        }
    }

    func loadMoreTimeline() {
        guard isHistoryAvailable, timelineState == .idle,
              let cursor = timelineCursor, let before = cursor.nextBeforeID else { return }
        timelineState = .loading
        notify(.timeline)
        var query = makeQuery()
        query.beforeID = before
        query.watermark = cursor.watermark
        query.storeID = cursor.storeID
        timelineTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await connection.activities(query)
                guard !Task.isCancelled else { return }
                let known = Set(timeline.map(\.id))
                timeline.append(contentsOf: page.activities.filter { !known.contains($0.id) })
                timelineCursor = (page.storeID, cursor.watermark, page.nextBeforeID)
                timelineState = page.nextBeforeID == nil ? .complete : .idle
            } catch MonitorConnectionError.cursor {
                reloadTimeline()
                return
            } catch {
                guard !Task.isCancelled else { return }
                timelineState = .failed(Self.message(for: error))
            }
            notify(.timeline)
        }
    }

    /// Fetches activity newer than the newest displayed row and prepends it.
    private func catchUpTimeline() {
        guard isHistoryAvailable, timelineState != .loading else { return }
        guard let cursor = timelineCursor, let newest = timeline.first?.id else {
            if page == .timeline { reloadTimeline() }
            return
        }
        var query = makeQuery()
        query.afterID = newest
        query.storeID = cursor.storeID
        query.limit = 500
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await connection.activities(query)
                if page.nextBeforeID != nil {
                    // More than one page arrived; reload for a consistent view.
                    reloadTimeline()
                    return
                }
                guard !page.activities.isEmpty else { return }
                let known = Set(timeline.map(\.id))
                let fresh = page.activities.filter { !known.contains($0.id) }.sorted { $0.id > $1.id }
                timeline.insert(contentsOf: fresh, at: 0)
                notify(.timeline)
            } catch {
                reloadTimeline()
            }
        }
    }

    private func makeQuery() -> ActivityQuery {
        var query = ActivityQuery()
        query.text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        query.sessionID = timelineFilter.sessionID
        query.projectRoot = timelineFilter.projectRoot
        query.kind = timelineFilter.kind
        query.outcome = timelineFilter.outcome.queryValue
        query.execution = timelineFilter.execution
        query.limit = 200
        return query
    }

    /// Sessions and projects available as timeline filter choices.
    var timelineSessions: [AgentSession] {
        (monitorSnapshot?.graph.sessions ?? []).sorted { $0.startedAt > $1.startedAt }
    }

    var timelineProjects: [ProjectRecord] {
        var seen: Set<String> = []
        return (monitorSnapshot?.graph.sessions ?? []).compactMap(\.project)
            .filter { seen.insert($0.root).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Commands — selection and inspector

    func select(_ subject: InspectorSubject) {
        guard subject != inspector else { return }
        clearInspector()
        inspector = subject
        loadRelatedActivity()
        notify(.inspector)
    }

    private func clearInspector() {
        relatedTask?.cancel()
        diffTask?.cancel()
        inspector = .none
        relatedActivity = .idle
        diff = .idle
    }

    func launchChain(for identity: ExecutionIdentity) -> [LaunchChainNode] {
        projection.index.launchChain(for: identity)
    }

    func responsibleRecord(for identity: ExecutionIdentity) -> ExecutionRecord? {
        guard let responsible = projection.index.record(for: identity)?.responsible else { return nil }
        return projection.index.record(for: responsible) ?? projection.index.currentRecord(for: responsible.process)
    }

    func record(for identity: ExecutionIdentity) -> ExecutionRecord? {
        projection.index.record(for: identity) ?? projection.index.currentRecord(for: identity.process)
    }

    func agentNames(for activity: ActivityRecord) -> [String] {
        activity.sessionIDs.compactMap { projection.index.sessions[$0]?.agent.name }
    }

    private func loadRelatedActivity() {
        var query = ActivityQuery()
        query.limit = 50
        switch inspector {
        case .none:
            return
        case .agent(let row):
            guard let sessionID = row.sessionID else { relatedActivity = .unavailable; return }
            query.sessionID = sessionID
        case .port(let row):
            guard let identity = projection.index.historyIdentity(for: row.endpoint.execution.process) else {
                relatedActivity = .unavailable; return
            }
            query.execution = identity
        case .leftover(let row):
            guard let identity = projection.index.historyIdentity(for: row.execution.identity.process) else {
                relatedActivity = .unavailable; return
            }
            query.execution = identity
        case .activity(let activity):
            guard let execution = activity.execution else { relatedActivity = .unavailable; return }
            query.execution = execution
        }
        guard isHistoryAvailable else { relatedActivity = .unavailable; return }
        relatedActivity = .loading
        relatedTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await connection.activities(query)
                guard !Task.isCancelled else { return }
                relatedActivity = .loaded(page.activities)
            } catch {
                guard !Task.isCancelled else { return }
                relatedActivity = .failed(Self.message(for: error))
            }
            notify(.inspector)
        }
    }

    func loadDiff(forFile path: String) {
        diffTask?.cancel()
        diff = .loading
        notify(.inspector)
        let service = gitDiff
        diffTask = Task { [weak self] in
            let result = await service.diff(forFile: path)
            guard !Task.isCancelled, let self else { return }
            diff = .loaded(result)
            notify(.inspector)
        }
    }

    // MARK: Commands — process control

    /// Sends exactly one signal to one exact live execution. The extension issues a fresh token
    /// and the kernel revalidates the identity; stale targets are refused, never PID-signaled.
    func control(_ operation: ControlOperation, target: ExecutionIdentity) async -> ControlFeedback {
        let key = target.process.stableID
        pendingControls.insert(key)
        notify(.inspector)
        let result = await control.perform(ControlRequest(execution: target, operation: operation))
        pendingControls.remove(key)
        let feedback = ControlFeedback(
            processKey: key,
            operation: operation,
            signalSent: result.action.signalSent,
            errorCode: result.action.errorCode,
            auditErrorCode: result.auditErrorCode,
            exitObserved: false
        )
        controlFeedback = feedback
        notify(.inspector)
        refresh()
        return feedback
    }

    // MARK: Commands — history

    func clearHistory() async -> String? {
        guard link == .connected else { return MonitorConnectionError.notConnected.errorDescription }
        do {
            try await connection.clearHistory()
            timeline = []
            timelineCursor = nil
            refresh()
            reloadTimeline()
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    /// Erases everything Sidewatch stored: the monitor's history, rules, mode, and retention
    /// settings for this account (when connected), and this app's preferences.
    func eraseAllData() async -> String? {
        guard !isErasingData else { return nil }
        isErasingData = true
        notify(.status)
        defer {
            isErasingData = false
            notify(.all)
        }
        if link == .connected {
            do {
                try await connection.eraseAllData()
            } catch {
                return Self.message(for: error)
            }
        }
        resetLocalState()
        timeline = []
        timelineCursor = nil
        refresh()
        if isHistoryAvailable { reloadTimeline() }
        return nil
    }

    /// Forgets data received from a monitor that is no longer installed.
    private func discardMonitorState() {
        monitorSnapshot = nil
        health = nil
        timeline = []
        timelineCursor = nil
        timelineState = .unavailable
        relatedActivity = .idle
        controlFeedback = nil
    }

    private func resetLocalState() {
        AppPreferences.shared.resetAll()
        timelineFilter = TimelineFilter()
        agentServicesOnly = false
        controlFeedback = nil
        clearInspector()
    }

    // MARK: Configuration

    /// Applies a configuration acknowledged by the extension (persisted selected intent).
    func applyAcknowledgedConfiguration(_ configuration: MonitorConfiguration) {
        monitorSnapshot?.configuration = configuration
        notify(.configuration)
        refresh()
    }

    // MARK: Status notices

    var notices: [StatusNotice] {
        var result: [StatusNotice] = []
        let availability = extensionManager.availability
        switch availability {
        case .notInstalled:
            result.append(.init(severity: .warning, message: String(localized: "Showing current processes and ports only. History and protection stay off until it's installed."), action: .installExtension, title: String(localized: "Monitor extension not installed")))
        case .awaitingApproval:
            result.append(.init(severity: .warning, message: String(localized: "Approve the Sidewatch monitor extension in System Settings. History and protection are inactive until it's approved."), action: .openExtensionSettings, title: String(localized: "Approval needed")))
        case .needsRestart:
            result.append(.init(severity: .warning, message: String(localized: "Restart your Mac to finish installing the Sidewatch monitor extension."), action: nil, title: String(localized: "Restart required")))
        case .notEntitled:
            result.append(.init(severity: .error, message: String(localized: "This copy of Sidewatch isn't signed with the Endpoint Security entitlement. Showing current processes and ports only."), action: nil, title: String(localized: "Monitoring unavailable")))
        case .unavailable:
            result.append(.init(severity: .error, message: extensionFailureMessage, action: .installExtension, title: String(localized: "Monitor extension unavailable")))
        case .fullDiskAccessRequired:
            result.append(.init(severity: .warning, message: String(localized: "Grant Full Disk Access to the Sidewatch monitor so it can collect activity."), action: .openFullDiskAccess))
        case .connecting, .active:
            break
        }

        if availability == .active || availability == .connecting {
            switch link {
            case .failed(_, let message):
                result.append(.init(severity: .error, message: String(localized: "Can't connect to the monitor service: \(message)"), action: .reconnect))
            case .disconnected:
                result.append(.init(severity: .warning, message: String(localized: "The monitor service disconnected. History shown may be out of date."), action: .reconnect))
            case .idle, .connecting, .connected:
                break
            }
        }

        if link == .connected, let health {
            switch health.availability {
            case .fullDiskAccessRequired:
                result.append(.init(severity: .warning, message: String(localized: "Grant Full Disk Access to the Sidewatch monitor so it can collect activity."), action: .openFullDiskAccess))
            case .notEntitled:
                result.append(.init(severity: .error, message: String(localized: "The monitor is missing the Endpoint Security entitlement. Activity isn't being collected."), action: nil))
            case .unavailable:
                result.append(.init(severity: .error, message: String(localized: "The monitor can't collect activity right now."), action: .refresh))
            case .active, .connecting, .awaitingApproval, .needsRestart, .notInstalled:
                break
            }
            if health.storageError != nil {
                result.append(.init(severity: .error, message: String(localized: "History storage is unavailable. New activity may not be saved."), action: .refresh))
            }
            if health.droppedEvents > 0 {
                result.append(.init(severity: .warning, message: String(localized: "\(Int(health.droppedEvents)) events were dropped. History is incomplete for those periods."), action: nil))
            }
        }

        if let gaps = monitorSnapshot?.gaps, !gaps.isEmpty, link == .connected {
            result.append(.init(severity: .info, message: String(localized: "\(gaps.count) collection gaps recorded. History may be incomplete around those times."), action: nil))
        }
        if let message = monitorRefreshErrorMessage, link == .connected {
            result.append(.init(severity: .error, message: String(localized: "Couldn't load monitor data: \(message)"), action: .refresh))
        }
        if let code = nativeErrorCode {
            result.append(.init(severity: .error, message: String(localized: "Couldn't read the current process list (error \(Int(code))): \(Self.errnoDescription(code))"), action: .refresh))
        }
        return result.sorted { $0.severity.rawValue > $1.severity.rawValue }
    }

    /// Why the system reports the extension as unavailable, for notices and Settings.
    var extensionFailureMessage: String {
        switch extensionManager.errorCode {
        case "codeSignature":
            return String(localized: "The monitor extension's code signature is invalid.")
        case "unsupportedLocation":
            return String(localized: "Move Sidewatch to the Applications folder to install the monitor extension.")
        case "extensionDisabled":
            return String(localized: "The Sidewatch monitor extension is installed but turned off.")
        case "systemPolicy":
            return String(localized: "System policy doesn't allow the monitor extension to be installed.")
        case "authorizationRequired":
            return String(localized: "Administrator authorization is required to install the monitor extension.")
        case let code?:
            return String(localized: "The monitor extension couldn't be activated (\(code)).")
        case nil:
            return String(localized: "The monitor extension is unavailable.")
        }
    }

    // MARK: Helpers

    static func message(for error: Error) -> String {
        if let monitor = error as? MonitorConnectionError, let description = monitor.errorDescription {
            return description
        }
        return String(localized: "The operation couldn't be completed.")
    }

    nonisolated static func errnoDescription(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
