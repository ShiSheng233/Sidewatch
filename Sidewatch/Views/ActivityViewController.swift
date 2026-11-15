import AppKit

/// Native list for the Agents, Timeline, Ports & Services, and Leftover Services pages.
/// Rows come from `ActivityViewModel`; this controller performs no collection or attribution.
final class ActivityViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private enum Item {
        case agent(AgentRow)
        case activity(ActivityRecord)
        case port(PortRow)
        case leftover(LeftoverRow)

        var signature: Int {
            switch self {
            case .agent(let row): row.hashValue
            case .activity(let record): record.hashValue
            case .port(let row): row.hashValue
            case .leftover(let row): row.hashValue
            }
        }

        var id: String {
            switch self {
            case .agent(let row): "agent:" + row.id
            case .activity(let record): "activity:\(record.id)"
            case .port(let row): "port:" + row.id
            case .leftover(let row): "leftover:" + row.id
            }
        }
    }

    private let viewModel: ActivityViewModel
    private var page: SidewatchPage = .agents
    private var items: [Item] = []
    private var observer: UUID?

    private let table = NSTableView()
    private lazy var scroll = ViewFactory.scrollingTable(table)
    private let emptyState = EmptyStateView()
    private let filterBar = NSStackView()
    private let footer = NSStackView()
    private let footerLabel = ViewFactory.label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
    private lazy var loadMoreButton = ViewFactory.button(String(localized: "Load Older Activity"), target: self, action: #selector(loadMore))

    private let portBar = NSStackView()
    private let portScopeControl = NSSegmentedControl()
    private let sessionPopup = NSPopUpButton()
    private let projectPopup = NSPopUpButton()
    private let kindPopup = NSPopUpButton()
    private let outcomePopup = NSPopUpButton()
    private lazy var clearFiltersButton = ViewFactory.button(String(localized: "Clear Filters"), target: self, action: #selector(clearFilters))
    private var popupSessions: [String] = []
    private var popupProjects: [String] = []

    init(viewModel: ActivityViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 10, height: 4)
        table.gridStyleMask = []
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        filterBar.orientation = .horizontal
        filterBar.spacing = 8
        filterBar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 4, right: 12)
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        for (popup, label) in [
            (sessionPopup, String(localized: "Filter by agent session")),
            (projectPopup, String(localized: "Filter by project")),
            (kindPopup, String(localized: "Filter by event type")),
            (outcomePopup, String(localized: "Filter by outcome"))
        ] {
            popup.target = self
            popup.action = #selector(filterChanged)
            popup.controlSize = .small
            popup.setAccessibilityLabel(label)
            popup.toolTip = label
            filterBar.addArrangedSubview(popup)
        }
        clearFiltersButton.controlSize = .small
        filterBar.addArrangedSubview(clearFiltersButton)
        filterBar.addArrangedSubview(NSView())

        portScopeControl.segmentCount = 2
        portScopeControl.setLabel(String(localized: "All Services"), forSegment: 0)
        portScopeControl.setLabel(String(localized: "Agent Services"), forSegment: 1)
        portScopeControl.selectedSegment = 0
        portScopeControl.trackingMode = .selectOne
        portScopeControl.controlSize = .small
        portScopeControl.target = self
        portScopeControl.action = #selector(portScopeChanged)
        portScopeControl.setAccessibilityLabel(String(localized: "Which services to show"))
        portBar.orientation = .horizontal
        portBar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 4, right: 12)
        portBar.addArrangedSubview(portScopeControl)
        portBar.addArrangedSubview(NSView())

        footer.orientation = .horizontal
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 6, right: 12)
        footer.translatesAutoresizingMaskIntoConstraints = false
        loadMoreButton.controlSize = .small
        footer.addArrangedSubview(footerLabel)
        footer.addArrangedSubview(NSView())
        footer.addArrangedSubview(loadMoreButton)

        let stack = NSStackView(views: [filterBar, portBar, scroll, footer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        root.addSubview(emptyState)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            filterBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            portBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            emptyState.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: scroll.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: scroll.bottomAnchor)
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = viewModel.observe { [weak self] change in
            guard let self else { return }
            if change.contains(.page) {
                show(page: viewModel.page)
            } else if change.contains(.rows) || change.contains(.timeline) || change.contains(.status) {
                reloadItems()
            }
            if change.contains(.inspector), case .none = viewModel.inspector, table.selectedRow >= 0 {
                table.deselectAll(nil)
            }
        }
        show(page: viewModel.page)
    }

    func focusTable() {
        view.window?.makeFirstResponder(table)
    }

    // MARK: Page configuration

    private func show(page: SidewatchPage) {
        self.page = page
        items = []
        for column in table.tableColumns { table.removeTableColumn(column) }
        for column in columns(for: page) { table.addTableColumn(column) }
        table.sizeToFit()
        table.setAccessibilityLabel(DisplayText.page(page))
        filterBar.isHidden = page != .timeline
        portBar.isHidden = page != .ports
        loadMoreButton.isHidden = page != .timeline
        reloadItems()
    }

    private func columns(for page: SidewatchPage) -> [NSTableColumn] {
        switch page {
        case .agents:
            return [
                ViewFactory.column("agent", title: String(localized: "Agent"), width: 130),
                ViewFactory.column("project", title: String(localized: "Project"), width: 150),
                ViewFactory.column("state", title: String(localized: "State"), width: 90),
                ViewFactory.column("started", title: String(localized: "Started"), width: 120),
                ViewFactory.column("ended", title: String(localized: "Ended"), width: 120),
                ViewFactory.column("descendants", title: String(localized: "Processes"), width: 80),
                ViewFactory.column("services", title: String(localized: "Listening"), width: 80),
                ViewFactory.column("evidence", title: String(localized: "Evidence"), width: 90)
            ]
        case .timeline:
            return [
                ViewFactory.column("time", title: String(localized: "Time"), width: 110),
                ViewFactory.column("kind", title: String(localized: "Event"), width: 100),
                ViewFactory.column("outcome", title: String(localized: "Outcome"), width: 100),
                ViewFactory.column("path", title: String(localized: "Path or Command"), width: 320),
                ViewFactory.column("process", title: String(localized: "Process"), width: 110),
                ViewFactory.column("agent", title: String(localized: "Agent"), width: 110)
            ]
        case .ports:
            return [
                ViewFactory.column("protocol", title: String(localized: "Protocol"), width: 80, minWidth: 72),
                ViewFactory.column("address", title: String(localized: "Address"), width: 130),
                ViewFactory.column("port", title: String(localized: "Port"), width: 64),
                ViewFactory.column("pid", title: String(localized: "PID"), width: 64, minWidth: 52),
                ViewFactory.column("command", title: String(localized: "Command"), width: 260),
                ViewFactory.column("project", title: String(localized: "Project"), width: 120),
                ViewFactory.column("runtime", title: String(localized: "Runtime"), width: 80),
                ViewFactory.column("attribution", title: String(localized: "Origin"), width: 140)
            ]
        case .leftovers:
            return [
                ViewFactory.column("process", title: String(localized: "Process"), width: 120),
                ViewFactory.column("pid", title: String(localized: "PID"), width: 64, minWidth: 52),
                ViewFactory.column("ports", title: String(localized: "Ports"), width: 90),
                ViewFactory.column("attribution", title: String(localized: "Agent"), width: 130),
                ViewFactory.column("ended", title: String(localized: "Agent Exited"), width: 120),
                ViewFactory.column("project", title: String(localized: "Project"), width: 120),
                ViewFactory.column("certainty", title: String(localized: "Attribution"), width: 130),
                ViewFactory.column("command", title: String(localized: "Command"), width: 240)
            ]
        case .rules, .diskAudit:
            return []
        }
    }

    // MARK: Data

    private func reloadItems() {
        let selectedID = table.selectedRow >= 0 && table.selectedRow < items.count ? items[table.selectedRow].id : nil
        let previousIDs = items.map(\.id)
        let previousSignatures = Dictionary(items.map { ($0.id, $0.signature) }, uniquingKeysWith: { first, _ in first })
        switch page {
        case .agents: items = viewModel.visibleAgents.map(Item.agent)
        case .timeline: items = viewModel.timeline.map(Item.activity)
        case .ports: items = viewModel.visiblePorts.map(Item.port)
        case .leftovers: items = viewModel.visibleLeftovers.map(Item.leftover)
        case .rules, .diskAudit: items = []
        }
        if previousIDs.isEmpty || items.isEmpty {
            table.reloadData()
        } else {
            let newIDs = items.map(\.id)
            var changed: Set<String> = []
            for item in items where previousSignatures[item.id].map({ $0 != item.signature }) ?? false {
                changed.insert(item.id)
            }
            TableDiff.apply(to: table, old: previousIDs, new: newIDs, changed: changed)
        }
        if let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        if page == .timeline { refreshFilterBar() }
        updateEmptyStateAndFooter()
    }

    private func updateEmptyStateAndFooter() {
        let searching = !viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        let empty = items.isEmpty
        defer {
            if emptyState.isHidden != !empty {
                Motion.fade(emptyState)
                emptyState.isHidden = !empty
            }
        }

        switch page {
        case .agents:
            if searching {
                emptyState.show(title: String(localized: "No Matching Agents"), detail: String(localized: "No agent matches “\(viewModel.searchText)”."))
            } else if viewModel.isHistoryAvailable {
                emptyState.show(title: String(localized: "No Agents"), detail: String(localized: "Agent sessions appear here when a recognized agent CLI runs."))
            } else {
                emptyState.show(title: String(localized: "No Running Agents"), detail: String(localized: "No recognized agent is running. Agent history requires the monitor extension."))
            }
            footerLabel.stringValue = String(localized: "\(items.count) agents")
        case .timeline:
            switch viewModel.timelineState {
            case .unavailable:
                emptyState.show(title: String(localized: "History Unavailable"), detail: String(localized: "The timeline requires a connection to the monitor extension."))
            case .failed(let message):
                emptyState.show(title: String(localized: "Couldn't Load Activity"), detail: message)
            case .loading where empty:
                emptyState.show(title: String(localized: "Loading…"), detail: "")
            default:
                emptyState.show(
                    title: String(localized: "No Activity"),
                    detail: searching || viewModel.timelineFilter != TimelineFilter()
                        ? String(localized: "No activity matches the current search and filters.")
                        : String(localized: "Recorded agent activity appears here.")
                )
            }
            footerLabel.stringValue = String(localized: "\(items.count) events loaded")
            loadMoreButton.isEnabled = viewModel.timelineState == .idle
            loadMoreButton.title = viewModel.timelineState == .complete
                ? String(localized: "All Activity Loaded")
                : String(localized: "Load Older Activity")
        case .ports:
            emptyState.show(
                title: searching ? String(localized: "No Matching Ports") : String(localized: "No Listening Ports"),
                detail: searching
                    ? String(localized: "No port, command, or project matches “\(viewModel.searchText)”.")
                    : String(localized: "No TCP listeners or UDP bindings were found for processes you can inspect.")
            )
            footerLabel.stringValue = String(localized: "\(items.count) endpoints")
        case .leftovers:
            if !viewModel.isHistoryAvailable {
                emptyState.show(title: String(localized: "History Unavailable"), detail: String(localized: "Leftover services are identified from recorded agent exits, which requires the monitor extension."))
            } else {
                emptyState.show(
                    title: searching ? String(localized: "No Matching Services") : String(localized: "No Leftover Services"),
                    detail: String(localized: "Processes still running after their agent exited appear here. Unknown origins and missed exits aren't listed.")
                )
            }
            footerLabel.stringValue = String(localized: "\(items.count) leftover processes")
        case .rules, .diskAudit:
            break
        }
        footerLabel.setAccessibilityLabel(footerLabel.stringValue)
    }

    // MARK: Timeline filters

    /// Most recent sessions offered in the Agent filter; older ones stay reachable from the
    /// inspector's Show in Timeline.
    private static let sessionChoiceLimit = 100

    private func refreshFilterBar() {
        let filter = viewModel.timelineFilter

        var sessions = Array(viewModel.timelineSessions.prefix(Self.sessionChoiceLimit))
        if let sessionID = filter.sessionID, !sessions.contains(where: { $0.id == sessionID }),
           let selected = viewModel.timelineSessions.first(where: { $0.id == sessionID }) {
            sessions.append(selected)
        }
        popupSessions = sessions.map(\.id)
        Self.fill(sessionPopup, titles: [String(localized: "All Agents")] + sessions.map { session in
            String(localized: "\(session.agent.name) — \(DisplayText.project(session.project)) — \(DisplayText.dateTime(session.startedAt))")
        })
        let sessionIndex = filter.sessionID.flatMap { popupSessions.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        if sessionPopup.indexOfSelectedItem != sessionIndex { sessionPopup.selectItem(at: sessionIndex) }

        let projects = viewModel.timelineProjects
        popupProjects = projects.map(\.root)
        if Self.fill(projectPopup, titles: [String(localized: "All Projects")] + projects.map(\.name)) {
            for (index, project) in projects.enumerated() { projectPopup.item(at: index + 1)?.toolTip = project.root }
        }
        let projectIndex = filter.projectRoot.flatMap { popupProjects.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        if projectPopup.indexOfSelectedItem != projectIndex { projectPopup.selectItem(at: projectIndex) }

        Self.fill(kindPopup, titles: [String(localized: "All Events")] + ActivityKind.allCases.map(DisplayText.kind))
        let kindIndex = filter.kind.flatMap { ActivityKind.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        if kindPopup.indexOfSelectedItem != kindIndex { kindPopup.selectItem(at: kindIndex) }

        Self.fill(outcomePopup, titles: TimelineOutcomeFilter.allCases.map(DisplayText.outcomeFilter))
        let outcomeIndex = TimelineOutcomeFilter.allCases.firstIndex(of: filter.outcome) ?? 0
        if outcomePopup.indexOfSelectedItem != outcomeIndex { outcomePopup.selectItem(at: outcomeIndex) }

        clearFiltersButton.isEnabled = filter != TimelineFilter()
        let enabled = viewModel.isHistoryAvailable
        for popup in [sessionPopup, projectPopup, kindPopup, outcomePopup] where popup.isEnabled != enabled {
            popup.isEnabled = enabled
        }
    }

    /// Replaces a popup's items only when they changed, so a refresh never disturbs an open menu.
    @discardableResult
    private static func fill(_ popup: NSPopUpButton, titles: [String]) -> Bool {
        guard popup.itemTitles != titles else { return false }
        popup.removeAllItems()
        // addItems(withTitles:) drops duplicate titles; each session needs its own row.
        for title in titles {
            popup.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        }
        return true
    }

    @objc private func filterChanged(_ sender: NSPopUpButton) {
        var filter = viewModel.timelineFilter
        filter.execution = nil
        let sessionIndex = sessionPopup.indexOfSelectedItem
        filter.sessionID = sessionIndex > 0 && sessionIndex - 1 < popupSessions.count ? popupSessions[sessionIndex - 1] : nil
        let projectIndex = projectPopup.indexOfSelectedItem
        filter.projectRoot = projectIndex > 0 && projectIndex - 1 < popupProjects.count ? popupProjects[projectIndex - 1] : nil
        let kindIndex = kindPopup.indexOfSelectedItem
        filter.kind = kindIndex > 0 ? ActivityKind.allCases[kindIndex - 1] : nil
        let outcomeIndex = max(0, outcomePopup.indexOfSelectedItem)
        filter.outcome = TimelineOutcomeFilter.allCases[outcomeIndex]
        viewModel.setTimelineFilter(filter)
    }

    @objc private func portScopeChanged() {
        viewModel.setAgentServicesOnly(portScopeControl.selectedSegment == 1)
    }

    @objc private func clearFilters() {
        viewModel.setTimelineFilter(TimelineFilter())
    }

    @objc private func loadMore() {
        viewModel.loadMoreTimeline()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue, row < items.count else { return nil }
        let cell = ViewFactory.textCell(in: tableView, identifier: column)
        switch items[row] {
        case .agent(let agent): configureAgent(cell, agent, column)
        case .activity(let activity): configureActivity(cell, activity, column)
        case .port(let port): configurePort(cell, port, column)
        case .leftover(let leftover): configureLeftover(cell, leftover, column)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldTypeSelectFor event: NSEvent, withCurrentSearch searchString: String?) -> Bool { true }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard row < items.count else { return nil }
        switch items[row] {
        case .agent(let agent): return agent.agentName
        case .activity(let activity): return activity.sourcePath
        case .port(let port): return String(port.endpoint.port)
        case .leftover(let leftover): return DisplayText.executableName(leftover.execution)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < items.count else {
            viewModel.select(.none)
            return
        }
        switch items[row] {
        case .agent(let agent): viewModel.select(.agent(agent))
        case .activity(let activity): viewModel.select(.activity(activity))
        case .port(let port): viewModel.select(.port(port))
        case .leftover(let leftover): viewModel.select(.leftover(leftover))
        }
        if page == .timeline, row >= items.count - 20 { viewModel.loadMoreTimeline() }
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < items.count else { return }
        switch items[row] {
        case .agent(let agent):
            if let sessionID = agent.sessionID { viewModel.showTimeline(sessionID: sessionID) }
        case .activity(let activity):
            if let path = activity.targetPath ?? activity.sourcePath { revealInFinder(path) }
        case .port, .leftover:
            break
        }
    }

    // MARK: Cells

    private func configureAgent(_ cell: NSTableCellView, _ row: AgentRow, _ column: String) {
        switch column {
        case "agent":
            ViewFactory.configure(cell, text: row.agentName)
        case "project":
            ViewFactory.configure(cell, text: DisplayText.project(row.project), color: row.project == nil ? .tertiaryLabelColor : .labelColor, tooltip: row.project?.root)
        case "state":
            let color: NSColor = row.state == .running ? .systemGreen : (row.state == .unknown ? .systemOrange : .tertiaryLabelColor)
            ViewFactory.configure(cell, text: DisplayText.runState(row.state), color: row.state == .exited ? .secondaryLabelColor : .labelColor,
                                  symbol: "circle.fill", symbolColor: color, symbolSize: 7)
        case "started":
            ViewFactory.configure(cell, text: DisplayText.dateTime(row.startedAt), color: .secondaryLabelColor, numeric: true)
        case "ended":
            ViewFactory.configure(cell, text: row.endedAt.map(DisplayText.dateTime) ?? "—", color: row.endedAt == nil ? .tertiaryLabelColor : .secondaryLabelColor, numeric: true)
        case "descendants":
            ViewFactory.configure(cell, text: row.descendantCount.formatted(), color: row.descendantCount == 0 ? .tertiaryLabelColor : .labelColor,
                                  numeric: true, tooltip: String(localized: "\(row.runningDescendantCount) running"))
        case "services":
            ViewFactory.configure(cell, text: row.endpointCount.formatted(), color: row.endpointCount == 0 ? .tertiaryLabelColor : .labelColor, numeric: true)
        case "evidence":
            ViewFactory.configure(cell, text: DisplayText.evidence(row.evidence), color: .tertiaryLabelColor)
        default:
            ViewFactory.configure(cell, text: "")
        }
    }

    private func configureActivity(_ cell: NSTableCellView, _ activity: ActivityRecord, _ column: String) {
        switch column {
        case "time":
            ViewFactory.configure(cell, text: DisplayText.dateTime(activity.occurredAt), color: .secondaryLabelColor, numeric: true)
        case "kind":
            ViewFactory.configure(cell, text: DisplayText.kind(activity.kind), color: activity.kind == .gap ? .systemOrange : .labelColor)
        case "outcome":
            let decided = activity.response != .notApplicable
            ViewFactory.configure(cell, text: DisplayText.outcome(activity), color: decided ? .labelColor : .tertiaryLabelColor,
                                  symbol: decided ? "circle.fill" : nil, symbolColor: DisplayText.outcomeColor(activity), symbolSize: 7)
        case "path":
            let text: String
            if activity.kind == .rename, let source = activity.sourcePath, let target = activity.targetPath {
                text = String(localized: "\(source) → \(target)")
            } else if let path = activity.targetPath ?? activity.sourcePath {
                text = path
            } else if activity.kind == .exec || activity.kind == .fork || activity.kind == .exit,
                      let execution = activity.execution, let record = viewModel.record(for: execution) {
                text = DisplayText.commandSummary(record)
            } else if activity.kind == .gap {
                text = activity.detail.map(DisplayText.gapReason) ?? DisplayText.gapReason("")
            } else {
                text = "—"
            }
            ViewFactory.configure(cell, text: text, monospaced: true, tooltip: text)
        case "process":
            let record = activity.execution.flatMap(viewModel.record(for:))
            let pid = activity.execution.map { String($0.process.pid) } ?? ""
            ViewFactory.configure(cell, text: record.map { DisplayText.executableName($0) } ?? pid, tooltip: pid.isEmpty ? nil : String(localized: "PID \(pid)"))
        case "agent":
            let names = viewModel.agentNames(for: activity)
            ViewFactory.configure(cell, text: names.isEmpty ? "—" : names.formatted(.list(type: .and)), color: names.isEmpty ? .secondaryLabelColor : .labelColor)
        default:
            ViewFactory.configure(cell, text: "")
        }
    }

    private func configurePort(_ cell: NSTableCellView, _ row: PortRow, _ column: String) {
        switch column {
        case "protocol":
            ViewFactory.configure(cell, text: DisplayText.transport(row.endpoint.transport), color: .secondaryLabelColor)
        case "address":
            ViewFactory.configure(cell, text: DisplayText.address(row.endpoint), monospaced: true)
        case "port":
            ViewFactory.configure(cell, text: String(row.endpoint.port), numeric: true)
        case "pid":
            ViewFactory.configure(cell, text: String(row.endpoint.execution.process.pid), color: .secondaryLabelColor, numeric: true)
        case "command":
            ViewFactory.configure(cell, text: row.execution.map(DisplayText.commandSummary) ?? String(localized: "Unavailable"), color: row.execution == nil ? .secondaryLabelColor : .labelColor, monospaced: true, tooltip: row.execution?.command)
        case "project":
            ViewFactory.configure(cell, text: DisplayText.project(row.project), color: row.project == nil ? .tertiaryLabelColor : .labelColor, tooltip: row.project?.root)
        case "runtime":
            ViewFactory.configure(cell, text: DisplayText.runtime(row.runtime), color: row.runtime == .unknown ? .tertiaryLabelColor : .labelColor)
        case "attribution":
            let uncertain = row.attributions.contains { $0.evidence != .observed }
            ViewFactory.configure(
                cell,
                text: DisplayText.attribution(row.attributions),
                color: row.attributions.isEmpty ? .tertiaryLabelColor : .labelColor,
                tooltip: row.attributions.count > 1
                    ? String(localized: "Shared by more than one agent")
                    : (uncertain && !row.attributions.isEmpty ? String(localized: "Inferred, not directly observed") : nil)
            )
        default:
            ViewFactory.configure(cell, text: "")
        }
    }

    private func configureLeftover(_ cell: NSTableCellView, _ row: LeftoverRow, _ column: String) {
        switch column {
        case "process":
            ViewFactory.configure(cell, text: DisplayText.executableName(row.execution))
        case "pid":
            ViewFactory.configure(cell, text: String(row.execution.identity.process.pid), color: .secondaryLabelColor, numeric: true)
        case "ports":
            let ports = row.endpoints.map { String($0.port) }
            ViewFactory.configure(cell, text: ports.isEmpty ? "—" : ports.formatted(.list(type: .and)), color: ports.isEmpty ? .tertiaryLabelColor : .labelColor, numeric: true)
        case "attribution":
            ViewFactory.configure(cell, text: DisplayText.attribution(row.attributions))
        case "ended":
            ViewFactory.configure(cell, text: row.agentEndedAt.map(DisplayText.dateTime) ?? "—", color: .secondaryLabelColor, numeric: true)
        case "project":
            ViewFactory.configure(cell, text: DisplayText.project(row.project), color: row.project == nil ? .tertiaryLabelColor : .labelColor, tooltip: row.project?.root)
        case "certainty":
            let text: String
            if row.isShared && row.isUncertain {
                text = String(localized: "Shared, uncertain")
            } else if row.isShared {
                text = String(localized: "Shared")
            } else if row.isUncertain {
                text = String(localized: "Uncertain")
            } else {
                text = String(localized: "Observed")
            }
            ViewFactory.configure(cell, text: text, color: row.isShared || row.isUncertain ? .labelColor : .tertiaryLabelColor,
                                  symbol: row.isShared || row.isUncertain ? "circle.fill" : nil, symbolColor: .systemOrange, symbolSize: 7)
        case "command":
            ViewFactory.configure(cell, text: DisplayText.commandSummary(row.execution), monospaced: true, tooltip: row.execution.command)
        default:
            ViewFactory.configure(cell, text: "")
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, row < items.count else { return }
        switch items[row] {
        case .agent(let agent):
            if let sessionID = agent.sessionID {
                menu.addItem(item(String(localized: "Show in Timeline"), #selector(menuShowTimeline(_:)), sessionID))
            }
            if !agent.command.isEmpty {
                menu.addItem(item(String(localized: "Copy Command"), #selector(menuCopy(_:)), agent.command))
            }
            if let root = agent.project?.root {
                menu.addItem(item(String(localized: "Copy Project Path"), #selector(menuCopy(_:)), root))
                menu.addItem(item(String(localized: "Reveal Project in Finder"), #selector(menuReveal(_:)), root))
            }
        case .activity(let activity):
            if let path = activity.targetPath ?? activity.sourcePath {
                menu.addItem(item(String(localized: "Reveal in Finder"), #selector(menuReveal(_:)), path))
                menu.addItem(item(String(localized: "Copy Path"), #selector(menuCopy(_:)), path))
            }
            if let execution = activity.execution {
                menu.addItem(item(String(localized: "Show Activity from Same Process"), #selector(menuShowExecution(_:)), execution))
            }
        case .port(let port):
            addControlItems(to: menu, target: port.controlTarget, record: port.execution)
            menu.addItem(item(String(localized: "Copy Address"), #selector(menuCopy(_:)), "\(DisplayText.address(port.endpoint)):\(port.endpoint.port)"))
            if let command = port.execution?.command {
                menu.addItem(item(String(localized: "Copy Command"), #selector(menuCopy(_:)), command))
            }
        case .leftover(let leftover):
            addControlItems(to: menu, target: leftover.controlTarget, record: leftover.execution)
            menu.addItem(item(String(localized: "Copy Command"), #selector(menuCopy(_:)), leftover.execution.command))
        }
    }

    private func addControlItems(to menu: NSMenu, target: ExecutionIdentity?, record: ExecutionRecord?) {
        let stop = item(String(localized: "Stop…"), #selector(menuStop(_:)), ControlMenuPayload(target: target, record: record, operation: .stop))
        let force = item(String(localized: "Force Quit…"), #selector(menuStop(_:)), ControlMenuPayload(target: target, record: record, operation: .forceQuit))
        stop.isEnabled = target != nil
        force.isEnabled = target != nil
        if target == nil {
            stop.toolTip = String(localized: "Stopping requires the monitor's live identity for this process.")
            force.toolTip = stop.toolTip
        }
        menu.addItem(stop)
        menu.addItem(force)
        menu.addItem(.separator())
    }

    private func item(_ title: String, _ action: Selector, _ payload: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = payload
        return item
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String { ViewFactory.copyToPasteboard(text) }
    }

    @objc private func menuReveal(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { revealInFinder(path) }
    }

    @objc private func menuShowTimeline(_ sender: NSMenuItem) {
        if let sessionID = sender.representedObject as? String { viewModel.showTimeline(sessionID: sessionID) }
    }

    @objc private func menuShowExecution(_ sender: NSMenuItem) {
        if let execution = sender.representedObject as? ExecutionIdentity { viewModel.showTimeline(execution: execution) }
    }

    @objc private func menuStop(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ControlMenuPayload, let target = payload.target, let window = view.window else { return }
        ProcessControlUI.confirmAndPerform(payload.operation, target: target, record: payload.record, viewModel: viewModel, window: window)
    }

    private func revealInFinder(_ path: String) {
        ProcessControlUI.reveal(path, in: view.window)
    }
}

private struct ControlMenuPayload {
    var target: ExecutionIdentity?
    var record: ExecutionRecord?
    var operation: ControlOperation
}
