import AppKit

/// Protection Rules page: mode selection, acknowledged state, rule list, and history storage.
final class RuleEditorViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let viewModel: ActivityViewModel
    private let rules: RuleViewModel
    private var displayed: [ProtectionRule] = []

    private let modeControl = NSSegmentedControl()
    private let modeExplanation = ViewFactory.label("", color: .secondaryLabelColor, wraps: true)
    private let activationPill = StatusPillView()
    private let errorLabel = ViewFactory.label("", color: .systemRed, wraps: true)
    private let spinner = NSProgressIndicator()
    private let table = NSTableView()
    private let emptyState = EmptyStateView()
    private lazy var addButton = ViewFactory.button(String(localized: "New Rule…"), symbol: "plus", target: self, action: #selector(addRule))
    private lazy var editButton = ViewFactory.button(String(localized: "Edit…"), symbol: "pencil", target: self, action: #selector(editRule))
    private lazy var deleteButton = ViewFactory.button(String(localized: "Delete…"), symbol: "trash", target: self, action: #selector(deleteRule))
    private let storageLabel = ViewFactory.label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, wraps: true)
    private let coverageLabel = ViewFactory.label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .tertiaryLabelColor, wraps: true)

    init(viewModel: ActivityViewModel, rules: RuleViewModel) {
        self.viewModel = viewModel
        self.rules = rules
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()

        modeControl.segmentCount = MonitoringMode.allCases.count
        for (index, mode) in MonitoringMode.allCases.enumerated() {
            modeControl.setLabel(DisplayText.mode(mode), forSegment: index)
            modeControl.setWidth(110, forSegment: index)
        }
        modeControl.trackingMode = .selectOne
        modeControl.segmentStyle = .automatic
        modeControl.controlSize = .large
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityLabel(String(localized: "Protection mode"))

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let modeTitle = ViewFactory.sectionHeader(String(localized: "MODE"))
        let modeRow = NSStackView(views: [modeControl, spinner, NSView(), activationPill])
        modeRow.spacing = 10
        modeRow.alignment = .centerY
        let modeCard = CardContainer(views: [modeTitle, modeRow, modeExplanation, coverageLabel, errorLabel])

        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editRule)
        table.setAccessibilityLabel(String(localized: "Protection rules"))
        for column in [
            ViewFactory.column("enabled", title: String(localized: "On"), width: 36, minWidth: 36),
            ViewFactory.column("name", title: String(localized: "Name"), width: 160),
            ViewFactory.column("target", title: String(localized: "Target"), width: 80),
            ViewFactory.column("path", title: String(localized: "Path"), width: 280),
            ViewFactory.column("operations", title: String(localized: "Operations"), width: 170),
            ViewFactory.column("agents", title: String(localized: "Agents"), width: 140)
        ] { table.addTableColumn(column) }
        table.autosaveName = "Sidewatch.rules.columns"
        table.autosaveTableColumns = true
        let scroll = ViewFactory.scrollingTable(table)

        for button in [addButton, editButton, deleteButton] { button.controlSize = .regular }
        let buttons = NSStackView(views: [addButton, editButton, deleteButton, NSView()])
        buttons.spacing = 8

        let storageTitle = ViewFactory.sectionHeader(String(localized: "HISTORY"))
        let clear = ViewFactory.button(String(localized: "Clear History…"), symbol: "clock.arrow.circlepath", target: nil, action: #selector(MainWindowController.clearHistory(_:)))
        let storageRow = NSStackView(views: [storageLabel, NSView(), clear])
        storageRow.alignment = .centerY
        let storageCard = CardContainer(views: [storageTitle, storageRow])

        let stack = NSStackView(views: [modeCard, buttons, scroll, storageCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        root.addSubview(stack)
        root.addSubview(emptyState)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            modeCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            storageCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            storageRow.widthAnchor.constraint(equalTo: storageCard.widthAnchor, constant: -28),
            modeRow.widthAnchor.constraint(equalTo: modeCard.widthAnchor, constant: -28),
            emptyState.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: scroll.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: scroll.bottomAnchor)
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rules.observe { [weak self] in self?.render() }
        viewModel.observe { [weak self] change in
            if change.contains(.rows) || change.contains(.status) || change.contains(.configuration) { self?.render() }
        }
        render()
    }

    // MARK: Rendering

    private func render() {
        let connected = rules.isConnected
        if let mode = rules.selectedMode, let index = MonitoringMode.allCases.firstIndex(of: mode) {
            modeControl.selectedSegment = index
            modeExplanation.stringValue = DisplayText.modeExplanation(mode)
        } else {
            modeControl.selectedSegment = -1
            modeExplanation.stringValue = String(localized: "Connect the monitor extension to choose a mode. Without it, no rule is evaluated or enforced.")
        }
        modeControl.isEnabled = connected && !rules.isSubmitting
        if rules.isSubmitting { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        switch rules.activation {
        case .unavailable:
            activationPill.set(text: String(localized: "Inactive"), color: .systemGray, live: false,
                               accessibilityText: String(localized: "Rules inactive: the monitor isn't connected."))
        case .active(let revision, let mode):
            activationPill.set(text: String(localized: "Active · Revision \(Int(revision))"), color: Palette.modeColor(mode),
                               live: viewModel.health?.availability == .active,
                               accessibilityText: String(localized: "\(DisplayText.mode(mode)) is active at revision \(Int(revision)), confirmed by the monitor."))
        case .pending(let selected, let active, _):
            let text = active.map { String(localized: "Pending · Active Revision \(Int($0))") } ?? String(localized: "Pending Confirmation")
            activationPill.set(text: text, color: .systemOrange, live: false,
                               accessibilityText: String(localized: "Revision \(Int(selected)) is waiting for the monitor to confirm it. It isn't active yet."))
        }
        coverageLabel.stringValue = String(localized: "Rules can prevent opening, deleting, and renaming or moving matched items. Creating and writing files is recorded but can't be blocked. Rules apply only to recognized agents and the processes they start.")

        if let error = rules.lastError {
            if errorLabel.stringValue != error || errorLabel.isHidden { Motion.fade(errorLabel) }
            errorLabel.stringValue = error
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }

        let previous = displayed.map(\.id)
        let previousSignatures = Dictionary(displayed.map { ($0.id, $0.hashValue) }, uniquingKeysWith: { a, _ in a })
        displayed = rules.rules
        let changedIDs = Set(displayed.compactMap { rule in previousSignatures[rule.id].flatMap { $0 != rule.hashValue ? rule.id : nil } })
        TableDiff.apply(to: table, old: previous, new: displayed.map(\.id), changed: changedIDs)
        if let id = rules.selectedRuleID, let index = displayed.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }

        addButton.isEnabled = connected && !rules.isSubmitting
        let hasSelection = table.selectedRow >= 0
        editButton.isEnabled = connected && hasSelection && !rules.isSubmitting
        deleteButton.isEnabled = connected && hasSelection && !rules.isSubmitting

        if displayed.isEmpty {
            emptyState.show(
                title: connected ? String(localized: "No Protection Rules") : String(localized: "Rules Unavailable"),
                detail: connected
                    ? String(localized: "Create a rule to keep agents from opening, deleting, renaming, or moving important files and folders.")
                    : String(localized: "Protection rules are stored and enforced by the monitor extension.")
            )
        } else {
            emptyState.isHidden = true
        }

        var storage: [String] = []
        if let bytes = rules.storageBytes { storage.append(String(localized: "Using \(DisplayText.bytes(bytes)) on disk.")) }
        if let oldest = rules.oldestActivity { storage.append(String(localized: "Oldest activity: \(DisplayText.dateTime(oldest)).")) }
        if let days = rules.retentionDays { storage.append(String(localized: "Activity is kept for \(days) days.")) }
        if storage.isEmpty { storage.append(String(localized: "History is stored by the monitor extension and isn't available while it's disconnected.")) }
        storage.append(String(localized: "Clearing history keeps running services, their origins, and your rules."))
        storageLabel.stringValue = storage.joined(separator: " ")
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue, row < displayed.count else { return nil }
        let rule = displayed[row]
        if column == "enabled" {
            let id = NSUserInterfaceItemIdentifier("rule.enabled")
            let button = (tableView.makeView(withIdentifier: id, owner: nil) as? NSButton) ?? {
                let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
                button.identifier = id
                return button
            }()
            button.state = rule.enabled ? .on : .off
            button.tag = row
            button.isEnabled = rules.isConnected && !rules.isSubmitting
            button.setAccessibilityLabel(String(localized: "Enable \(rule.name)"))
            return button
        }
        let cell = ViewFactory.textCell(in: tableView, identifier: "rule." + column)
        let dimmed: NSColor = rule.enabled ? .labelColor : .tertiaryLabelColor
        switch column {
        case "name":
            ViewFactory.configure(cell, text: rule.name, color: dimmed)
        case "target":
            ViewFactory.configure(cell, text: DisplayText.target(rule.target), color: dimmed,
                                  symbol: rule.target == .directory ? "folder" : "doc", symbolColor: .secondaryLabelColor)
        case "path":
            ViewFactory.configure(cell, text: rule.path, color: dimmed, monospaced: true)
        case "operations":
            ViewFactory.configure(cell, text: DisplayText.operations(rule.operations), color: dimmed)
        case "agents":
            let names = rules.agentDefinitions.filter { rule.agentIDs.contains($0.id) }.map(\.name)
            ViewFactory.configure(cell, text: rule.agentIDs.isEmpty ? String(localized: "All agents") : names.formatted(.list(type: .and)), color: dimmed)
        default:
            ViewFactory.configure(cell, text: "")
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        rules.selectRule(row >= 0 && row < displayed.count ? displayed[row].id : nil)
        let enabled = row >= 0 && rules.isConnected && !rules.isSubmitting
        editButton.isEnabled = enabled
        deleteButton.isEnabled = enabled
    }

    // MARK: Actions

    @objc private func modeChanged() {
        let index = modeControl.selectedSegment
        guard index >= 0, index < MonitoringMode.allCases.count else { return }
        let mode = MonitoringMode.allCases[index]
        guard mode != rules.selectedMode else { return }
        if mode == .protect, let window = view.window {
            let alert = NSAlert()
            alert.messageText = String(localized: "Turn On Protect Mode?")
            let enabled = rules.configuration?.rules.filter(\.enabled).count ?? 0
            alert.informativeText = String(localized: "Agents will be denied supported operations on files and folders matched by your \(enabled) enabled rules. Try Dry Run first to see what would be blocked.")
            alert.addButton(withTitle: String(localized: "Turn On Protect"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                if response == .alertFirstButtonReturn {
                    Task { _ = await self.rules.setMode(mode) }
                } else {
                    render()
                }
            }
            return
        }
        Task { _ = await rules.setMode(mode) }
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        guard sender.tag < displayed.count else { return }
        let rule = displayed[sender.tag]
        Task { _ = await rules.setEnabled(sender.state == .on, ruleID: rule.id) }
    }

    @objc private func addRule() { presentEditor(for: nil) }

    @objc private func editRule() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < displayed.count else { return }
        presentEditor(for: displayed[row])
    }

    @objc private func deleteRule() {
        let row = table.selectedRow
        guard row >= 0, row < displayed.count, let window = view.window else { return }
        let rule = displayed[row]
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete “\(rule.name)”?")
        alert.informativeText = String(localized: "The rule stops applying once the monitor confirms the change. Past matches stay in history.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { _ = await self.rules.delete(ruleID: rule.id) }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == String(UnicodeScalar(NSDeleteCharacter)!) && table.selectedRow >= 0 {
            deleteRule()
        } else {
            super.keyDown(with: event)
        }
    }

    func presentEditor(for rule: ProtectionRule?) {
        let form = RuleFormViewController(draft: rule.map(RuleDraft.init) ?? RuleDraft(), definitions: rules.agentDefinitions) { [weak self] draft in
            guard let self else { return false }
            return await rules.save(draft)
        }
        presentAsSheet(form)
    }
}

/// Rounded card container used to group controls.
final class CardContainer: AppearanceAwareView {
    init(views: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.detachesHiddenViews = true
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for view in views where view is NSTextField {
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -28).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateColors() {
        layer?.backgroundColor = resolved(.quaternarySystemFill)
        layer?.borderWidth = 0
    }
}

// MARK: - Rule form

/// Sheet for creating or editing one rule. The extension canonicalizes the path on save.
final class RuleFormViewController: NSViewController {
    private var draft: RuleDraft
    private let definitions: [AgentDefinition]
    private let onSave: (RuleDraft) async -> Bool

    private let nameField = NSTextField()
    private let targetControl = NSSegmentedControl(labels: [DisplayText.target(.directory), DisplayText.target(.file)], trackingMode: .selectOne, target: nil, action: nil)
    private let pathField = NSTextField()
    private var operationBoxes: [ProtectedOperation: NSButton] = [:]
    private let allAgentsBox = NSButton(checkboxWithTitle: String(localized: "All recognized agents"), target: nil, action: nil)
    private var agentBoxes: [String: NSButton] = [:]
    private let errorLabel = ViewFactory.label("", color: .systemRed, wraps: true)
    private let spinner = NSProgressIndicator()
    private lazy var saveButton = NSButton(title: String(localized: "Save"), target: self, action: #selector(save))

    init(draft: RuleDraft, definitions: [AgentDefinition], onSave: @escaping (RuleDraft) async -> Bool) {
        self.draft = draft
        self.definitions = definitions
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        title = draft.id == nil ? String(localized: "New Rule") : String(localized: "Edit Rule")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let heading = ViewFactory.label(title ?? "", font: .systemFont(ofSize: 17, weight: .semibold))

        nameField.placeholderString = String(localized: "For example, Production secrets")
        nameField.stringValue = draft.name
        nameField.setAccessibilityLabel(String(localized: "Rule name"))

        targetControl.selectedSegment = draft.target == .directory ? 0 : 1
        targetControl.target = self
        targetControl.action = #selector(targetChanged)
        targetControl.setAccessibilityLabel(String(localized: "Rule target type"))

        pathField.placeholderString = String(localized: "/Users/you/Projects/app/.env")
        pathField.stringValue = draft.path
        pathField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        pathField.setAccessibilityLabel(String(localized: "Protected path"))
        pathField.lineBreakMode = .byTruncatingMiddle
        let choose = NSButton(title: String(localized: "Choose…"), target: self, action: #selector(choosePath))
        let pathRow = NSStackView(views: [pathField, choose])
        pathRow.spacing = 8
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var operationViews: [NSView] = []
        for operation in ProtectedOperation.allCases {
            let box = NSButton(checkboxWithTitle: DisplayText.operation(operation), target: nil, action: nil)
            box.state = draft.operations.contains(operation) ? .on : .off
            operationBoxes[operation] = box
            operationViews.append(box)
        }
        let operations = NSStackView(views: operationViews)
        operations.spacing = 14

        allAgentsBox.state = draft.agentIDs.isEmpty ? .on : .off
        allAgentsBox.target = self
        allAgentsBox.action = #selector(scopeChanged)
        var agentViews: [NSView] = []
        for definition in definitions {
            let box = NSButton(checkboxWithTitle: definition.name, target: self, action: #selector(scopeChanged))
            box.state = draft.agentIDs.contains(definition.id) ? .on : .off
            agentBoxes[definition.id] = box
            agentViews.append(box)
        }
        let agents = NSStackView(views: agentViews)
        agents.spacing = 14

        let grid = NSGridView(views: [
            [label(String(localized: "Name:")), nameField],
            [label(String(localized: "Protect a:")), targetControl],
            [label(String(localized: "Path:")), pathRow],
            [label(String(localized: "Prevent:")), operations],
            [label(String(localized: "Applies to:")), allAgentsBox],
            [NSGridCell.emptyContentView, agents]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.column(at: 1).width = 420

        let note = ViewFactory.label(String(localized: "Folder rules include everything inside the folder, but not folders with similar names. Unrecognized processes never match."), font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, wraps: true)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.keyEquivalent = "\r"
        saveButton.bezelColor = .controlAccentColor
        let buttons = NSStackView(views: [spinner, NSView(), cancel, saveButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [heading, grid, note, errorLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.detachesHiddenViews = true
        errorLabel.isHidden = true
        NSLayoutConstraint.activate([
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            note.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            errorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520)
        ])
        view = stack
        scopeChanged()
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    @objc private func targetChanged() {
        draft.target = targetControl.selectedSegment == 0 ? .directory : .file
    }

    @objc private func scopeChanged() {
        let all = allAgentsBox.state == .on
        Motion.animate(Motion.quick) {
            for box in self.agentBoxes.values { box.animator().alphaValue = all ? 0.4 : 1 }
        }
        for box in agentBoxes.values { box.isEnabled = !all }
    }

    @objc private func choosePath() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = draft.target == .file
        panel.canChooseDirectories = draft.target == .directory
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = draft.target == .directory
            ? String(localized: "Choose a folder to protect.")
            : String(localized: "Choose a file to protect.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.pathField.stringValue = url.path
        }
    }

    @objc private func cancel() {
        dismiss(nil)
    }

    @objc private func save() {
        draft.name = nameField.stringValue
        draft.path = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.operations = Set(operationBoxes.filter { $0.value.state == .on }.map(\.key))
        draft.agentIDs = allAgentsBox.state == .on ? [] : Set(agentBoxes.filter { $0.value.state == .on }.map(\.key))
        if allAgentsBox.state == .off, draft.agentIDs.isEmpty {
            showError(String(localized: "Select at least one agent, or choose all recognized agents."))
            return
        }
        if let error = draft.validate(existingRuleCount: 0) {
            showError(RuleViewModel.message(for: error))
            return
        }
        saveButton.isEnabled = false
        spinner.startAnimation(nil)
        let draft = draft
        Task { [weak self] in
            guard let self else { return }
            let saved = await onSave(draft)
            spinner.stopAnimation(nil)
            saveButton.isEnabled = true
            if saved {
                dismiss(nil)
            } else {
                showError(String(localized: "The rule wasn't saved. See the message on the Protection Rules page."))
            }
        }
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        if errorLabel.isHidden {
            errorLabel.isHidden = false
            Motion.entrance(errorLabel)
        }
        if !Motion.reduceMotion, let layer = (view.window?.contentView ?? view).layer {
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.values = [0, -8, 8, -5, 5, -2, 0]
            shake.duration = 0.4
            layer.add(shake, forKey: "shake")
        }
    }
}
