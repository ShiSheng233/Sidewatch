#if DEBUG
import AppKit

/// Debug-only UI evidence capture. When `SIDEWATCH_UI_SNAPSHOT_DIR` is set, the app renders its
/// own main window for every page in light and dark appearance and then quits. It uses the real
/// view models and real data; nothing is mocked. Not compiled into Release builds.
@MainActor
enum DebugSnapshots {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["SIDEWATCH_UI_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(window: NSWindow, viewModel: ActivityViewModel) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: appearance)
                for page in SidewatchPage.allCases {
                    viewModel.setPage(page)
                    try? await Task.sleep(for: .milliseconds(900))
                    let name = "\(page.rawValue)-\(appearance == .aqua ? "light" : "dark").png"
                    write(window, to: directory.appendingPathComponent(name))
                }
            }
            NSApp.terminate(nil)
        }
    }

    private static func write(_ window: NSWindow, to url: URL) {
        guard let frameView = window.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
