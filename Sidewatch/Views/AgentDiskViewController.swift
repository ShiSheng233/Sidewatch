import AppKit

/// Agent Disk page: audited temporary artifacts grouped under the agent sessions that wrote
/// them, cleanup policy, and per-file provenance. All data comes from `AgentDiskViewModel`;
/// this controller only renders and confirms actions.
final class AgentDiskViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSplitViewDelegate, NSMenuDelegate {
    private let activity: ActivityViewModel
    private let viewModel: AgentDiskViewModel
    /// Called when the header summary or page notices change, so the content container can
    /// update its subtitle and notice bar.
    var onSummaryChange: (() -> Void)?

    private let outline = NSOutlineView()
    private lazy var scroll = ViewFactory.scrollingTable(outline)
    private let emptyState = EmptyStateView()
    private let splitView = NSSplitView()
    private let bottomPane = NSView()
    private let policyBar = NSStackView()
    private let policyContainer = NSStackView()
    private let statusRow = NSStackView()
    private let statusLabel = ViewFactory.label("", font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                                                color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator()
    /// Large spinner above the empty state while the first scan runs.
    private let scanSpinner: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .regular
        indicator.isDisplayedWhenStopped = false
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()
    private lazy var issuesButton: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(showIssues(_:)))
        button.bezelStyle = .inline
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.contentTintColor = .systemOrange
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.isHidden = true
        return button
    }()
    private lazy var toggleDetailButton: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(toggleDetailPane(_:)))
        button.bezelStyle = .toolbar
        button.isBordered = false
        button.controlSize = .small
        button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }()
    private var detailExpandedHeight: CGFloat = 190
    private static let detailCollapsedKey = "Sidewatch.agentDisk.detailCollapsed"
    private lazy var helpButton: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(showHelp(_:)))
        button.bezelStyle = .helpButton
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel(String(localized: "How cleanup works"))
        return button
    }()
    private var renderedDetail: String?
    private let detailScroll = NSScrollView()
    private let detailDocument = DiskDetailDocumentView()
    private let detailStack = NSStackView()

    private let idlePopup = NSPopUpButton()
    private lazy var autoCheckbox: NSButton = {
        let button = NSButton(checkboxWithTitle: String(localized: "Clean eligible files automatically"),
                              target: self, action: #selector(toggleAutomaticCleanup))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = String(localized: "Checks once a minute while Sidewatch is open and deletes files marked Eligible.")
        return button
    }()
    private lazy var cleanButton = ViewFactory.button(String(localized: "Clean Eligible…"), symbol: "trash",
                                                      target: self, action: #selector(cleanEligible))
    private lazy var scanButton = ViewFactory.button(String(localized: "Scan"), symbol: "arrow.clockwise",
                                                     target: self, action: #selector(scanNow))

    private var nodes: [DiskTreeNode] = []
    private var treeSignature = ""
    /// Selected row identity: a session log, or a file under a specific session log.
    private var selectedKey: String?
    /// Sessions the user expanded. Seeded with the largest sessions on the first scan.
    private var expandedLogs: Set<String> = []
    private var seededExpansion = false
    private var updatingSelection = false
    private var observer: UUID?
    private var activityObserver: UUID?

    init(activity: ActivityViewModel, viewModel: AgentDiskViewModel) {
        self.activity = activity
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        // Audit while the app is open; the page does not have to be visible for cleanup to run.
        viewModel.start()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        configureOutline()
        configurePolicyBar()
        configureStatus()
        configureDetail()
        configureSplitView()

        let statusTopRule = NSBox()
        statusTopRule.boxType = .separator
        statusTopRule.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [policyContainer, splitView, statusTopRule, statusRow])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(stack)
        root.addSubview(emptyState)
        root.addSubview(scanSpinner)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            splitView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            emptyState.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: scroll.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            scanSpinner.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            scanSpinner.bottomAnchor.constraint(equalTo: emptyState.centerYAnchor, constant: -34)
        ])
        stack.pinArrangedWidths()
        splitView.setContentHuggingPriority(.init(1), for: .vertical)
        splitView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = viewModel.observe { [weak self] change in self?.apply(change) }
        activityObserver = activity.observe { [weak self] change in
            guard let self, change.contains(.rows) else { return }
            self.viewModel.setSearchText(self.activity.searchText)
        }
        viewModel.setSearchText(activity.searchText)
        syncPolicy()
        reloadItems()
        renderDetail()
    }

    // MARK: Configuration

    private func configureOutline() {
        outline.usesAlternatingRowBackgroundColors = false
        outline.allowsMultipleSelection = false
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = true
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.rowHeight = 26
        outline.intercellSpacing = NSSize(width: 10, height: 4)
        outline.indentationPerLevel = 18
        outline.gridStyleMask = []
        outline.style = .inset
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.setAccessibilityLabel(String(localized: "Agent sessions and their temporary files"))
        let name = ViewFactory.column("name", title: String(localized: "Session / File"), width: 380, minWidth: 200)
        outline.addTableColumn(name)
        outline.outlineTableColumn = name
        outline.addTableColumn(ViewFactory.column("size", title: String(localized: "Size"), width: 90, minWidth: 72, alignment: .right))
        outline.addTableColumn(ViewFactory.column("status", title: String(localized: "Status"), width: 120, minWidth: 90))
        outline.addTableColumn(ViewFactory.column("activity", title: String(localized: "Last Activity"), width: 150, minWidth: 110))
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
    }

    private func configurePolicyBar() {
        let idleLabel = ViewFactory.label(String(localized: "Idle timeout"),
                                          font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                                          color: .secondaryLabelColor)
        idlePopup.controlSize = .small
        idlePopup.addItems(withTitles: AgentDiskViewModel.idleHourChoices.map(DisplayText.idleTimeout))
        idlePopup.target = self
        idlePopup.action = #selector(idleTimeoutChanged)
        idlePopup.setAccessibilityLabel(String(localized: "Idle timeout before automatic cleanup"))
        idlePopup.toolTip = String(localized: "Time without new log activity before files become eligible.")

        policyBar.orientation = .horizontal
        policyBar.spacing = 10
        policyBar.alignment = .centerY
        policyBar.translatesAutoresizingMaskIntoConstraints = false
        policyBar.addArrangedSubview(autoCheckbox)
        policyBar.addArrangedSubview(idleLabel)
        policyBar.addArrangedSubview(idlePopup)
        policyBar.addArrangedSubview(helpButton)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        policyBar.addArrangedSubview(spacer)
        policyBar.addArrangedSubview(cleanButton)
        policyBar.addArrangedSubview(scanButton)
        policyBar.setCustomSpacing(8, after: cleanButton)
        // At the minimum width (or with long translations) the label goes first; the popup's
        // accessibility label still names the setting.
        policyBar.setVisibilityPriority(.detachOnlyIfNecessary, for: idleLabel)

        policyContainer.orientation = .vertical
        policyContainer.spacing = 6
        policyContainer.alignment = .leading
        policyContainer.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 4, right: 20)
        policyContainer.detachesHiddenViews = true
        policyContainer.translatesAutoresizingMaskIntoConstraints = false
        policyContainer.addArrangedSubview(policyBar)
        policyContainer.pinArrangedWidths()
    }

    private func configureStatus() {
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true

        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .centerY
        statusRow.edgeInsets = NSEdgeInsets(top: 5, left: 20, bottom: 5, right: 16)
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.addArrangedSubview(spinner)
        statusRow.addArrangedSubview(statusLabel)
        statusRow.addArrangedSubview(NSView())
        statusRow.addArrangedSubview(issuesButton)
        statusRow.addArrangedSubview(toggleDetailButton)
    }

    private func configureSplitView() {
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        bottomPane.translatesAutoresizingMaskIntoConstraints = false
        bottomPane.addSubview(detailScroll)
        NSLayoutConstraint.activate([
            detailScroll.topAnchor.constraint(equalTo: bottomPane.topAnchor),
            detailScroll.leadingAnchor.constraint(equalTo: bottomPane.leadingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: bottomPane.trailingAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: bottomPane.bottomAnchor)
        ])
        splitView.addArrangedSubview(scroll)
        splitView.addArrangedSubview(bottomPane)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        let preferredHeight = bottomPane.heightAnchor.constraint(equalToConstant: detailExpandedHeight)
        preferredHeight.priority = .defaultLow
        preferredHeight.isActive = true
        splitView.autosaveName = "Sidewatch.agentDisk.split"
        if UserDefaults.standard.bool(forKey: Self.detailCollapsedKey) {
            bottomPane.isHidden = true
        }
        updateToggleDetailButton()
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === bottomPane
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 120)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(120, splitView.bounds.height - 110)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        let collapsed = splitView.isSubviewCollapsed(bottomPane) || bottomPane.isHidden || bottomPane.frame.height < 1
        if !collapsed, bottomPane.frame.height >= 110 {
            detailExpandedHeight = bottomPane.frame.height
        }
        UserDefaults.standard.set(collapsed, forKey: Self.detailCollapsedKey)
        updateToggleDetailButton()
    }

    @objc private func toggleDetailPane(_ sender: Any?) {
        let collapsed = splitView.isSubviewCollapsed(bottomPane) || bottomPane.isHidden || bottomPane.frame.height < 1
        let targetHeight = max(130, min(detailExpandedHeight, splitView.bounds.height - 120))
        if !collapsed {
            detailExpandedHeight = max(130, bottomPane.frame.height)
            bottomPane.isHidden = true
        } else {
            bottomPane.isHidden = false
        }
        splitView.adjustSubviews()
        if collapsed {
            splitView.setPosition(splitView.bounds.height - targetHeight, ofDividerAt: 0)
        }
        UserDefaults.standard.set(!collapsed, forKey: Self.detailCollapsedKey)
        updateToggleDetailButton()
    }

    private func updateToggleDetailButton() {
        let collapsed = splitView.isSubviewCollapsed(bottomPane) || bottomPane.isHidden
        toggleDetailButton.image = NSImage(
            systemSymbolName: "rectangle.bottomthird.inset.filled",
            accessibilityDescription: collapsed ? String(localized: "Show Details Area") : String(localized: "Hide Details Area")
        )
        toggleDetailButton.contentTintColor = collapsed ? .secondaryLabelColor : .controlAccentColor
        toggleDetailButton.toolTip = collapsed ? String(localized: "Show the Details Area") : String(localized: "Hide the Details Area")
        toggleDetailButton.setAccessibilityLabel(toggleDetailButton.toolTip)
    }

    private func configureDetail() {
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.documentView = detailDocument
        detailScroll.setAccessibilityLabel(String(localized: "Selected file details"))

        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 7
        detailStack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 12, right: 20)
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailDocument.translatesAutoresizingMaskIntoConstraints = false
        detailDocument.addSubview(detailStack)
        NSLayoutConstraint.activate([
            detailStack.topAnchor.constraint(equalTo: detailDocument.topAnchor),
            detailStack.leadingAnchor.constraint(equalTo: detailDocument.leadingAnchor),
            detailStack.trailingAnchor.constraint(equalTo: detailDocument.trailingAnchor),
            detailStack.bottomAnchor.constraint(equalTo: detailDocument.bottomAnchor),
            detailDocument.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
            detailDocument.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor),
            detailDocument.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor)
        ])
    }

    // MARK: Observation

    private func apply(_ change: AgentDiskChange) {
        if change.contains(.policy) { syncPolicy() }
        if change.contains(.report) {
            reloadItems()
        } else if change.contains(.state) {
            updateEmptyState()
        }
        updateStatus()
        updateControls()
        updateSummary()
    }

    // MARK: Commands

    func scan() {
        viewModel.scan()
    }

    /// Snapshot harness support, bounded by the view model.
    func awaitInitialScan() async {
        await viewModel.awaitInitialScan()
    }

    @objc private func scanNow() {
        viewModel.scan()
    }

    @objc private func toggleAutomaticCleanup() {
        guard !viewModel.cleanupSuppressed else { return }
        viewModel.setAutomaticCleanup(autoCheckbox.state == .on)
    }

    @objc private func idleTimeoutChanged() {
        let index = idlePopup.indexOfSelectedItem
        guard index >= 0, index < AgentDiskViewModel.idleHourChoices.count else { return }
        viewModel.setIdleHours(AgentDiskViewModel.idleHourChoices[index])
    }

    @objc private func showHelp(_ sender: NSButton) {
        let text = ViewFactory.label(
            String(localized: "Files become eligible after the agent process exits (and isn't resumed), or after the session log stays idle for the timeout. Shared files wait for all sessions, and open files wait until closed.\n\nFiles marked Review are never deleted."),
            font: .systemFont(ofSize: NSFont.smallSystemFontSize + 1), wraps: true
        )
        text.preferredMaxLayoutWidth = 320
        let folders = ViewFactory.button(String(localized: "Session Folders…"), symbol: "folder",
                                         target: self, action: #selector(showSessionFolders))
        folders.controlSize = .small
        let content = NSViewController()
        let container = NSView()
        container.addSubview(text)
        container.addSubview(folders)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            text.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            text.widthAnchor.constraint(equalToConstant: 320),
            folders.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 10),
            folders.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            folders.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
        content.view = container
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !Motion.reduceMotion
        popover.contentViewController = content
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func showSessionFolders() {
        AppDelegate.shared?.showSettings(.agentDisk)
    }

    @objc private func cleanEligible() {
        guard let window = view.window else { return }
        // Capture exactly what the user is looking at, search filter included. The engine
        // rescans, but may only delete these reviewed paths; a file that becomes eligible
        // meanwhile, or that the search hides, is kept.
        let eligible = viewModel.visibleItems.filter { $0.state == .eligible }
        guard !eligible.isEmpty else { return }
        let paths = Set(eligible.map(\.path))
        let bytes = eligible.reduce(Int64(0)) { $0 + $1.bytes }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete \(eligible.count) Eligible Files?")
        alert.informativeText = String(localized: "Frees \(DisplayText.bytes(bytes)). Sidewatch rescans first and skips any file that changed. This can't be undone.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                self?.viewModel.cleanEligible(allowedPaths: paths)
            }
        }
    }

    // MARK: Data

    private func reloadItems() {
        let groups = viewModel.visibleGroups
        let searching = !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !seededExpansion, !groups.isEmpty {
            // First results: open the largest sessions so files are visible without a click.
            seededExpansion = true
            expandedLogs.formUnion(groups.prefix(3).map(\.id))
        }
        let signature = groups.map { group in
            group.id + "\u{1E}" + String(group.bytes) + group.items.map { self.signature($0) }.joined(separator: "\u{1D}")
        }.joined(separator: "\u{1C}") + (searching ? "\u{1B}search" : "")
        defer {
            restoreSelection()
            updateEmptyState()
            renderDetail()
        }
        guard signature != treeSignature else { return }
        let wasEmpty = nodes.isEmpty
        let structureChanged = Set(nodes.map(\.key)) != Set(groups.map { DiskTreeNode.sessionKey($0.id) })
        treeSignature = signature
        nodes = groups.map(DiskTreeNode.init(group:))
        // Sessions appearing or leaving cross-fade the list; value-only refreshes reload in place
        // so the minute timer doesn't flash the rows.
        if structureChanged, !wasEmpty, view.window != nil { Motion.fade(scroll, duration: Motion.standard) }
        outline.reloadData()
        for node in nodes where searching || expandedLogs.contains(node.logPath) {
            outline.expandItem(node)
        }
        if wasEmpty, !nodes.isEmpty { revealRows() }
    }

    private func signature(_ item: AgentDiskItem) -> String {
        [
            item.path, String(item.bytes), item.state.rawValue, item.reason,
            String(item.lastActivityAt.timeIntervalSince1970),
            String(item.eligibleAt?.timeIntervalSince1970 ?? -1),
            item.agents.joined(separator: "\u{1F}"),
            item.tools.joined(separator: "\u{1F}"),
            item.logPaths.joined(separator: "\u{1F}"),
            item.sessionIDs.joined(separator: "\u{1F}")
        ].joined(separator: "\u{1E}")
    }

    /// A search that hides the selected row only deselects it, so clearing the search brings
    /// the selection back.
    private func restoreSelection() {
        updatingSelection = true
        defer { updatingSelection = false }
        guard let selectedKey, let node = node(forKey: selectedKey) else {
            outline.deselectAll(nil)
            return
        }
        if let parent = node.parent { outline.expandItem(parent) }
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func node(forKey key: String) -> DiskTreeNode? {
        for session in nodes {
            if session.key == key { return session }
            if let child = session.children.first(where: { $0.key == key }) { return child }
        }
        return nil
    }

    private var selectedNode: DiskTreeNode? {
        selectedKey.flatMap(node(forKey:))
    }

    private var clickedNode: DiskTreeNode? {
        let row = outline.clickedRow
        guard row >= 0 else { return nil }
        return outline.item(atRow: row) as? DiskTreeNode
    }

    /// Cross-fades the empty state instead of swapping it; the hide completes only if the list
    /// still has rows when the fade ends.
    private func setEmptyStateVisible(_ visible: Bool) {
        if visible {
            guard emptyState.isHidden || emptyState.alphaValue < 1 else { return }
            if emptyState.isHidden {
                emptyState.alphaValue = 0
                emptyState.isHidden = false
            }
            Motion.animate(Motion.standard) { self.emptyState.animator().alphaValue = 1 }
        } else {
            guard !emptyState.isHidden else { return }
            Motion.animate(Motion.quick, { self.emptyState.animator().alphaValue = 0 }) { [weak self] in
                guard let self, !self.nodes.isEmpty else { return }
                self.emptyState.isHidden = true
            }
        }
    }

    /// First rows after an empty list slide in with a short stagger, top to bottom.
    private func revealRows() {
        guard view.window != nil, !Motion.reduceMotion else { return }
        outline.layoutSubtreeIfNeeded()
        let visible = outline.rows(in: outline.visibleRect)
        for (offset, row) in (visible.location..<NSMaxRange(visible)).prefix(16).enumerated() {
            guard let rowView = outline.rowView(atRow: row, makeIfNecessary: false) else { continue }
            Motion.entrance(rowView, delay: Double(offset) * 0.025)
        }
    }

    private func updateEmptyState() {
        let searching = !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let empty = nodes.isEmpty
        defer { setEmptyStateVisible(empty) }
        let firstScan = viewModel.isScanning && !viewModel.hasScanned
        if firstScan {
            scanSpinner.alphaValue = 1
            scanSpinner.startAnimation(nil)
        } else if scanSpinner.alphaValue > 0 {
            Motion.animate(Motion.quick, { self.scanSpinner.animator().alphaValue = 0 }) { [weak self] in
                guard let self, !(self.viewModel.isScanning && !self.viewModel.hasScanned) else { return }
                self.scanSpinner.stopAnimation(nil)
            }
        }
        if firstScan {
            emptyState.show(title: String(localized: "Scanning…"),
                            detail: String(localized: "Looking for temporary files written by agent sessions."))
        } else if !viewModel.hasScanned {
            emptyState.show(title: String(localized: "Not Scanned Yet"),
                            detail: String(localized: "Agent temporary files appear here after the first scan."))
        } else if searching {
            emptyState.show(title: String(localized: "No Matching Files"),
                            detail: String(localized: "No file, agent, or tool matches “\(viewModel.searchText)”."))
        } else {
            emptyState.show(title: String(localized: "No Agent Files"),
                            detail: String(localized: "Sidewatch found no temporary files written by agent sessions."))
        }
    }

    private func updateStatus() {
        let text: String
        if !viewModel.hasScanned {
            // The centered empty state carries the first scan.
            text = ""
        } else if viewModel.isScanning, viewModel.isForegroundScan {
            text = String(localized: "Scanning…")
        } else if let report = viewModel.report {
            // Background refreshes keep the last numbers; the spinner alone shows the work.
            text = [
                String(localized: "Scanned \(DisplayText.dateTime(report.scannedAt))"),
                String(localized: "\(report.sessionCount) sessions"),
                String(localized: "\(viewModel.items.count) files")
            ].joined(separator: " · ")
        } else {
            text = ""
        }
        if statusLabel.stringValue != text {
            if !statusLabel.stringValue.isEmpty { Motion.fade(statusLabel) }
            statusLabel.stringValue = text
        }
        statusLabel.setAccessibilityLabel(text)
        updateIssues()
        let showSpinner = viewModel.isScanning && viewModel.hasScanned
        if showSpinner, spinner.isHidden {
            spinner.isHidden = false
            spinner.startAnimation(nil)
            Motion.entrance(spinner)
        } else if !showSpinner, !spinner.isHidden {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
    }

    /// The latest cleanup result, shown in the content container's notice bar.
    var pageNotices: [StatusNotice] {
        var notices: [StatusNotice] = []
        if let message = viewModel.cleanupMessage {
            notices.append(StatusNotice(severity: message.deletedFiles ? .info : .warning, message: message.text))
        }
        return notices
    }

    /// Scan issues are diagnostics, not alerts: most are logs Sidewatch can't read (for example
    /// compressed Codex sessions). A compact pill in the status row opens them grouped by cause.
    private func updateIssues() {
        let count = viewModel.issues.count
        let title = String(localized: "\(count) scan issues")
        if issuesButton.title != title { issuesButton.title = title }
        issuesButton.setAccessibilityLabel(String(localized: "\(count) scan issues. Show details."))
        let hidden = count == 0
        guard issuesButton.isHidden != hidden else { return }
        issuesButton.isHidden = hidden
        if !hidden, view.window != nil { Motion.entrance(issuesButton) }
    }

    #if DEBUG
    /// Snapshot harness support: opens the issues popover and returns it so it can be captured.
    func debugShowIssues() -> NSPopover? {
        guard !issuesButton.isHidden else { return nil }
        return presentIssues(from: issuesButton)
    }
    #endif

    @objc private func showIssues(_ sender: NSButton) {
        presentIssues(from: sender)
    }

    @discardableResult
    private func presentIssues(from sender: NSButton) -> NSPopover? {
        let issues = viewModel.issues
        guard !issues.isEmpty else { return nil }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !Motion.reduceMotion
        popover.contentViewController = DiskIssuesViewController(issues: issues)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        return popover
    }

    private func updateControls() {
        scanButton.isEnabled = !viewModel.isForegroundScan
        cleanButton.isEnabled = viewModel.canClean
        if viewModel.cleanupSuppressed {
            cleanButton.toolTip = String(localized: "Cleanup is disabled while UI snapshots are being captured.")
        } else if viewModel.eligibleCount == 0 {
            cleanButton.toolTip = String(localized: "No files are eligible.")
        } else {
            cleanButton.toolTip = String(localized: "Permanently delete the eligible files shown in the list.")
        }
        autoCheckbox.isEnabled = !viewModel.cleanupSuppressed
        idlePopup.isEnabled = !viewModel.cleanupSuppressed
    }

    private func syncPolicy() {
        autoCheckbox.state = viewModel.policy.automaticCleanup ? .on : .off
        let index = AgentDiskViewModel.idleHourChoices.firstIndex(of: viewModel.policy.idleHours) ?? 2
        idlePopup.selectItem(at: index)
        updateControls()
    }

    private func updateSummary() {
        onSummaryChange?()
    }

    /// Header line shared with the content container.
    var summaryText: String {
        // Before the first report the page's empty state says what is happening; the header stays
        // quiet instead of repeating it. An empty label keeps its line height, so nothing jumps.
        guard viewModel.hasScanned else { return "" }
        let total = DisplayText.bytes(viewModel.totalBytes)
        guard viewModel.eligibleCount > 0 else { return String(localized: "\(total) on disk · nothing eligible") }
        return String(localized: "\(total) on disk · \(DisplayText.bytes(viewModel.eligibleBytes)) eligible")
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? DiskTreeNode else { return nodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? DiskTreeNode else { return nodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? DiskTreeNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue, let node = item as? DiskTreeNode else { return nil }
        let cell = ViewFactory.textCell(in: outlineView, identifier: column)
        switch (node.kind, column) {
        case (.session(let group), "name"):
            ViewFactory.configure(cell, text: "", symbol: "bubble.left.and.text.bubble.right",
                                  symbolColor: .secondaryLabelColor, tooltip: group.session.logPath)
            cell.textField?.attributedStringValue = Self.title(group.session.title, detail: group.session.agent,
                                                               weight: .semibold, monospaced: false)
            cell.setAccessibilityLabel(String(localized: "Session \(group.session.title), \(group.session.agent)"))
        case (.session(let group), "size"):
            ViewFactory.configure(cell, text: DisplayText.bytes(group.bytes), numeric: true, alignment: .right)
        case (.session(let group), "status"):
            if group.eligibleCount > 0 {
                ViewFactory.configure(cell, text: String(localized: "\(group.eligibleCount) eligible"),
                                      color: .systemGreen, symbol: "circle.fill", symbolColor: .systemGreen, symbolSize: 7)
            } else {
                ViewFactory.configure(cell, text: String(localized: "\(group.items.count) files"), color: .secondaryLabelColor)
            }
        case (.session(let group), "activity"):
            ViewFactory.configure(cell, text: DisplayText.dateTime(group.session.lastActivityAt), color: .secondaryLabelColor,
                                  numeric: true, tooltip: DisplayText.fullDateTime(group.session.lastActivityAt))
        case (.file(let item), "name"):
            let name = (item.path as NSString).lastPathComponent
            let folder = (item.path as NSString).deletingLastPathComponent
            ViewFactory.configure(cell, text: "", symbol: item.reason == "review.directory" ? "folder" : "doc",
                                  symbolColor: .tertiaryLabelColor, tooltip: item.path)
            cell.textField?.attributedStringValue = Self.title(name, detail: folder, weight: .regular, monospaced: true)
            cell.setAccessibilityLabel(item.path)
        case (.file(let item), "size"):
            ViewFactory.configure(cell, text: DisplayText.bytes(item.bytes), color: .secondaryLabelColor, numeric: true, alignment: .right)
        case (.file(let item), "status"):
            ViewFactory.configure(cell, text: DisplayText.agentDiskState(item.state),
                                  color: stateColor(item.state), symbol: "circle.fill",
                                  symbolColor: stateColor(item.state), symbolSize: 7,
                                  tooltip: DisplayText.agentDiskReason(item.reason))
        case (.file, "activity"):
            // A file's activity is its session's; the parent row already shows it.
            ViewFactory.configure(cell, text: "")
        default:
            ViewFactory.configure(cell, text: "")
        }
        return cell
    }

    /// Primary text followed by quieter context, e.g. a file name and its folder.
    private static func title(_ primary: String, detail: String, weight: NSFont.Weight, monospaced: Bool) -> NSAttributedString {
        let size = NSFont.systemFontSize - (monospaced ? 1 : 0)
        let font: NSFont = monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        let text = NSMutableAttributedString(string: primary, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if !detail.isEmpty {
            let detailFont: NSFont = monospaced ? .monospacedSystemFont(ofSize: size - 1, weight: .regular) : .systemFont(ofSize: size - 1)
            text.append(NSAttributedString(string: "   " + detail, attributes: [
                .font: detailFont, .foregroundColor: NSColor.tertiaryLabelColor
            ]))
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        return text
    }

    func outlineView(_ outlineView: NSOutlineView, shouldTypeSelectFor event: NSEvent, withCurrentSearch searchString: String?) -> Bool { true }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        switch (item as? DiskTreeNode)?.kind {
        case .session(let group): group.session.title
        case .file(let item): (item.path as NSString).lastPathComponent
        case nil: nil
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DiskTreeNode else { return }
        expandedLogs.insert(node.logPath)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? DiskTreeNode else { return }
        expandedLogs.remove(node.logPath)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection else { return }
        selectedKey = (outline.item(atRow: outline.selectedRow) as? DiskTreeNode)?.key
        renderDetail()
    }

    @objc private func doubleClicked() {
        guard let node = clickedNode else { return }
        switch node.kind {
        case .session:
            if outline.isItemExpanded(node) {
                outline.animator().collapseItem(node)
            } else {
                outline.animator().expandItem(node)
            }
        case .file(let item):
            ProcessControlUI.reveal(item.path, in: view.window)
        }
    }

    private func stateColor(_ state: AgentDiskItemState) -> NSColor {
        switch state {
        case .waiting: .secondaryLabelColor
        case .eligible: .systemGreen
        case .review: .systemOrange
        case .removed: .tertiaryLabelColor
        case .failed: .systemRed
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedNode else { return }
        if case .file(let item) = node.kind {
            menu.addItem(menuItem(String(localized: "Show in Finder"), #selector(menuRevealArtifact(_:)), item.path))
        }
        if !node.logPath.isEmpty {
            menu.addItem(menuItem(String(localized: "Show Session Log in Finder"), #selector(menuRevealPath(_:)), node.logPath))
        }
        menu.addItem(.separator())
        switch node.kind {
        case .file(let item):
            menu.addItem(menuItem(String(localized: "Copy Path"), #selector(menuCopyPath(_:)), item.path))
        case .session(let group):
            menu.addItem(menuItem(String(localized: "Copy Log Path"), #selector(menuCopyPath(_:)), group.session.logPath))
        }
    }

    private func menuItem(_ title: String, _ action: Selector, _ payload: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = payload
        return item
    }

    @objc private func menuRevealArtifact(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        ProcessControlUI.reveal(path, in: view.window)
    }

    @objc private func menuRevealPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        ProcessControlUI.reveal(path, in: view.window)
    }

    @objc private func menuCopyPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        ViewFactory.copyToPasteboard(path)
    }

    // MARK: Detail

    private func renderDetail() {
        // Minute refreshes rebuild nothing unless the selected item changed, so text selection
        // and scroll position survive.
        let key: String
        switch selectedNode?.kind {
        case .file(let item): key = "f" + item.path + "\u{1E}" + signature(item)
        case .session(let group): key = "s" + group.id + "\u{1E}" + String(group.bytes) + "\u{1D}"
            + String(group.items.count) + "\u{1D}" + String(group.session.lastActivityAt.timeIntervalSince1970)
        case nil: key = ""
        }
        guard key != renderedDetail else { return }
        // A different row slides its details in; a refresh of the same row only cross-fades.
        let previousIdentity = renderedDetail?.split(separator: "\u{1E}", maxSplits: 1).first
        let selectionChanged = previousIdentity != key.split(separator: "\u{1E}", maxSplits: 1).first
        renderedDetail = key
        if view.window != nil {
            if selectionChanged {
                Motion.entrance(detailStack)
            } else {
                Motion.fade(detailScroll)
            }
        }
        for view in detailStack.arrangedSubviews {
            detailStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        defer { detailStack.pinArrangedWidths() }
        if case .session(let group) = selectedNode?.kind {
            renderSessionDetail(group)
            return
        }
        guard case .file(let item) = selectedNode?.kind else {
            let title = ViewFactory.label(String(localized: "No Selection"),
                                          font: .systemFont(ofSize: 15, weight: .semibold),
                                          color: .secondaryLabelColor)
            let detail = ViewFactory.label(
                String(localized: "Select a session or file to see where it came from and when it can be deleted."),
                color: .tertiaryLabelColor, wraps: true
            )
            title.alignment = .center
            detail.alignment = .center
            let spacer = NSView()
            spacer.heightAnchor.constraint(equalToConstant: 36).isActive = true
            detailStack.addArrangedSubview(spacer)
            detailStack.addArrangedSubview(title)
            detailStack.addArrangedSubview(detail)
            return
        }

        detailStack.addArrangedSubview(ViewFactory.label((item.path as NSString).lastPathComponent,
                                                         font: .systemFont(ofSize: 15, weight: .semibold)))
        let pathLabel = ViewFactory.label(item.path, font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular),
                                          color: .secondaryLabelColor, selectable: true)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.toolTip = item.path
        detailStack.addArrangedSubview(pathLabel)

        addDetailRow(String(localized: "Status"), DisplayText.agentDiskState(item.state), color: stateColor(item.state))
        addDetailRow(String(localized: "Reason"), DisplayText.agentDiskReason(item.reason))
        addDetailRow(String(localized: "Size"), DisplayText.bytes(item.bytes), monospaced: true)
        addDetailRow(String(localized: "Last Activity"), DisplayText.fullDateTime(item.lastActivityAt), monospaced: true)
        addDetailRow(String(localized: "Eligible From"),
                     item.eligibleAt.map(DisplayText.fullDateTime) ?? "—",
                     color: item.eligibleAt == nil ? .tertiaryLabelColor : .labelColor,
                     monospaced: true)
        addDetailRow(String(localized: "Agents"),
                     item.agents.isEmpty ? "—" : item.agents.formatted(.list(type: .and)),
                     color: item.agents.isEmpty ? .tertiaryLabelColor : .labelColor)
        addDetailRow(String(localized: "Tools"),
                     item.tools.isEmpty ? "—" : item.tools.formatted(.list(type: .and)),
                     color: item.tools.isEmpty ? .tertiaryLabelColor : .labelColor)
        addDetailRow(String(localized: "Sessions"), String(item.sessionIDs.count), monospaced: true)

        detailStack.addArrangedSubview(ViewFactory.sectionHeader(String(localized: "Provenance")))
        addProvenanceRow(String(localized: "File"), path: item.path)
        for log in Set(item.logPaths).sorted() {
            addProvenanceRow(String(localized: "Session Log"), path: log)
        }
        if item.logPaths.isEmpty {
            addDetailRow(String(localized: "Session Log"), String(localized: "Unavailable"), color: .tertiaryLabelColor)
        }

        if item.state == .review {
            detailStack.addArrangedSubview(ViewFactory.label(
                String(localized: "Skipped by Clean Eligible and automatic cleanup."),
                font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, wraps: true
            ))
        }

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.addArrangedSubview(revealButton(String(localized: "Show in Finder"), path: item.path))
        actions.addArrangedSubview(revealButton(String(localized: "Copy Path"), path: item.path, copies: true))
        detailStack.addArrangedSubview(actions)
    }

    private func renderSessionDetail(_ group: AgentDiskSessionGroup) {
        let session = group.session
        detailStack.addArrangedSubview(ViewFactory.label(session.title, font: .systemFont(ofSize: 15, weight: .semibold)))
        if let project = session.projectRoot {
            let projectLabel = ViewFactory.label(project, font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular),
                                                 color: .secondaryLabelColor, selectable: true)
            projectLabel.lineBreakMode = .byTruncatingMiddle
            projectLabel.toolTip = project
            detailStack.addArrangedSubview(projectLabel)
        }
        addDetailRow(String(localized: "Agent"), session.agent.isEmpty ? "—" : session.agent,
                     color: session.agent.isEmpty ? .tertiaryLabelColor : .labelColor)
        addDetailRow(String(localized: "Session ID"), session.sessionID.isEmpty ? "—" : session.sessionID, monospaced: true)
        addDetailRow(String(localized: "Last Activity"), DisplayText.fullDateTime(session.lastActivityAt), monospaced: true)
        addDetailRow(String(localized: "Process Exit"),
                     session.endedAt.map(DisplayText.fullDateTime) ?? String(localized: "Not observed"),
                     color: session.endedAt == nil ? .tertiaryLabelColor : .labelColor,
                     monospaced: session.endedAt != nil)
        addDetailRow(String(localized: "Files"), String(localized: "\(group.items.count) files"))
        addDetailRow(String(localized: "Size"), DisplayText.bytes(group.bytes), monospaced: true)
        if group.eligibleCount > 0 {
            addDetailRow(String(localized: "Eligible"), String(localized: "\(group.eligibleCount) files"), color: .systemGreen)
        }
        if !session.logPath.isEmpty {
            detailStack.addArrangedSubview(ViewFactory.sectionHeader(String(localized: "Provenance")))
            addProvenanceRow(String(localized: "Session Log"), path: session.logPath)
        }
    }

    private func addDetailRow(_ title: String, _ value: String, color: NSColor = .labelColor, monospaced: Bool = false) {
        let key = ViewFactory.label(title, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
        key.alignment = .right
        key.setContentHuggingPriority(.required, for: .horizontal)
        key.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let value = ViewFactory.label(value, font: monospaced
            ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
            : .systemFont(ofSize: NSFont.smallSystemFontSize + 1),
            color: color, selectable: monospaced)
        value.lineBreakMode = .byTruncatingMiddle
        value.toolTip = value.stringValue
        let row = NSStackView(views: [key, value])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        detailStack.addArrangedSubview(row)
    }

    private func addProvenanceRow(_ title: String, path: String) {
        let key = ViewFactory.label(title, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
        key.alignment = .right
        key.setContentHuggingPriority(.required, for: .horizontal)
        key.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let pathLabel = ViewFactory.label(path, font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular),
                                          color: .labelColor, selectable: true)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.toolTip = path
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let button = DiskPathButton()
        button.title = String(localized: "Show")
        button.setAccessibilityLabel(String(localized: "Show \(title) in Finder: \((path as NSString).lastPathComponent)"))
        button.target = self
        button.action = #selector(revealPathButton(_:))
        button.bezelStyle = .push
        button.controlSize = .small
        button.path = path
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [key, pathLabel, button])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        detailStack.addArrangedSubview(row)
    }

    private func revealButton(_ title: String, path: String, copies: Bool = false) -> NSButton {
        let button = DiskPathButton()
        button.title = title
        button.target = self
        button.action = copies ? #selector(copyPathButton(_:)) : #selector(revealPathButton(_:))
        button.bezelStyle = .push
        button.controlSize = .small
        button.path = path
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    @objc private func revealPathButton(_ sender: DiskPathButton) {
        ProcessControlUI.reveal(sender.path, in: view.window)
    }

    @objc private func copyPathButton(_ sender: DiskPathButton) {
        ViewFactory.copyToPasteboard(sender.path)
    }
}

/// A push button carrying the path it acts on, so provenance rows don't need an object map.
private final class DiskPathButton: NSButton {
    var path = ""
}

private final class DiskDetailDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Popover listing scan issues grouped by cause. Paths are removed from the cause text and one
/// example path is shown under it, so thousands of similar issues read as a few lines.
private final class DiskIssuesViewController: NSViewController {
    struct Group {
        var cause: String
        var example: String?
        var count: Int
    }

    private let issues: [String]

    init(issues: [String]) {
        self.issues = issues
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func groups(_ issues: [String]) -> [Group] {
        // Only absolute paths that start a word; "eval/source" is not a path.
        let pathPattern = #"(?<!\S)/[^\s:]+"#
        var groups: [Group] = []
        var index: [String: Int] = [:]
        for issue in issues {
            var cause = issue.replacingOccurrences(of: pathPattern, with: "", options: .regularExpression)
            cause = cause.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            cause = cause.replacingOccurrences(of: #"\s*:\s*$"#, with: "", options: .regularExpression)
            cause = cause.replacingOccurrences(of: #"\s+:"#, with: ":", options: .regularExpression)
            if let position = index[cause] {
                groups[position].count += 1
            } else {
                index[cause] = groups.count
                let example = issue.range(of: pathPattern, options: .regularExpression).map { String(issue[$0]) }
                groups.append(Group(cause: cause, example: example, count: 1))
            }
        }
        return groups.sorted { $0.count == $1.count ? $0.cause < $1.cause : $0.count > $1.count }
    }

    override func loadView() {
        let groups = Self.groups(issues)
        let title = ViewFactory.label(String(localized: "Scan Issues"), font: .systemFont(ofSize: 13, weight: .semibold))
        let subtitle = ViewFactory.label(
            issues.count.formatted(),
            font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            color: .secondaryLabelColor
        )
        let copy = NSButton(title: String(localized: "Copy All"), target: self, action: #selector(copyAll))
        copy.bezelStyle = .push
        copy.controlSize = .small
        let header = NSStackView(views: [title, subtitle, NSView(), copy])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 10, right: 12)

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        for (offset, group) in groups.enumerated() {
            if offset > 0 {
                let rule = NSBox()
                rule.boxType = .separator
                list.addArrangedSubview(rule)
            }
            list.addArrangedSubview(Self.row(group))
        }
        list.pinArrangedWidths()

        let document = DiskDetailDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        let separator = NSBox()
        separator.boxType = .separator
        let root = NSStackView(views: [header, separator, scroll])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        root.pinArrangedWidths()
        let container = NSView()
        container.addSubview(root)
        list.layoutSubtreeIfNeeded()
        let height = min(max(list.fittingSize.height, 44), 320)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 460),
            scroll.heightAnchor.constraint(equalToConstant: height)
        ])
        view = container
    }

    private static func row(_ group: Group) -> NSView {
        let count = ViewFactory.label(group.count.formatted(),
                                      font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .semibold),
                                      color: .systemOrange)
        count.alignment = .right
        count.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let cause = ViewFactory.label(group.cause, font: .systemFont(ofSize: NSFont.smallSystemFontSize + 1), wraps: true)
        cause.preferredMaxLayoutWidth = 384  // 460 popover − count column, spacing, insets
        var lines: [NSView] = [cause]
        if let example = group.example {
            let path = ViewFactory.label(example, font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular),
                                         color: .tertiaryLabelColor, selectable: true)
            path.lineBreakMode = .byTruncatingMiddle
            path.toolTip = example
            path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            lines.append(path)
        }
        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [count, text])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.distribution = .fill
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 16)
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel("\(group.count.formatted()): \(group.cause)")
        return row
    }

    @objc private func copyAll() {
        ViewFactory.copyToPasteboard(issues.joined(separator: "\n"))
    }
}

private extension NSStackView {
    /// A vertical stack doesn't stretch its arranged views, so short labels and rows would hug
    /// one edge. Pin each one to the stack's width inside its insets.
    func pinArrangedWidths() {
        let insets = edgeInsets.left + edgeInsets.right
        for view in arrangedSubviews {
            view.widthAnchor.constraint(equalTo: widthAnchor, constant: -insets).isActive = true
        }
    }
}

/// Outline row: a session log, or one of the files it claimed. Rebuilt on every report; rows
/// are matched across reloads by `key`.
private final class DiskTreeNode {
    enum Kind {
        case session(AgentDiskSessionGroup)
        case file(AgentDiskItem)
    }

    let kind: Kind
    let key: String
    let logPath: String
    weak var parent: DiskTreeNode?
    private(set) var children: [DiskTreeNode] = []

    static func sessionKey(_ logPath: String) -> String { "s\u{0}" + logPath }

    init(group: AgentDiskSessionGroup) {
        kind = .session(group)
        logPath = group.id
        key = Self.sessionKey(group.id)
        children = group.items
            .sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
            .map { DiskTreeNode(item: $0, logPath: group.id, parent: self) }
    }

    private init(item: AgentDiskItem, logPath: String, parent: DiskTreeNode) {
        kind = .file(item)
        self.logPath = logPath
        key = "f\u{0}" + logPath + "\u{0}" + item.path
        self.parent = parent
    }
}

extension AgentDiskSession {
    /// Project folder name, or a short session ID when the project is unknown.
    var title: String {
        if let projectRoot, !projectRoot.isEmpty { return (projectRoot as NSString).lastPathComponent }
        if !sessionID.isEmpty { return String(localized: "Session \(String(sessionID.prefix(8)))") }
        return String(localized: "Unknown Session")
    }
}
