import AppKit

enum SettingsPane: String, CaseIterable {
    case general, monitor, agentDisk, data

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .monitor: String(localized: "Monitor")
        case .agentDisk: String(localized: "Agent Disk")
        case .data: String(localized: "Data")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .monitor: "checkmark.shield"
        case .agentDisk: "internaldrive"
        case .data: "externaldrive"
        }
    }
}

/// Native Settings window: a preference-style toolbar switches panes, and the window resizes to
/// fit each pane (and any change in a pane's content) with a cross-fade.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    private let container = NSView()
    private var panes: [SettingsPane: SettingsPaneController] = [:]
    private(set) var current: SettingsPane?
    private static let width: CGFloat = 600
    private static let paneKey = "Sidewatch.settings.pane"

    init(viewModel: ActivityViewModel, rules: RuleViewModel, disk: AgentDiskViewModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.toolbarStyle = .preference
        window.isRestorable = false
        window.animationBehavior = .documentWindow
        super.init(window: window)
        window.delegate = self
        window.contentView = container

        panes = [
            .general: GeneralSettingsPane(viewModel: viewModel),
            .monitor: MonitorSettingsPane(viewModel: viewModel),
            .agentDisk: AgentDiskSettingsPane(disk: disk),
            .data: DataSettingsPane(viewModel: viewModel, rules: rules)
        ]
        for pane in panes.values {
            pane.onSizeChange = { [weak self, weak pane] in
                guard let self, let pane, pane === self.current.flatMap({ self.panes[$0] }) else { return }
                self.fitWindow(animated: true)
            }
        }

        let toolbar = NSToolbar(identifier: "Sidewatch.settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        let saved = UserDefaults.standard.string(forKey: Self.paneKey).flatMap(SettingsPane.init(rawValue:))
        show(saved ?? .monitor, animated: false)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ pane: SettingsPane, animated: Bool = true) {
        guard let window, let controller = panes[pane] else { return }
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
        window.title = pane.title
        guard pane != current else { return }
        let previous = current.flatMap { panes[$0] }
        current = pane
        UserDefaults.standard.set(pane.rawValue, forKey: Self.paneKey)

        previous?.view.removeFromSuperview()
        previous?.paneDidDisappear()
        let view = controller.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.widthAnchor.constraint(equalToConstant: Self.width)
        ])
        controller.paneWillAppear()
        let animate = animated && window.isVisible && !Motion.reduceMotion
        if animate { view.alphaValue = 0 }
        fitWindow(animated: animate)
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.standard
                context.timingFunction = Motion.easeOut
                view.animator().alphaValue = 1
            }
        }
    }

    /// Sizes the window to the current pane, keeping its top edge in place.
    private func fitWindow(animated: Bool) {
        guard let window, let pane = current.flatMap({ panes[$0] }) else { return }
        pane.view.layoutSubtreeIfNeeded()
        let height = ceil(pane.view.fittingSize.height)
        let content = NSRect(x: 0, y: 0, width: Self.width, height: height)
        var frame = window.frameRect(forContentRect: content)
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        guard abs(frame.height - window.frame.height) > 0.5 else { return }
        window.setFrame(frame, display: true, animate: animated && window.isVisible && !Motion.reduceMotion)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        current.flatMap { panes[$0] }?.paneWillAppear()
    }

    func windowWillClose(_ notification: Notification) {
        current.flatMap { panes[$0] }?.paneDidDisappear()
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane(rawValue: sender.itemIdentifier.rawValue) else { return }
        show(pane)
    }
}

// MARK: - Pane base

/// A settings pane: a vertical stack of sections at a fixed width. Panes report content size
/// changes so the window can follow them.
class SettingsPaneController: NSViewController {
    var onSizeChange: (() -> Void)?
    let stack = NSStackView()

