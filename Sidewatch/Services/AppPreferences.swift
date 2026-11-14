import Foundation

/// Preferences owned by this app (the monitor's settings live in its configuration).
/// Changes post `didChange` so app-level observers such as the Dock badge can update.
@MainActor
final class AppPreferences {
    static let shared = AppPreferences()
    static let didChange = Notification.Name("Sidewatch.AppPreferences.didChange")
    /// Posted after every app preference, window layout, and table layout was removed.
    static let didReset = Notification.Name("Sidewatch.AppPreferences.didReset")

    private enum Key {
        static let leftoverNotifications = "Sidewatch.leftoverNotifications"
        static let leftoverBadge = "Sidewatch.leftoverBadge"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.leftoverNotifications: true, Key.leftoverBadge: true])
    }

    /// Post a notification when an agent exits and leaves processes running.
    var leftoverNotifications: Bool {
        get { defaults.bool(forKey: Key.leftoverNotifications) }
        set { set(newValue, for: Key.leftoverNotifications) }
    }

    /// Show the number of leftover processes on the Dock icon.
    var leftoverBadge: Bool {
        get { defaults.bool(forKey: Key.leftoverBadge) }
        set { set(newValue, for: Key.leftoverBadge) }
    }

    /// Removes everything this app stored in its defaults domain, including window frames,
    /// split positions, and table column layouts, which AppKit saves there.
    func resetAll() {
        if let domain = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: domain)
        }
        NotificationCenter.default.post(name: Self.didReset, object: self)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func set(_ value: Bool, for key: String) {
        guard defaults.bool(forKey: key) != value else { return }
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
