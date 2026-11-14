import AppKit

/// Main window: sidebar, content (header, summary cards, notices, page), and inspector.
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let viewModel: ActivityViewModel
    private let rules: RuleViewModel
    private let splitController = NSSplitViewController()
    private let sidebar: SidebarViewController
    private let content: ContentContainerViewController
    private let inspector: InspectorViewController
    private var inspectorItem: NSSplitViewItem?
    private let modePill = StatusPillView()
    private weak var searchItem: NSSearchToolbarItem?
    private var searchDebounce: Task<Void, Never>?

    private static let modeItem = NSToolbarItem.Identifier("Sidewatch.mode")
    private static let refreshItem = NSToolbarItem.Identifier("Sidewatch.refresh")
    private static let searchIdentifier = NSToolbarItem.Identifier("Sidewatch.search")

    init(viewModel: ActivityViewModel, rules: RuleViewModel) {
        self.viewModel = viewModel
        self.rules = rules
        sidebar = SidebarViewController(viewModel: viewModel, rules: rules)
        content = ContentContainerViewController(viewModel: viewModel, rules: rules)
        inspector = InspectorViewController(viewModel: viewModel, rules: rules)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Sidewatch")
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 900, height: 560)
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.isRestorable = true
        super.init(window: window)
        window.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 300
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 460
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 280
        inspectorItem.maximumThickness = 520
        inspectorItem.canCollapse = true
        self.inspectorItem = inspectorItem
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
        splitController.addSplitViewItem(inspectorItem)
        splitController.splitView.autosaveName = "Sidewatch.split"
        window.contentViewController = splitController

        let toolbar = NSToolbar(identifier: "Sidewatch.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        window.setFrameAutosaveName("Sidewatch.main")
        if !window.setFrameUsingName("Sidewatch.main") { window.center() }

        viewModel.observe { [weak self] change in
            guard let self else { return }
            if change.contains(.status) || change.contains(.configuration) { updateModePill() }
            if change.contains(.page) { updateSubtitle() }
        }
        updateModePill()
        updateSubtitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.modeItem, .space, Self.refreshItem, Self.searchIdentifier, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.modeItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            // The toolbar supplies the glass capsule; the pill only draws its dot and text.
            modePill.drawsChrome = false
            modePill.heightAnchor.constraint(equalToConstant: 22).isActive = true
            modePill.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(showRules(_:))))
            item.view = modePill
            item.label = String(localized: "Mode")
            item.toolTip = String(localized: "Protection mode confirmed by the monitor")
            item.visibilityPriority = .high
            return item
        case Self.refreshItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: String(localized: "Refresh"))
            item.label = String(localized: "Refresh")
            item.toolTip = String(localized: "Refresh processes, ports, and history")
            item.target = self
            item.action = #selector(refresh(_:))
            item.isBordered = true
            return item
        case Self.searchIdentifier:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = String(localized: "Search")
            item.searchField.delegate = self
            item.searchField.setAccessibilityLabel(String(localized: "Search ports, commands, project paths, and file paths"))
            item.searchField.toolTip = String(localized: "Search by port number, command, project path, or file path")
            item.preferredWidthForSearchField = 180
            // Keep search compact instead of letting it absorb the toolbar's free space.
            let cap = item.searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 220)
            cap.priority = .defaultHigh
            cap.isActive = true
            searchItem = item
            return item
        default:
            return nil
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        let text = field.stringValue
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.viewModel.setSearchText(text)
        }
    }

    private func updateModePill() {
        let text: String
        let color: NSColor
        var live = false
        switch rules.activation {
        case .unavailable:
            switch viewModel.extensionManager.availability {
            case .awaitingApproval: text = String(localized: "Needs Approval")
            default: text = viewModel.link == .connecting ? String(localized: "Connecting…") : String(localized: "Monitor Off")
            }
            color = .systemGray
        case .active(_, let mode):
            text = DisplayText.mode(mode)
            color = Palette.modeColor(mode)
            live = viewModel.health?.availability == .active
        case .pending(_, _, let activeMode):
            if let activeMode {
                text = String(localized: "\(DisplayText.mode(activeMode)) (Change Pending)")
                color = Palette.modeColor(activeMode)
            } else {
                text = String(localized: "Mode Pending")
                color = .systemGray
            }
        }
        let accessibility: String
        if live {
            accessibility = String(localized: "Active mode: \(text). Collecting activity.")
        } else if case .unavailable = rules.activation {
            accessibility = String(localized: "Protection status: \(text). History and protection are inactive until the monitor is connected.")
        } else {
            accessibility = String(localized: "Protection status: \(text)")
        }
        modePill.set(text: text, color: color, live: live, accessibilityText: accessibility)
    }

    private func updateSubtitle() {
        window?.subtitle = DisplayText.page(viewModel.page)
    }

    // MARK: Commands (responder chain)

    @objc func refresh(_ sender: Any?) {
        viewModel.refresh()
        if viewModel.isHistoryAvailable { viewModel.reloadTimeline() }
    }

    @objc func performFind(_ sender: Any?) {
        searchItem?.beginSearchInteraction()
    }

    @objc func showAgents(_ sender: Any?) { viewModel.setPage(.agents) }
    @objc func showTimeline(_ sender: Any?) { viewModel.setPage(.timeline) }
    @objc func showPorts(_ sender: Any?) { viewModel.setPage(.ports) }
    @objc func showLeftovers(_ sender: Any?) { viewModel.setPage(.leftovers) }
    @objc func showRules(_ sender: Any?) { viewModel.setPage(.rules) }

    @objc func installExtension(_ sender: Any?) { viewModel.activateExtension() }
    @objc func openFullDiskAccessSettings(_ sender: Any?) { viewModel.openFullDiskAccess() }

    @objc func newRule(_ sender: Any?) {
        viewModel.setPage(.rules)
        content.ruleEditor.presentEditor(for: nil)
    }

    @objc func clearHistory(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear Activity History?")
        alert.informativeText = String(localized: "Recorded file activity and finished history are removed. Running services and the origins needed to explain them are kept, and your rules and mode don't change. This is not secure erasure.")
        alert.addButton(withTitle: String(localized: "Clear History"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { @MainActor in
                if let message = await self.viewModel.clearHistory() {
                    let failure = NSAlert()
                    failure.messageText = String(localized: "Couldn't Clear History")
                    failure.informativeText = message
                    failure.beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showAgents(_:)): menuItem.state = viewModel.page == .agents ? .on : .off
        case #selector(showTimeline(_:)): menuItem.state = viewModel.page == .timeline ? .on : .off
        case #selector(showPorts(_:)): menuItem.state = viewModel.page == .ports ? .on : .off
        case #selector(showLeftovers(_:)): menuItem.state = viewModel.page == .leftovers ? .on : .off
        case #selector(showRules(_:)): menuItem.state = viewModel.page == .rules ? .on : .off
        case #selector(clearHistory(_:)), #selector(newRule(_:)): return viewModel.isHistoryAvailable
        default: break
        }
        return true
    }
}

// MARK: - Sidebar

final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let viewModel: ActivityViewModel
    private let rules: RuleViewModel
    private let table = NSTableView()
    private let pages = SidewatchPage.allCases
    private var updating = false

    init(viewModel: ActivityViewModel, rules: RuleViewModel) {
        self.viewModel = viewModel
        self.rules = rules
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        table.style = .sourceList
        table.headerView = nil
        table.rowHeight = 30
        table.addTableColumn(NSTableColumn(identifier: .init("page")))
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(String(localized: "Sections"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        viewModel.observe { [weak self] change in
            guard let self else { return }
            if change.contains(.page) { syncSelection() }
            if change.contains(.rows) || change.contains(.configuration) || change.contains(.status) { updateBadges() }
        }
        rules.observe { [weak self] in self?.updateBadges() }
        table.reloadData()
        syncSelection()
    }

    private func syncSelection() {
        guard let index = pages.firstIndex(of: viewModel.page), table.selectedRow != index else { return }
        updating = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        updating = false
    }

    private func badge(for page: SidewatchPage) -> (Int, NSColor)? {
        switch page {
        case .agents:
            let running = viewModel.projection.agents.filter { $0.state == .running }.count
            return running > 0 ? (running, .systemGreen) : nil
        case .ports:
            let count = viewModel.projection.ports.count
            return count > 0 ? (count, .secondaryLabelColor) : nil
        case .leftovers:
            let count = viewModel.projection.leftovers.count
            return count > 0 ? (count, .systemOrange) : nil
        case .rules:
            let enabled = rules.configuration?.rules.filter(\.enabled).count ?? 0
            return enabled > 0 ? (enabled, .secondaryLabelColor) : nil
        case .timeline:
            return nil
        }
    }

    private func updateBadges() {
        for (row, page) in pages.enumerated() {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.setBadge(badge(for: page))
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: SidebarCell.identifier, owner: nil) as? SidebarCell) ?? SidebarCell()
        let page = pages[row]
        cell.configure(title: DisplayText.page(page), symbol: DisplayText.pageSymbol(page))
        cell.setBadge(badge(for: page), animated: false)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, table.selectedRow >= 0 else { return }
        viewModel.setPage(pages[table.selectedRow])
    }
}

private final class SidebarCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
    private let badge = BadgeView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, title, NSView(), badge])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { badge.isEmphasized = backgroundStyle == .emphasized }
    }

    func configure(title: String, symbol: String) {
        self.title.stringValue = title
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        setAccessibilityLabel(title)
    }

    func setBadge(_ value: (Int, NSColor)?, animated: Bool = true) {
        badge.set(value: value?.0, color: value?.1 ?? .secondaryLabelColor, animated: animated)
        if let count = value?.0 {
            setAccessibilityLabel(String(localized: "\(title.stringValue), \(count) items"))
        } else {
            setAccessibilityLabel(title.stringValue)
        }
    }
}

