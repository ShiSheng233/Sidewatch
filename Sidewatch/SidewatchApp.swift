import AppKit
import OSLog
import UserNotifications

@main
enum SidewatchMain {
    static func main() {
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            let delegate = AppDelegate()
            AppDelegate.shared = delegate
            application.delegate = delegate
            application.setActivationPolicy(.regular)
            application.run()
        }
    }
}

/// Application lifecycle. Collection runs in the system extension independently of this app;
/// quitting the app only stops this window's observation.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    private var viewModel: ActivityViewModel?
    private var rules: RuleViewModel?
    private var windowController: MainWindowController?
    private var settingsController: SettingsWindowController?
    private var notifiedLeftovers: Set<String> = []
    private var notificationsAuthorized: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.lifecycle.notice("Sidewatch host launched.")
        NSApp.mainMenu = MainMenu.build()

        let viewModel = ActivityViewModel(extensionManager: ExtensionManager(), connection: MonitorConnection())
        let rules = RuleViewModel(activity: viewModel)
        self.viewModel = viewModel
        self.rules = rules

        let controller = MainWindowController(viewModel: viewModel, rules: rules)
        windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()

        viewModel.observe { [weak self] change in
            if change.contains(.rows) { self?.leftoversChanged() }
        }
        NotificationCenter.default.addObserver(forName: AppPreferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.leftoversChanged() }
        }
        NotificationCenter.default.addObserver(forName: AppPreferences.didReset, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesReset() }
        }
        viewModel.start()
        #if DEBUG
        if let window = controller.window { DebugSnapshots.run(window: window, viewModel: viewModel) }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.showWindow(nil) }
        return true
    }

    // MARK: Windows

    func showMainWindow() {
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    func showSettings(_ pane: SettingsPane? = nil) {
        guard let viewModel, let rules else { return }
        let controller = settingsController ?? SettingsWindowController(viewModel: viewModel, rules: rules)
        settingsController = controller
        if let pane { controller.show(pane, animated: controller.window?.isVisible == true) }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettingsWindow(_ sender: Any?) { showSettings() }
    @objc func showMonitorSettings(_ sender: Any?) { showSettings(.monitor) }
    @objc func showDataSettings(_ sender: Any?) { showSettings(.data) }

    // MARK: Leftover reminders

    /// Badges the Dock icon and posts one reminder per newly confirmed leftover process.
    private func leftoversChanged() {
        guard let viewModel, viewModel.isHistoryAvailable else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        let leftovers = viewModel.projection.leftovers
        let preferences = AppPreferences.shared
        NSApp.dockTile.badgeLabel = leftovers.isEmpty || !preferences.leftoverBadge ? nil : leftovers.count.formatted()

        let current = Set(leftovers.map(\.id))
        let fresh = leftovers.filter { !notifiedLeftovers.contains($0.id) }
        notifiedLeftovers.formIntersection(current)
        guard !fresh.isEmpty else { return }
        notifiedLeftovers.formUnion(fresh.map(\.id))
        // Reminders that are switched off are still marked seen, so turning them back on
        // doesn't replay old leftovers.
        if preferences.leftoverNotifications { postReminder(for: fresh) }
    }

    /// After Erase All Data: forget which leftovers were announced and withdraw old reminders.
    private func preferencesReset() {
        notifiedLeftovers = []
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        leftoversChanged()
    }

    private func postReminder(for leftovers: [LeftoverRow]) {
        let center = UNUserNotificationCenter.current()
        let agents = Array(Set(leftovers.flatMap { $0.attributions.map(\.agentName) })).sorted()
        let count = leftovers.count
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Services Left Running")
        content.body = agents.isEmpty
            ? String(localized: "\(count) processes are still running after their agent exited.")
            : String(localized: "\(agents.formatted(.list(type: .and))) exited, but \(count) related processes are still running.")
        content.threadIdentifier = "leftovers"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

        Task { @MainActor in
            if notificationsAuthorized == nil {
                notificationsAuthorized = (try? await center.requestAuthorization(options: [.alert, .badge])) ?? false
            }
            guard notificationsAuthorized == true else { return }
            do {
                try await center.add(request)
            } catch {
                Diagnostics.interface.error("Leftover reminder could not be delivered.")
            }
        }
    }
}

/// Main menu built in code; titles come from the String Catalog.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let appName = String(localized: "Sidewatch")

        let app = submenu(appName, in: main)
        app.addItem(withTitle: String(localized: "About \(appName)"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Settings…"), action: #selector(AppDelegate.showSettingsWindow(_:)), keyEquivalent: ",")
        app.addItem(withTitle: String(localized: "Manage Monitor…"), action: #selector(AppDelegate.showMonitorSettings(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let services = NSMenuItem(title: String(localized: "Services"), action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Hide \(appName)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Quit \(appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(String(localized: "File"), in: main)
        file.addItem(withTitle: String(localized: "New Protection Rule…"), action: #selector(MainWindowController.newRule(_:)), keyEquivalent: "n")
        file.addItem(.separator())
        file.addItem(withTitle: String(localized: "Clear History…"), action: #selector(MainWindowController.clearHistory(_:)), keyEquivalent: "")
        file.addItem(withTitle: String(localized: "Erase All Data…"), action: #selector(MainWindowController.eraseAllData(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: String(localized: "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu(String(localized: "Edit"), in: main)
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Find…"), action: #selector(MainWindowController.performFind(_:)), keyEquivalent: "f")

        let view = submenu(String(localized: "View"), in: main)
        let pages: [(SidewatchPage, Selector)] = [
            (.agents, #selector(MainWindowController.showAgents(_:))),
            (.timeline, #selector(MainWindowController.showTimeline(_:))),
            (.ports, #selector(MainWindowController.showPorts(_:))),
            (.leftovers, #selector(MainWindowController.showLeftovers(_:))),
            (.diskAudit, #selector(MainWindowController.showAgentDisk(_:))),
            (.rules, #selector(MainWindowController.showRules(_:)))
        ]
        for (index, entry) in pages.enumerated() {
            view.addItem(withTitle: DisplayText.page(entry.0), action: entry.1, keyEquivalent: String(index + 1))
        }
        view.addItem(.separator())
        view.addItem(withTitle: String(localized: "Refresh"), action: #selector(MainWindowController.refresh(_:)), keyEquivalent: "r")
        view.addItem(.separator())
        let sidebar = view.addItem(withTitle: String(localized: "Toggle Sidebar"), action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        let inspector = view.addItem(withTitle: String(localized: "Toggle Inspector"), action: #selector(NSSplitViewController.toggleInspector(_:)), keyEquivalent: "i")
        inspector.keyEquivalentModifierMask = [.command, .option]
        let fullScreen = view.addItem(withTitle: String(localized: "Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        let window = submenu(String(localized: "Window"), in: main)
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: String(localized: "Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = submenu(String(localized: "Help"), in: main)
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ title: String, in main: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }
}
