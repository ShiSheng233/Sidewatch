import AppKit

/// Agent Disk settings: which session folders the audit reads, and extra folders the user adds
/// because an app launched from the Dock can't see variables set in a shell profile.
final class AgentDiskSettingsPane: SettingsPaneController {
    private let disk: AgentDiskViewModel
    private let folders = SettingsSection(title: String(localized: "Session Folders"))
    private lazy var addButton = ViewFactory.button(String(localized: "Add Folder…"), symbol: "plus",
                                                    target: self, action: #selector(addFolder))
    private var renderedSignature: [String] = []

    init(disk: AgentDiskViewModel) {
        self.disk = disk
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func build() {
        add(folders)
        let addRow = SettingsRow(
            title: String(localized: "Additional session folder"),
            detail: String(localized: "Add custom CODEX_HOME, CLAUDE_CONFIG_DIR, or other session log folders."),
            accessories: [addButton]
        )
        add(SettingsSection(title: nil, rows: [addRow],
                            footer: String(localized: "Add all custom session folders so active files aren't cleaned up early.")))
        disk.observe { [weak self] change in
            if change.contains(.report) || change.contains(.policy) { self?.render() }
        }
        render()
    }

    override func paneWillAppear() { render() }

    // MARK: Rendering

    /// Shown roots: every custom folder, plus default locations that exist. Missing defaults
    /// would only list agents the user doesn't have.
    private var visibleRoots: [AgentDiskSessionRoot] {
        let scanned = disk.sessionRoots
        var roots = scanned.filter { $0.exists || $0.isCustom }
        // A folder added since the last scan is listed right away; the scan fills in whether it exists.
        // A folder that duplicates a default location is still listed so it can be removed.
        for folder in disk.policy.sessionFolders where !roots.contains(where: { $0.folder == folder }) {
            roots.append(AgentDiskSessionRoot(provider: folder.provider, path: folder.path, folder: folder, exists: true))
        }
        return roots
    }

    private func render() {
        guard isViewLoaded else { return }
        let roots = visibleRoots
        let signature = roots.map { "\($0.provider)\u{0}\($0.path)\u{0}\($0.isCustom)\u{0}\($0.exists)" }
            + [disk.hasScanned ? "scanned" : "pending"]
        guard signature != renderedSignature else { return }
        renderedSignature = signature

        if roots.isEmpty {
            let row = SettingsRow(title: disk.hasScanned
                ? String(localized: "No session folders found")
                : String(localized: "Looking for session folders…"))
            row.titleLabel.textColor = .secondaryLabelColor
            folders.setRows([row])
        } else {
            folders.setRows(roots.map(row(for:)))
        }
        folders.setFooter(String(localized: "Automatically includes default agent folders and visible environment variables (CODEX_HOME, CLAUDE_CONFIG_DIR, XDG_DATA_HOME, PI_CODING_AGENT_DIR)."))
        contentChanged()
    }

    private func row(for root: AgentDiskSessionRoot) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: root.isCustom ? "folder.badge.person.crop" : "folder",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        icon.contentTintColor = root.exists ? .controlAccentColor : .tertiaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true

        var accessories: [NSView] = []
        if !root.exists {
            accessories.append(ViewFactory.label(String(localized: "Not found"),
                                                 font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                                                 color: .systemOrange))
        }
        if root.isCustom {
            let remove = FolderButton(image: NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: String(localized: "Remove Folder")) ?? NSImage(),
                                      target: self, action: #selector(removeFolder(_:)))
            remove.isBordered = false
            remove.symbolConfiguration = .init(pointSize: 14, weight: .regular)
            remove.contentTintColor = .secondaryLabelColor
            remove.toolTip = String(localized: "Remove Folder")
            remove.translatesAutoresizingMaskIntoConstraints = false
            remove.widthAnchor.constraint(equalToConstant: 22).isActive = true
            remove.heightAnchor.constraint(equalToConstant: 22).isActive = true
            remove.folder = root.folder
            accessories.append(remove)
        }

        let row = SettingsRow(title: Self.providerName(root.provider), detail: root.path,
                              leading: icon, accessories: accessories)
        row.detailLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        row.detailLabel.lineBreakMode = .byTruncatingMiddle
        row.detailLabel.maximumNumberOfLines = 1
        row.detailLabel.toolTip = root.path
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel([Self.providerName(root.provider), root.path,
                                   root.exists ? nil : String(localized: "Not found")].compactMap { $0 }.joined(separator: ", "))
        return row
    }

    static func providerName(_ provider: String) -> String {
        switch provider {
        case "codex": String(localized: "Codex", comment: "Agent provider")
        case "claude": String(localized: "Claude Code", comment: "Agent provider")
        case "omp": String(localized: "omp", comment: "Agent provider")
        case "pi": String(localized: "pi", comment: "Agent provider")
        default: provider
        }
    }

    // MARK: Actions

    @objc private func addFolder() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose an agent's configuration folder or its session log folder.")

        let popup = NSPopUpButton()
        for provider in AgentLogProvider.allCases {
            popup.addItem(withTitle: Self.providerName(provider.rawValue))
            popup.lastItem?.representedObject = provider.rawValue
        }
        popup.setAccessibilityLabel(String(localized: "Agent"))
        let label = ViewFactory.label(String(localized: "Agent:"))
        let accessory = NSStackView(views: [label, popup])
        accessory.spacing = 8
        accessory.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url,
                  let provider = popup.selectedItem?.representedObject as? String else { return }
            MainActor.assumeIsolated {
                self?.disk.addSessionFolder(AgentSessionFolder(provider: provider,
                                                               path: url.standardizedFileURL.path))
            }
        }
    }

    @objc private func removeFolder(_ sender: FolderButton) {
        guard let folder = sender.folder else { return }
        disk.removeSessionFolder(folder)
    }
}

private final class FolderButton: NSButton {
    var folder: AgentSessionFolder?
}