/// Capsule count badge that pops in, rolls between values, and fades out at zero.
private final class BadgeView: AppearanceAwareView {
    private let label = NSTextField(labelWithString: "")
    private var color: NSColor = .secondaryLabelColor
    private var value: Int?
    var isEmphasized = false { didSet { if isEmphasized != oldValue { updateColors() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = Palette.roundedFont(size: 11, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.wantsLayer = true
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 18),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 22)
        ])
        layer?.cornerCurve = .continuous
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    func set(value newValue: Int?, color: NSColor, animated: Bool) {
        self.color = color
        updateColors()
        defer { value = newValue }
        guard newValue != value else { return }
        guard let newValue else {
            if animated { Motion.animate(Motion.quick, { self.animator().alphaValue = 0 }, completion: { self.isHidden = true }) }
            else { isHidden = true }
            return
        }
        if animated, let old = value { Motion.roll(label, upward: newValue > old) }
        label.stringValue = newValue.formatted()
        if isHidden {
            isHidden = false
            alphaValue = animated ? 0 : 1
            if animated { Motion.animate(Motion.standard) { self.animator().alphaValue = 1 } }
        }
    }

    override func updateColors() {
        if isEmphasized {
            label.textColor = .alternateSelectedControlTextColor
            layer?.backgroundColor = resolved(NSColor.white.withAlphaComponent(0.25))
            return
        }
        label.textColor = color == .secondaryLabelColor ? .secondaryLabelColor : color
        layer?.backgroundColor = resolved(color.withAlphaComponent(color == .secondaryLabelColor ? 0.12 : 0.16))
    }
}

