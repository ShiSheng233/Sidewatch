import AppKit

/// Confirmation flows for destructive data and monitor actions, shared by the menus, the main
/// window, and Settings. Every flow is a sheet on the window the user acted in.
@MainActor
enum DataActions {
    static func confirmClearHistory(in window: NSWindow, viewModel: ActivityViewModel) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear Activity History?")
        alert.informativeText = String(localized: "Removes recorded events and finished sessions. Running services, rules, and mode are kept.")
        alert.addButton(withTitle: String(localized: "Clear History"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                if let message = await viewModel.clearHistory() {
                    showFailure(String(localized: "Couldn't Clear History"), message, in: window)
                }
            }
        }
    }

    static func confirmEraseAll(in window: NSWindow, viewModel: ActivityViewModel) {
        let connected = viewModel.isHistoryAvailable
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Erase All Sidewatch Data?")
        alert.informativeText = connected
            ? String(localized: "Permanently removes all history, sessions, rules, and preferences, and resets mode to Record Only. Active processes remain tracked. This can't be undone.")
            : String(localized: "Monitor disconnected: only app preferences and window layout will be reset.")
        alert.addButton(withTitle: connected ? String(localized: "Erase All Data") : String(localized: "Reset Preferences"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                if let message = await viewModel.eraseAllData() {
                    showFailure(String(localized: "Couldn't Erase Data"), message, in: window)
                }
            }
        }
    }

    static func confirmUninstall(in window: NSWindow, viewModel: ActivityViewModel) {
        let connected = viewModel.isHistoryAvailable
        let alert = NSAlert()
        alert.messageText = String(localized: "Uninstall the Sidewatch Monitor?")
        alert.informativeText = String(localized: "Activity history and protection stop until you install it again. macOS asks for an administrator's approval to remove the extension.")
        alert.showsSuppressionButton = true
        if let erase = alert.suppressionButton {
            erase.title = connected
                ? String(localized: "Also erase all recorded data and settings")
                : String(localized: "Also erase data (requires a monitor connection)")
            erase.state = connected ? .on : .off
            erase.isEnabled = connected
        }
        alert.addButton(withTitle: String(localized: "Uninstall"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let erase = connected && alert.suppressionButton?.state == .on
            Task { @MainActor in
                switch await viewModel.uninstallMonitor(eraseData: erase) {
                case .removed, .canceled:
                    break
                case .afterRestart:
                    let notice = NSAlert()
                    notice.messageText = String(localized: "Restart to Finish Uninstalling")
                    notice.informativeText = String(localized: "The monitor extension is removed when you restart your Mac.")
                    notice.beginSheetModal(for: window, completionHandler: nil)
                case .failed(let message):
                    showFailure(String(localized: "Couldn't Uninstall the Monitor"), message, in: window)
                }
            }
        }
    }

    private static func showFailure(_ title: String, _ message: String, in window: NSWindow) {
        let failure = NSAlert()
        failure.messageText = title
        failure.informativeText = message
        failure.beginSheetModal(for: window, completionHandler: nil)
    }
}