    override func loadView() {
        let root = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        let bottom = stack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom
        ])
        view = root
        build()
    }

    /// Subclasses add their sections here.
    func build() {}

    func add(_ section: NSView) {
        stack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
    }

    func paneWillAppear() {}
    func paneDidDisappear() {}

    /// Call after content changes that may alter the pane's height.
    func contentChanged() {
        guard isViewLoaded, view.window != nil else { return }
        let before = view.fittingSize.height
        view.layoutSubtreeIfNeeded()
        if abs(view.fittingSize.height - before) > 0.5 || abs(view.fittingSize.height - view.frame.height) > 0.5 {
            onSizeChange?()
        }
    }
}

// MARK: - General

final class GeneralSettingsPane: SettingsPaneController {
    private let viewModel: ActivityViewModel
    private let notifications = NSSwitch()
    private let badge = NSSwitch()
    private var observer: NSObjectProtocol?

    init(viewModel: ActivityViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func build() {
        notifications.target = self
        notifications.action = #selector(toggleNotifications)
        notifications.controlSize = .small
        notifications.setAccessibilityLabel(String(localized: "Leftover service notifications"))
        badge.target = self
        badge.action = #selector(toggleBadge)
        badge.controlSize = .small
        badge.setAccessibilityLabel(String(localized: "Leftover count on the Dock icon"))

        add(SettingsSection(title: String(localized: "Leftover Services"), rows: [
            SettingsRow(title: String(localized: "Notifications"),
                        detail: String(localized: "Notify me when an agent exits while processes it started are still running."),
                        accessories: [notifications]),
            SettingsRow(title: String(localized: "Dock badge"),
                        detail: String(localized: "Show the number of leftover processes on the Sidewatch icon."),
                        accessories: [badge])
        ], footer: String(localized: "Leftovers are identified from recorded agent exits, so reminders need the monitor.")))

        let rulesButton = ViewFactory.button(String(localized: "Open Protection Rules"), target: self, action: #selector(openRules))
        let notificationSettings = ViewFactory.button(String(localized: "Notification Settings…"), target: self, action: #selector(openNotificationSettings))
        add(SettingsSection(title: String(localized: "Shortcuts"), rows: [
            SettingsRow(title: String(localized: "Protection rules and mode"),
                        detail: String(localized: "Choose Record Only, Dry Run, or Protect, and manage protected files and folders."),
                        accessories: [rulesButton]),
            SettingsRow(title: String(localized: "System notifications"),
                        detail: String(localized: "Change how Sidewatch alerts appear in macOS."),
                        accessories: [notificationSettings])
        ]))

        observer = NotificationCenter.default.addObserver(forName: AppPreferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        render()
    }

    private func render() {
        notifications.state = AppPreferences.shared.leftoverNotifications ? .on : .off
        badge.state = AppPreferences.shared.leftoverBadge ? .on : .off
    }

    @objc private func toggleNotifications() { AppPreferences.shared.leftoverNotifications = notifications.state == .on }
    @objc private func toggleBadge() { AppPreferences.shared.leftoverBadge = badge.state == .on }

    @objc private func openRules() {
        viewModel.setPage(.rules)
        AppDelegate.shared?.showMainWindow()
    }

    @objc private func openNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(MonitorWire.hostID)")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Monitor

/// Monitor helper management: overall status, a requirements checklist, and install, check,
/// and uninstall actions.
final class MonitorSettingsPane: SettingsPaneController {
    private let viewModel: ActivityViewModel
    private let hero = SettingsHeroView()
    private let requirements = SettingsSection(title: String(localized: "Requirements"))
    private let extensionRow = RequirementRow(title: String(localized: "System extension"))
    private let accessRow = RequirementRow(title: String(localized: "Full Disk Access"))
    private let serviceRow = RequirementRow(title: String(localized: "Monitor service"))
    private let collectionRow = RequirementRow(title: String(localized: "Activity collection"))
    private lazy var checkButton = ViewFactory.button(String(localized: "Check Again"), symbol: "arrow.clockwise", target: self, action: #selector(checkAgain))
    private lazy var installButton = ViewFactory.button(String(localized: "Install"), target: self, action: #selector(install))
    private lazy var uninstallButton = ViewFactory.button(String(localized: "Uninstall…"), target: self, action: #selector(uninstall))
    private let checkSpinner = NSProgressIndicator()
    private var observerID: UUID?
    private var clock: Timer?
    /// Keeps "checking" visible briefly so a fast check still reads as having happened.
    private var checkingUntil: Date?

    init(viewModel: ActivityViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func build() {
        add(hero)
        requirements.setRows([extensionRow, accessRow, serviceRow, collectionRow])
        add(requirements)

        uninstallButton.hasDestructiveAction = true
        checkSpinner.style = .spinning
        checkSpinner.controlSize = .small
        checkSpinner.isDisplayedWhenStopped = false
        installButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [uninstallButton, NSView(), checkSpinner, checkButton, installButton])
        buttons.spacing = 8
        buttons.alignment = .centerY
        add(buttons)

        observerID = viewModel.observe { [weak self] change in
            if change.contains(.status) || change.contains(.configuration) { self?.render() }
        }
        render()
    }

    override func paneWillAppear() {
        render()
        clock?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    override func paneDidDisappear() {
        clock?.invalidate()
        clock = nil
    }

    @objc private func checkAgain() {
        checkingUntil = Date().addingTimeInterval(0.9)
        viewModel.checkMonitorStatus()
        render()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.render()
        }
    }

    @objc private func install() {
        let manager = viewModel.extensionManager
        if manager.availability == .awaitingApproval {
            viewModel.openExtensionSettings()
        } else {
            viewModel.activateExtension()
        }
    }

    @objc private func uninstall() {
        guard let window = view.window else { return }
        DataActions.confirmUninstall(in: window, viewModel: viewModel)
    }

    // MARK: Rendering

    private func render() {
        guard isViewLoaded else { return }
        let manager = viewModel.extensionManager
        let checking = viewModel.isCheckingMonitor || (checkingUntil.map { $0 > Date() } ?? false)
        let busy = manager.operation == .installing || manager.operation == .uninstalling || viewModel.isRemovingMonitor
        let health = viewModel.link == .connected ? viewModel.health : nil

        renderExtensionRow(manager, checking: checking)
        renderServiceRow(manager, checking: checking)
        renderAccessRow(health, checking: checking)
        renderCollectionRow(health, checking: checking)
        renderHero(manager, health: health, checking: checking)

        // Primary action follows what the extension needs next.
        let primary: String?
        switch manager.availability {
        case .notInstalled, .unavailable: primary = manager.availability == .notInstalled ? String(localized: "Install") : String(localized: "Reinstall")
        case .awaitingApproval: primary = String(localized: "Open System Settings")
        case .active, .fullDiskAccessRequired:
            primary = manager.isUpdateAvailable ? String(localized: "Update") : String(localized: "Reinstall")
        case .connecting, .needsRestart, .notEntitled: primary = nil
        }
        installButton.title = primary ?? String(localized: "Install")
        installButton.isHidden = primary == nil
        let primaryIsDefault = manager.availability == .notInstalled || manager.isUpdateAvailable || manager.availability == .awaitingApproval
        installButton.keyEquivalent = primaryIsDefault ? "\r" : ""
        installButton.isEnabled = !busy

        checkButton.isEnabled = !busy && !checking
        if checking || busy { checkSpinner.startAnimation(nil) } else { checkSpinner.stopAnimation(nil) }

        let installed = ![.notInstalled, .notEntitled, .connecting].contains(manager.availability) || manager.installed != nil
        uninstallButton.isHidden = !installed && manager.operation != .uninstalling
        uninstallButton.isEnabled = !busy && !checking

        contentChanged()
    }

    private func renderHero(_ manager: ExtensionManager, health: MonitorHealth?, checking: Bool) {
        let title: String
        let detail: String
        let symbol: String
        let color: NSColor
        var live = false
        let rows = [extensionRow.state, accessRow.state, serviceRow.state, collectionRow.state]

        if manager.operation == .uninstalling || viewModel.isRemovingMonitor {
            (title, detail, symbol, color) = (String(localized: "Uninstalling…"), String(localized: "Waiting for macOS to remove the monitor extension."), "shield.slash", .systemGray)
        } else if manager.operation == .installing {
            (title, detail, symbol, color) = (String(localized: "Installing…"), String(localized: "Waiting for macOS to install and approve the monitor extension."), "shield.lefthalf.filled", .systemBlue)
        } else if manager.availability == .notInstalled {
            (title, detail, symbol, color) = (String(localized: "Monitor Not Installed"), String(localized: "Sidewatch shows current processes and ports. Install the monitor to record agent history and enforce protection rules."), "shield.slash", .systemGray)
        } else if manager.availability == .notEntitled {
            (title, detail, symbol, color) = (String(localized: "Monitoring Unavailable"), String(localized: "This copy of Sidewatch isn't signed with the Endpoint Security entitlement."), "xmark.shield", .systemRed)
        } else if manager.availability == .needsRestart {
            (title, detail, symbol, color) = (String(localized: "Restart Required"), String(localized: "Restart your Mac to finish the change to the monitor extension."), "arrow.triangle.2.circlepath", .systemOrange)
        } else if rows.allSatisfy({ $0 == .ok }) {
            let mode = health?.activeMode.map(DisplayText.mode) ?? DisplayText.mode(.recordOnly)
            (title, detail, symbol, color) = (String(localized: "Monitor Active"), String(localized: "Collecting activity for your account in \(mode) mode."), "checkmark.shield.fill", .systemGreen)
            live = true
        } else if checking && rows.contains(.working) {
            (title, detail, symbol, color) = (String(localized: "Checking…"), String(localized: "Asking macOS and the monitor for their current state."), "shield.lefthalf.filled", .systemBlue)
        } else if rows.contains(.error) {
            (title, detail, symbol, color) = (String(localized: "Monitor Unavailable"), String(localized: "Resolve the problems below to record history and enforce rules."), "exclamationmark.shield.fill", .systemRed)
        } else {
            (title, detail, symbol, color) = (String(localized: "Needs Attention"), String(localized: "The monitor is installed but isn't collecting activity yet."), "exclamationmark.shield.fill", .systemOrange)
        }

        var meta: [String] = []
        if let installed = manager.installed {
            meta.append(String(localized: "Version \(installed.version) (\(installed.build))"))
        } else if let bundled = manager.bundled {
            meta.append(String(localized: "Included version \(bundled.version) (\(bundled.build))"))
        }
        if manager.isUpdateAvailable, let bundled = manager.bundled {
            meta.append(String(localized: "Update to \(bundled.version) (\(bundled.build)) available"))
        }
        if let checked = manager.lastChecked {
            meta.append(Date().timeIntervalSince(checked) < 10
                        ? String(localized: "Checked just now")
                        : String(localized: "Checked \(DisplayText.relative(checked))"))
        }
        hero.set(title: title, detail: detail, meta: meta.joined(separator: "  ·  "), symbol: symbol, color: color, live: live, checking: checking)
    }

    private func renderExtensionRow(_ manager: ExtensionManager, checking: Bool) {
        switch (manager.operation, manager.availability) {
        case (.installing?, _):
            extensionRow.set(.working, String(localized: "Installing…"))
        case (.uninstalling?, _):
            extensionRow.set(.working, String(localized: "Removing…"))
        case (.checking?, _), (_, .connecting):
            extensionRow.set(.working, String(localized: "Checking…"))
        case (_, .active), (_, .fullDiskAccessRequired):
            if manager.isUpdateAvailable, let bundled = manager.bundled {
                extensionRow.set(.warning, String(localized: "Installed and enabled. This app includes a different version (\(bundled.version), build \(bundled.build))."),
                                 action: (String(localized: "Update"), { [weak self] in self?.viewModel.activateExtension() }))
            } else {
                extensionRow.set(.ok, String(localized: "Installed and enabled."))
            }
        case (_, .awaitingApproval):
            extensionRow.set(.warning, String(localized: "Waiting for your approval in System Settings."),
                             action: (String(localized: "Approve…"), { [weak self] in self?.viewModel.openExtensionSettings() }))
        case (_, .needsRestart):
            extensionRow.set(.warning, String(localized: "Restart your Mac to finish."))
        case (_, .notInstalled):
            extensionRow.set(.inactive, String(localized: "Not installed."))
        case (_, .notEntitled):
            extensionRow.set(.error, String(localized: "Not signed for Endpoint Security."))
        case (_, .unavailable):
            var action: (String, () -> Void)?
            if manager.errorCode == "extensionDisabled" {
                action = (String(localized: "Open Settings…"), { [weak self] in self?.viewModel.openExtensionSettings() })
            }
            extensionRow.set(.error, viewModel.extensionFailureMessage, action: action)
        }
    }

    private func renderServiceRow(_ manager: ExtensionManager, checking: Bool) {
        guard manager.availability == .active || manager.availability == .fullDiskAccessRequired else {
            serviceRow.set(.inactive, String(localized: "Available once the extension is enabled."))
            return
        }
        switch viewModel.link {
        case .connected:
            serviceRow.set(.ok, String(localized: "Connected."))
        case .connecting:
            serviceRow.set(.working, String(localized: "Connecting…"))
        case .idle:
            serviceRow.set(checking ? .working : .inactive, String(localized: "Not connected."))
        case .disconnected:
            serviceRow.set(.warning, String(localized: "Disconnected. History shown may be out of date."),
                           action: (String(localized: "Reconnect"), { [weak self] in self?.viewModel.perform(.reconnect) }))
        case .failed(_, let message):
            serviceRow.set(.error, message, action: (String(localized: "Reconnect"), { [weak self] in self?.viewModel.perform(.reconnect) }))
        }
    }

    private func renderAccessRow(_ health: MonitorHealth?, checking: Bool) {
        guard let health else {
            accessRow.set(checking && viewModel.link == .connecting ? .working : .inactive,
                          String(localized: "Checked by the monitor once it's connected."))
            return
        }
        switch health.availability {
        case .fullDiskAccessRequired:
            accessRow.set(.warning, String(localized: "Not granted. Turn on Sidewatch Monitor in Full Disk Access; collection starts automatically."),
                          action: (String(localized: "Open Settings…"), { [weak self] in self?.viewModel.openFullDiskAccess() }))
        case .active:
            accessRow.set(.ok, String(localized: "Granted."))
        default:
            accessRow.set(.inactive, String(localized: "Unknown while the monitor can't start collection."))
        }
    }

    private func renderCollectionRow(_ health: MonitorHealth?, checking: Bool) {
        guard let health else {
            collectionRow.set(checking && viewModel.link == .connecting ? .working : .inactive, String(localized: "Inactive."))
            return
        }
        if health.storageError != nil {
            collectionRow.set(.error, String(localized: "History storage is unavailable. New activity may not be saved."))
            return
        }
        switch health.availability {
        case .active:
            let mode = health.activeMode.map(DisplayText.mode) ?? DisplayText.mode(.recordOnly)
            let dropped = health.droppedEvents > 0 ? " " + String(localized: "\(Int(health.droppedEvents)) events were dropped.") : ""
            collectionRow.set(health.droppedEvents > 0 ? .warning : .ok, String(localized: "Collecting in \(mode) mode.") + dropped)
        case .fullDiskAccessRequired:
            collectionRow.set(.warning, String(localized: "Waiting for Full Disk Access."))
        case .notEntitled:
            collectionRow.set(.error, String(localized: "The monitor is missing the Endpoint Security entitlement."))
        default:
            collectionRow.set(.error, String(localized: "The monitor can't collect activity right now."))
        }
    }
}

/// A requirement row: status glyph, title, detail, and an optional fix-it button.
private final class RequirementRow: NSView {
    private let glyph = StatusGlyphView()
    private let row: SettingsRow
    private lazy var button: NSButton = {
        let button = ViewFactory.button("", target: self, action: #selector(performAction))
        button.controlSize = .small
        return button
    }()
    private var handler: (() -> Void)?
    private(set) var state: RequirementState = .inactive

    init(title: String) {
        row = SettingsRow(title: title, leading: glyph)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(_ state: RequirementState, _ detail: String, action: (String, () -> Void)? = nil) {
        self.state = state
        glyph.set(state)
        row.setDetail(detail, color: state == .error ? .systemRed : .secondaryLabelColor)
        handler = action?.1
        if let action, state != .working, state != .ok {
            button.title = action.0
            row.setAccessories([button])
        } else {
            row.setAccessories([])
        }
        setAccessibilityLabel("\(row.titleLabel.stringValue): \(state.accessibilityLabel). \(detail)")
    }

    @objc private func performAction() { handler?() }
}

// MARK: - Data

final class DataSettingsPane: SettingsPaneController {
    private let viewModel: ActivityViewModel
    private let rules: RuleViewModel
    private let sizeValue = SettingsRow.valueLabel()
    private let oldestValue = SettingsRow.valueLabel()
    private let locationValue = SettingsRow.valueLabel(monospaced: true)
    private let retentionPopup = NSPopUpButton()
    private let budgetPopup = NSPopUpButton()
    private let storage = SettingsSection(title: String(localized: "History Storage"))
    private let retention = SettingsSection(title: String(localized: "Retention"))
    private lazy var clearButton = ViewFactory.button(String(localized: "Clear History…"), target: self, action: #selector(clearHistory))
    private lazy var eraseButton = ViewFactory.button(String(localized: "Erase All Data…"), target: self, action: #selector(eraseAll))
    private let eraseSpinner = NSProgressIndicator()

    private static let retentionChoices = [1, 3, 7, 14, 30, 90, 365]
    private static let budgetChoices: [Int64] = [256, 512, 1024, 2048, 4096].map { Int64($0) * 1024 * 1024 }

    init(viewModel: ActivityViewModel, rules: RuleViewModel) {
        self.viewModel = viewModel
        self.rules = rules
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func build() {
        locationValue.stringValue = "/Library/Application Support/\(MonitorWire.hostID)/Users/\(getuid())"
        locationValue.toolTip = locationValue.stringValue
        locationValue.widthAnchor.constraint(lessThanOrEqualToConstant: 330).isActive = true
        storage.setRows([
            SettingsRow(title: String(localized: "Size on disk"), accessories: [sizeValue]),
            SettingsRow(title: String(localized: "Oldest activity"), accessories: [oldestValue]),
            SettingsRow(title: String(localized: "Location"), accessories: [locationValue])
        ])
        add(storage)

        for popup in [retentionPopup, budgetPopup] {
            popup.controlSize = .regular
            popup.target = self
            popup.translatesAutoresizingMaskIntoConstraints = false
        }
        retentionPopup.action = #selector(retentionChanged)
        budgetPopup.action = #selector(budgetChanged)
        retentionPopup.setAccessibilityLabel(String(localized: "Keep activity for"))
        budgetPopup.setAccessibilityLabel(String(localized: "Storage limit"))
        retention.setRows([
            SettingsRow(title: String(localized: "Keep activity for"), accessories: [retentionPopup]),
            SettingsRow(title: String(localized: "Storage limit"),
                        detail: String(localized: "The oldest activity is removed first when history grows past this size."),
                        accessories: [budgetPopup])
        ])
        add(retention)

        eraseButton.hasDestructiveAction = true
        eraseSpinner.style = .spinning
        eraseSpinner.controlSize = .small
        eraseSpinner.isDisplayedWhenStopped = false
        add(SettingsSection(title: String(localized: "Clean Up"), rows: [
            SettingsRow(title: String(localized: "Clear history"),
                        detail: String(localized: "Removes recorded activity and finished sessions. Rules, mode, and running services are kept."),
                        accessories: [clearButton]),
            SettingsRow(title: String(localized: "Erase all data"),
                        detail: String(localized: "Removes all history, protection rules, and settings, and returns Sidewatch to its defaults."),
                        accessories: [eraseSpinner, eraseButton])
        ], footer: String(localized: "Removed data isn't securely overwritten on disk.")))

        viewModel.observe { [weak self] change in
            if change.contains(.status) || change.contains(.configuration) || change.contains(.rows) { self?.render() }
        }
        rules.observe { [weak self] in self?.render() }
        render()
    }

    override func paneWillAppear() { render() }

    private func render() {
        guard isViewLoaded else { return }
        let connected = viewModel.isHistoryAvailable
        let snapshot = viewModel.monitorSnapshot
        sizeValue.stringValue = connected ? snapshot.map { DisplayText.bytes($0.storageBytes) } ?? "—" : "—"
        oldestValue.stringValue = connected ? snapshot?.oldestActivity.map(DisplayText.dateTime) ?? String(localized: "No activity") : "—"
        storage.setFooter(connected ? nil : String(localized: "History is stored by the monitor. Connect it to see and change these settings."))

        let configuration = connected ? rules.configuration : nil
        fill(retentionPopup, choices: Self.retentionChoices, selected: configuration?.retentionDays) {
            String(localized: "\($0) days")
        }
        fill(budgetPopup, choices: Self.budgetChoices, selected: configuration?.storageBudgetBytes) { DisplayText.bytes($0) }
        let editable = configuration != nil && !rules.isSubmitting
        retentionPopup.isEnabled = editable
        budgetPopup.isEnabled = editable
        if let error = rules.lastError, connected {
            retention.setFooter(error, color: .systemRed)
        } else {
            retention.setFooter(String(localized: "Old activity is removed hourly. Running services and the origins that explain them are always kept."))
        }

        let erasing = viewModel.isErasingData
        if erasing { eraseSpinner.startAnimation(nil) } else { eraseSpinner.stopAnimation(nil) }
        eraseButton.isEnabled = !erasing && !viewModel.isRemovingMonitor
        clearButton.isEnabled = connected && !erasing
        contentChanged()
    }

    private func fill<Value: Hashable & Comparable>(_ popup: NSPopUpButton, choices: [Value], selected: Value?, title: (Value) -> String) {
        var values = choices
        if let selected, !values.contains(selected) { values.append(selected); values.sort() }
        let titles = values.map(title)
        if popup.itemTitles != titles {
            popup.removeAllItems()
            for (value, text) in zip(values, titles) {
                popup.addItem(withTitle: text)
                popup.lastItem?.representedObject = value
            }
        }
        if let selected, let index = values.firstIndex(of: selected) {
            popup.selectItem(at: index)
        } else {
            // Unknown while disconnected: show a dash rather than guessing a value.
            popup.removeAllItems()
            popup.addItem(withTitle: "—")
        }
    }

    @objc private func retentionChanged() {
        guard let days = retentionPopup.selectedItem?.representedObject as? Int else { return }
        Task { _ = await rules.setRetention(days: days) }
    }

    @objc private func budgetChanged() {
        guard let bytes = budgetPopup.selectedItem?.representedObject as? Int64 else { return }
        Task { _ = await rules.setStorageBudget(bytes: bytes) }
    }

    @objc private func clearHistory() {
        guard let window = view.window else { return }
        DataActions.confirmClearHistory(in: window, viewModel: viewModel)
    }

    @objc private func eraseAll() {
        guard let window = view.window else { return }
        DataActions.confirmEraseAll(in: window, viewModel: viewModel)
    }
}