// MARK: - Content container

/// Compact page header, full-width info bar, and the current page.
final class ContentContainerViewController: NSViewController {
    private let viewModel: ActivityViewModel
    private let rules: RuleViewModel
    let activityList: ActivityViewController
    let ruleEditor: RuleEditorViewController

    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let notices = NoticeStackView()
    private let pageHost = NSView()
    private var shownPage: SidewatchPage?

    init(viewModel: ActivityViewModel, rules: RuleViewModel) {
        self.viewModel = viewModel
        self.rules = rules
        activityList = ActivityViewController(viewModel: viewModel)
        ruleEditor = RuleEditorViewController(viewModel: viewModel, rules: rules)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.setAccessibilityRole(.staticText)
        summaryLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [titleLabel, summaryLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 1
        header.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        header.translatesAutoresizingMaskIntoConstraints = false
        notices.onAction = { [weak self] action in self?.viewModel.perform(action) }

        pageHost.translatesAutoresizingMaskIntoConstraints = false
        pageHost.wantsLayer = true
        root.addSubview(header)
        root.addSubview(notices)
        root.addSubview(pageHost)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            notices.topAnchor.constraint(equalTo: header.bottomAnchor),
            notices.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            notices.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pageHost.topAnchor.constraint(equalTo: notices.bottomAnchor),
            pageHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pageHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pageHost.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for child in [activityList, ruleEditor] as [NSViewController] {
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            pageHost.addSubview(child.view)
            NSLayoutConstraint.activate([
                child.view.topAnchor.constraint(equalTo: pageHost.topAnchor),
                child.view.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
                child.view.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor)
            ])
        }
        viewModel.observe { [weak self] change in
            guard let self else { return }
            if change.contains(.page) { showPage() }
            if change.contains(.status) || change.contains(.rows) || change.contains(.configuration) || change.contains(.timeline) {
                updateHeader()
            }
        }
        rules.observe { [weak self] in self?.updateHeader() }
        showPage()
    }

    /// Dips the page out and back in, so two different tables are never visible at once.
    private func showPage() {
        let page = viewModel.page
        guard page != shownPage else { return }
        let first = shownPage == nil
        shownPage = page
        guard !first, !Motion.reduceMotion else {
            apply(page)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.09
            context.timingFunction = Motion.easeInOut
            pageHost.animator().alphaValue = 0
            summaryLabel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.apply(page)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = Motion.easeOut
                    self.pageHost.animator().alphaValue = 1
                    self.summaryLabel.animator().alphaValue = 1
                }
            }
        })
    }

    private func apply(_ page: SidewatchPage) {
        activityList.view.isHidden = page == .rules
        ruleEditor.view.isHidden = page != .rules
        updateHeader()
    }

    private func updateHeader() {
        let page = viewModel.page
        titleLabel.stringValue = DisplayText.page(page)
        summaryLabel.stringValue = summary(for: page)
        notices.show(viewModel.notices)
    }

    private func summary(for page: SidewatchPage) -> String {
        let projection = viewModel.projection
        let history = viewModel.isHistoryAvailable
        switch page {
        case .agents:
            let running = projection.agents.filter { $0.state == .running }.count
            return history
                ? String(localized: "\(running) running · \(projection.agents.count) sessions")
                : String(localized: "\(running) running · current processes only")
        case .timeline:
            return history ? String(localized: "\(viewModel.timeline.count) events loaded") : String(localized: "History off")
        case .ports:
            let ports = Set(projection.ports.map(\.endpoint.port)).count
            return String(localized: "\(projection.ports.count) endpoints on \(ports) ports")
        case .leftovers:
            return history
                ? String(localized: "\(projection.leftovers.count) still running after their agent exited")
                : String(localized: "Needs monitor history")
        case .rules:
            let all = rules.configuration?.rules ?? []
            let enabled = all.filter(\.enabled).count
            switch rules.activation {
            case .active(_, let mode):
                return String(localized: "\(DisplayText.mode(mode)) · \(enabled) of \(all.count) rules on")
            case .pending:
                return String(localized: "Change pending · \(enabled) of \(all.count) rules on")
            case .unavailable:
                return String(localized: "Inactive while the monitor is off")
            }
        }
    }
}
