import AppKit

/// Detail inspector: launch chain, process details, related file activity, Git diff, and
/// explicit per-process controls. Rendering only; all data comes from the view models.
final class InspectorViewController: NSViewController {
    private let viewModel: ActivityViewModel
    private let rules: RuleViewModel
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private var observers: [UUID] = []

    init(viewModel: ActivityViewModel, rules: RuleViewModel) {
        self.viewModel = viewModel
        self.rules = rules
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        scroll.setAccessibilityLabel(String(localized: "Inspector"))
        view = scroll
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observers.append(viewModel.observe { [weak self] change in
            guard let self else { return }
            if change.contains(.inspector) || change.contains(.page) {
                render()
            } else if change.contains(.status), currentState != renderedState {
                // The periodic refresh posts .status every few seconds. Rebuilding then would
                // reset the diff's scroll position and move keyboard and VoiceOver focus, so
                // only a change to something the inspector shows rebuilds it.
                render()
            }
        })
        rules.observe { [weak self] in
            if self?.viewModel.page == .rules { self?.render() }
        }
        render()
    }

    // MARK: Rendering

    private var renderedSubjectKey = ""

    /// Everything outside the subject row that the inspector draws.
    private struct RenderState: Equatable {
        var page: SidewatchPage
        var inspector: InspectorSubject
        var related: RelatedActivityState
        var diff: DiffState
        var feedback: ControlFeedback?
        var pending: Set<String>
        var historyAvailable: Bool
    }

    private var renderedState: RenderState?

    private var currentState: RenderState {
        RenderState(page: viewModel.page, inspector: viewModel.inspector, related: viewModel.relatedActivity,
                    diff: viewModel.diff, feedback: viewModel.controlFeedback, pending: viewModel.pendingControls,
                    historyAvailable: viewModel.isHistoryAvailable)
    }

    /// The diff view survives rebuilds of the same diff, keeping its scroll position and selection.
    private var cachedDiff: (text: String, view: NSView)?

    private var subjectKey: String {
        if viewModel.page == .rules { return "rule:" + (rules.selectedRuleID ?? "") }
        switch viewModel.inspector {
        case .none: return "none"
        case .agent(let row): return "agent:" + row.id
        case .port(let row): return "port:" + row.id
        case .leftover(let row): return "leftover:" + row.id
        case .activity(let record): return "activity:\(record.id)"
        }
    }

    private func render() {
        let key = subjectKey
        let subjectChanged = key != renderedSubjectKey
        renderedSubjectKey = key
        renderedState = currentState
        if subjectChanged {
            Motion.fade(stack, duration: Motion.standard)
            cachedDiff = nil
        }
        // A rebuild of the same subject keeps the reader's place: scroll offset and the
        // focused button are restored after the new views are in place.
        let focusedTitle = subjectChanged ? nil : focusedButtonTitle()
        let scrollOrigin = scroll.contentView.bounds.origin
        actionHandlers.removeAll()
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        defer {
            if subjectChanged, let first = stack.arrangedSubviews.first { Motion.entrance(first) }
            if !subjectChanged {
                view.layoutSubtreeIfNeeded()
                scroll.contentView.scroll(to: scrollOrigin)
                scroll.reflectScrolledClipView(scroll.contentView)
                if let focusedTitle { restoreFocus(toButtonTitled: focusedTitle) }
            }
        }
        if viewModel.page == .rules {
            renderRule()
            return
        }
        switch viewModel.inspector {
        case .none:
            renderPlaceholder()
        case .agent(let row):
            renderAgent(row)
        case .port(let row):
            renderPort(row)
        case .leftover(let row):
            renderLeftover(row)
        case .activity(let activity):
            renderActivity(activity)
        }
    }

    private func renderPlaceholder() {
        let label = ViewFactory.label(String(localized: "No Selection"), font: .systemFont(ofSize: 15, weight: .semibold), color: .secondaryLabelColor)
        let detail = ViewFactory.label(String(localized: "Select an agent, event, port, or service to see where it came from."), color: .tertiaryLabelColor, wraps: true)
        add(label)
        add(detail)
    }

    private func renderAgent(_ row: AgentRow) {
        addHeader(title: row.agentName, subtitle: DisplayText.project(row.project), symbol: "terminal")
        var actions: [NSView] = []
        if let sessionID = row.sessionID {
            actions.append(actionButton(String(localized: "Show in Timeline"), symbol: "clock") { [weak self] in
                self?.viewModel.showTimeline(sessionID: sessionID)
            })
        }
        if let root = row.project?.root {
            actions.append(actionButton(String(localized: "Reveal Project"), symbol: "folder") { [weak self] in
                ProcessControlUI.reveal(root, in: self?.view.window)
            })
        }
        addActions(actions)

        addSection(String(localized: "Details"))
        var details: [(String, String)] = [
            (String(localized: "State"), DisplayText.runState(row.state)),
            (String(localized: "Started"), DisplayText.fullDateTime(row.startedAt))
        ]
        if let ended = row.endedAt {
            details.append((String(localized: "Ended"), DisplayText.fullDateTime(ended)))
            details.append((String(localized: "Duration"), DisplayText.duration(from: row.startedAt, to: ended)))
        }
        if let reason = DisplayText.endReason(row.endReason) { details.append((String(localized: "End Reason"), reason)) }
        details.append((String(localized: "Processes"), String(localized: "\(row.descendantCount) related, \(row.runningDescendantCount) running")))
        details.append((String(localized: "Listening"), String(localized: "\(row.endpointCount) endpoints")))
        details.append((String(localized: "Evidence"), DisplayText.evidence(row.evidence)))
        if let root = row.project?.root { details.append((String(localized: "Project Path"), root)) }
        if !row.command.isEmpty { details.append((String(localized: "Command"), row.command)) }
        addGrid(details)
        if row.sessionID == nil {
            addNote(String(localized: "Found in the current process list. Without monitor history, its launch chain and file activity are unknown."))
        }
        addNote(String(localized: "Chat titles and task contents aren't available from system events."))

        addLaunchChain(for: row.root)
        addRelatedActivity()
    }

    private func renderPort(_ row: PortRow) {
        let title = "\(DisplayText.transport(row.endpoint.transport)) \(DisplayText.address(row.endpoint)):\(row.endpoint.port)"
        addHeader(title: title, subtitle: DisplayText.executableName(row.execution), symbol: "network")
        addControls(target: row.controlTarget, record: row.execution, process: row.endpoint.execution.process,
                    activeAgents: row.attributions.filter { !$0.sessionEnded }.map(\.agentName))

        addSection(String(localized: "Endpoint"))
        var details: [(String, String)] = [
            (String(localized: "Protocol"), DisplayText.transport(row.endpoint.transport)),
            (String(localized: "Address"), DisplayText.address(row.endpoint)),
            (String(localized: "Port"), String(row.endpoint.port)),
            (String(localized: "Kind"), row.endpoint.transport == .tcp ? String(localized: "Listening socket") : String(localized: "Bound socket (may not be a server)")),
            (String(localized: "First Seen"), DisplayText.fullDateTime(row.endpoint.firstObservedAt)),
            (String(localized: "Source"), row.observedNatively ? String(localized: "Current process scan") : String(localized: "Monitor observation"))
        ]
        addGrid(details)

        addProcessDetails(row.execution, process: row.endpoint.execution.process)
        details = [(String(localized: "Runtime"), DisplayText.runtime(row.runtime)),
                   (String(localized: "Project"), row.project?.root ?? DisplayText.project(nil))]
        addGrid(details)
        addAttribution(row.attributions)
        addLaunchChain(for: viewModel.projection.index.historyIdentity(for: row.endpoint.execution.process) ?? row.endpoint.execution)
        addRelatedActivity()
    }

    private func renderLeftover(_ row: LeftoverRow) {
        addHeader(title: DisplayText.executableName(row.execution), subtitle: String(localized: "Still running after its agent exited"), symbol: "exclamationmark.triangle.fill")
        if row.isShared {
            addNote(String(localized: "Shared: this process is related to more than one agent session. Check that no one still needs it before stopping it."))
        }
        if row.isUncertain {
            addNote(String(localized: "Uncertain: part of this attribution is inferred rather than directly observed."))
        }
        addControls(target: row.controlTarget, record: row.execution, process: row.execution.identity.process, activeAgents: [])

        if let ended = row.agentEndedAt {
            addSection(String(localized: "Agent"))
            addGrid([
                (String(localized: "Agent Exited"), DisplayText.fullDateTime(ended)),
                (String(localized: "Running Since Exit"), DisplayText.duration(from: ended, to: Date()))
            ])
        }
        addProcessDetails(row.execution, process: row.execution.identity.process)
        if !row.endpoints.isEmpty {
            addSection(String(localized: "Listening"))
            addGrid(row.endpoints.map { (DisplayText.transport($0.transport), "\(DisplayText.address($0)):\($0.port)") })
        } else {
            addNote(String(localized: "This process has no listening ports."))
        }
        addAttribution(row.attributions)
        addLaunchChain(for: viewModel.projection.index.historyIdentity(for: row.execution.identity.process) ?? row.execution.identity)
        addRelatedActivity()
    }

    private func renderActivity(_ activity: ActivityRecord) {
        let path = activity.targetPath ?? activity.sourcePath
        let title = path.map { ($0 as NSString).lastPathComponent } ?? DisplayText.kind(activity.kind)
        addHeader(title: title, subtitle: "\(DisplayText.kind(activity.kind)) · \(DisplayText.outcome(activity))", symbol: "doc")

        var actions: [NSView] = []
        if let path {
            actions.append(actionButton(String(localized: "Reveal in Finder"), symbol: "folder") { [weak self] in
                ProcessControlUI.reveal(path, in: self?.view.window)
            })
            actions.append(actionButton(String(localized: "Copy Path"), symbol: "doc.on.doc") {
                ViewFactory.copyToPasteboard(path)
            })
        }
        if let execution = activity.execution {
            actions.append(actionButton(String(localized: "Same Process"), symbol: "line.3.horizontal.decrease.circle") { [weak self] in
                self?.viewModel.showTimeline(execution: execution)
            })
        }
        addActions(actions)

        addSection(String(localized: "Event"))
        var details: [(String, String)] = [
            (String(localized: "Time"), DisplayText.fullDateTime(activity.occurredAt)),
            (String(localized: "Event"), DisplayText.kind(activity.kind)),
            (String(localized: "Mode"), DisplayText.mode(activity.mode)),
            (String(localized: "Outcome"), DisplayText.outcome(activity)),
            (String(localized: "Evidence"), DisplayText.evidence(activity.evidence))
        ]
        if activity.kind == .rename {
            if let source = activity.sourcePath { details.append((String(localized: "From"), source)) }
            if let target = activity.targetPath { details.append((String(localized: "To"), target)) }
        } else if let path {
            details.append((String(localized: "Path"), path))
        }
        if let root = activity.projectRoot { details.append((String(localized: "Project"), root)) }
        if !activity.matchedRuleIDs.isEmpty {
            let names = activity.matchedRuleIDs.map { id in
                rules.configuration?.rules.first { $0.id == id }?.name ?? String(localized: "Deleted rule")
            }
            details.append((String(localized: "Matched Rules"), names.formatted(.list(type: .and))))
            details.append((String(localized: "Rule Revision"), String(activity.configurationRevision)))
        }
        if activity.kind == .gap {
            details.append((String(localized: "Reason"), DisplayText.gapReason(activity.detail ?? "")))
        }
        let agents = viewModel.agentNames(for: activity)
        details.append((String(localized: "Agent"), agents.isEmpty ? String(localized: "None recorded") : agents.formatted(.list(type: .and))))
        addGrid(details)
        if activity.evaluation == .deny && activity.response == .allow {
            addNote(String(localized: "Would Block: a rule matched in Dry Run. The operation was allowed."))
        }

        if let execution = activity.execution {
            addLaunchChain(for: execution)
        }

        if let path, activity.kind != .exec, activity.kind != .fork, activity.kind != .exit {
            addDiff(for: path)
        }
        addRelatedActivity(title: String(localized: "Activity from the Same Process"))
    }

    private func renderRule() {
        guard let rule = rules.selectedRule else {
            add(ViewFactory.label(String(localized: "No Rule Selected"), font: .systemFont(ofSize: 15, weight: .semibold), color: .secondaryLabelColor))
            add(ViewFactory.label(String(localized: "Select a rule to see its matches and blocked operations."), color: .tertiaryLabelColor, wraps: true))
            return
        }
        addHeader(title: rule.name, subtitle: rule.path, symbol: "lock.shield")
        addGrid([
            (String(localized: "Status"), rule.enabled ? String(localized: "Enabled") : String(localized: "Disabled")),
            (String(localized: "Target"), DisplayText.target(rule.target)),
            (String(localized: "Operations"), DisplayText.operations(rule.operations)),
            (String(localized: "Agents"), rule.agentIDs.isEmpty
                ? String(localized: "All recognized agents")
                : rules.agentDefinitions.filter { rule.agentIDs.contains($0.id) }.map(\.name).formatted(.list(type: .and)))
        ])
        switch rules.activation {
        case .unavailable:
            addNote(String(localized: "Not connected to the monitor. This rule isn't being evaluated."))
        case .pending:
            addNote(String(localized: "Waiting for the monitor to confirm these settings. The rule isn't active yet."))
        case .active(_, let mode):
            if mode == .recordOnly {
                addNote(String(localized: "The active mode is Record Only, so this rule isn't evaluated."))
            }
        }
        addSection(String(localized: "Recent Matches"))
        switch rules.ruleMatches {
        case .idle, .loading:
            add(ViewFactory.label(String(localized: "Loading…"), color: .secondaryLabelColor))
        case .unavailable:
            add(ViewFactory.label(String(localized: "Match history requires the monitor connection."), color: .secondaryLabelColor, wraps: true))
        case .failed(let message):
            add(ViewFactory.label(message, color: .systemRed, wraps: true))
        case .loaded(let records):
            if records.isEmpty {
                add(ViewFactory.label(String(localized: "No recent matches among the latest authorization events."), color: .secondaryLabelColor, wraps: true))
            }
            for record in records { add(activityLine(record)) }
        }
    }

    // MARK: Sections

    private func addControls(target: ExecutionIdentity?, record: ExecutionRecord?, process: ProcessIdentity, activeAgents: [String]) {
        let pending = viewModel.pendingControls.contains(process.stableID)
        let stop = actionButton(String(localized: "Stop…"), symbol: "stop.circle") { [weak self] in
            guard let self, let target, let window = view.window else { return }
            ProcessControlUI.confirmAndPerform(.stop, target: target, record: record, viewModel: viewModel, window: window, activeAgents: activeAgents)
        }
        let force = actionButton(String(localized: "Force Quit…"), symbol: "xmark.octagon") { [weak self] in
            guard let self, let target, let window = view.window else { return }
            ProcessControlUI.confirmAndPerform(.forceQuit, target: target, record: record, viewModel: viewModel, window: window, activeAgents: activeAgents)
        }
        stop.isEnabled = target != nil && !pending
        force.isEnabled = target != nil && !pending
        var views: [NSView] = [stop, force]
        if let command = record?.command {
            views.append(actionButton(String(localized: "Copy Command"), symbol: "doc.on.doc") { ViewFactory.copyToPasteboard(command) })
        }
        addActions(views)
        if target == nil {
            addNote(String(localized: "Stopping requires the monitor extension's live identity for this exact process. It can still be inspected."))
        }
        if let feedback = viewModel.controlFeedback, feedback.processKey == process.stableID {
            let color: NSColor = feedback.signalSent && feedback.auditErrorCode == nil ? .secondaryLabelColor : .systemRed
            add(ViewFactory.label(DisplayText.controlFeedback(feedback), color: color, wraps: true))
        }
    }

    private func addProcessDetails(_ record: ExecutionRecord?, process: ProcessIdentity) {
        addSection(String(localized: "Process"))
        var details: [(String, String)] = [(String(localized: "PID"), String(process.pid))]
        if let record {
            details.append((String(localized: "Executable"), record.executable.isEmpty ? String(localized: "Unavailable") : record.executable))
            details.append((String(localized: "Command"), record.command.isEmpty ? String(localized: "Unavailable") : record.command))
            details.append((String(localized: "Working Directory"), record.workingDirectory ?? String(localized: "Unavailable")))
            details.append((String(localized: "Started"), DisplayText.fullDateTime(record.startedAt)))
            details.append((String(localized: "State"), DisplayText.runState(viewModel.projection.index.runState(of: record))))
            if let signing = record.signingID { details.append((String(localized: "Signing ID"), signing)) }
        } else {
            details.append((String(localized: "Command"), String(localized: "Unavailable")))
        }
        addGrid(details)
    }

    private func addAttribution(_ attributions: [ServiceAttribution]) {
        addSection(String(localized: "Origin"))
        if attributions.isEmpty {
            addNote(String(localized: "Unknown origin. No recorded or inferred relationship to an agent."))
            return
        }
        addGrid(attributions.map { attribution in
            let state = attribution.sessionEnded ? String(localized: "exited") : String(localized: "running")
            return (attribution.agentName, String(localized: "\(DisplayText.evidence(attribution.evidence)), agent \(state)"))
        })
        if attributions.count > 1 {
            addNote(String(localized: "More than one agent is related to this process. Sidewatch shows known relationships but can't detect every consumer of a service."))
        }
    }

    private func addLaunchChain(for identity: ExecutionIdentity) {
        let chain = viewModel.launchChain(for: identity)
        addSection(String(localized: "Launch Chain"))
        guard !chain.isEmpty else {
            addNote(String(localized: "No launch history is available for this process."))
            return
        }
        for (offset, node) in chain.enumerated() {
            let name = DisplayText.executableName(node.execution)
            var line = String(repeating: "  ", count: min(offset, 8)) + (offset == 0 ? "" : "↳ ")
            line += node.agentName.map { String(localized: "\(name) (PID \(Int(node.identity.process.pid))) — \($0)") }
                ?? String(localized: "\(name) (PID \(Int(node.identity.process.pid)))")
            let label = ViewFactory.label(line, font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: node.agentName == nil ? .regular : .semibold), selectable: true)
            label.lineBreakMode = .byTruncatingTail
            var tooltip = node.execution?.command ?? ""
            if let link = node.link, let evidence = node.linkEvidence {
                let kind = link == .exec ? String(localized: "exec") : String(localized: "fork")
                tooltip += "\n" + String(localized: "Started from the process above by \(kind) (\(DisplayText.evidence(evidence)))")
            }
            label.toolTip = tooltip
            label.setAccessibilityLabel(line)
            add(label)
        }
        let weak = chain.compactMap(\.linkEvidence).contains { $0 != .observed }
        if weak {
            addNote(String(localized: "Some links are inferred from process lists rather than recorded launches."))
        }
        if let responsible = viewModel.responsibleRecord(for: identity) {
            addNote(String(localized: "Responsible process (supplementary evidence): \(DisplayText.executableName(responsible))"))
        }
    }

    private func addRelatedActivity(title: String = String(localized: "Related Activity")) {
        addSection(title)
        switch viewModel.relatedActivity {
        case .idle, .loading:
            add(ViewFactory.label(String(localized: "Loading…"), color: .secondaryLabelColor))
        case .unavailable:
            add(ViewFactory.label(String(localized: "Activity history requires the monitor extension."), color: .secondaryLabelColor, wraps: true))
        case .failed(let message):
            add(ViewFactory.label(message, color: .systemRed, wraps: true))
        case .loaded(let records):
            let fileRecords = records.filter { $0.sourcePath != nil || $0.targetPath != nil }
            if fileRecords.isEmpty {
                add(ViewFactory.label(String(localized: "No file activity recorded."), color: .secondaryLabelColor))
            }
            for record in fileRecords.prefix(30) { add(activityLine(record)) }
        }
    }

    private func activityLine(_ record: ActivityRecord) -> NSView {
        let path = record.targetPath ?? record.sourcePath ?? ""
        let text = "\(record.occurredAt.formatted(date: .omitted, time: .standard))  \(DisplayText.kind(record.kind))  \(DisplayText.outcome(record))  \(path)"
        let label = ViewFactory.label(text, font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular), selectable: true)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = path
        return label
    }

    private func addDiff(for path: String) {
        addSection(String(localized: "Changes Since Last Commit"))
        switch viewModel.diff {
        case .idle:
            addActions([actionButton(String(localized: "Show Git Diff"), symbol: "plusminus") { [weak self] in
                self?.viewModel.loadDiff(forFile: path)
            }])
        case .loading:
            add(ViewFactory.label(String(localized: "Loading…"), color: .secondaryLabelColor))
        case .loaded(let result):
            switch result {
            case .diff(let repository, let text, let truncated):
                addNote(String(localized: "Current working copy compared with HEAD in \((repository as NSString).lastPathComponent). This may include edits by other tools or people and doesn't show which agent changed each line."))
                add(diffView(text))
                if truncated { addNote(String(localized: "The diff is too large and was truncated.")) }
            case .noChanges:
                addNote(String(localized: "No differences from the last commit."))
            case .noBaseline:
                addNote(String(localized: "This file has no committed version, so there's nothing to compare it with."))
            case .notInRepository:
                addNote(String(localized: "This file isn't in a Git repository, so no diff is available."))
            case .gitUnavailable:
                addNote(String(localized: "Git isn't available. Install the Command Line Tools to view diffs."))
            case .failed(let status):
                addNote(String(localized: "Git couldn't produce a diff (status \(Int(status)))."))
            }
        }
    }

    private func diffView(_ text: String) -> NSView {
        if let cachedDiff, cachedDiff.text == text { return cachedDiff.view }
        let view = makeDiffView(text)
        cachedDiff = (text, view)
        return view
    }

    private func makeDiffView(_ text: String) -> NSView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let attributed = NSMutableAttributedString()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                attributes[.foregroundColor] = NSColor.systemGreen
                attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.12)
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                attributes[.foregroundColor] = NSColor.systemRed
                attributes[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.12)
            } else if line.hasPrefix("@@") {
                attributes[.foregroundColor] = NSColor.systemBlue
                attributes[.backgroundColor] = NSColor.systemBlue.withAlphaComponent(0.08)
            } else if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("+++") || line.hasPrefix("---") {
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            } else {
                attributes[.foregroundColor] = NSColor.labelColor
            }
            attributed.append(NSAttributedString(string: String(line) + "\n", attributes: attributes))
        }
        textView.textStorage?.setAttributedString(attributed)
        textView.setAccessibilityLabel(String(localized: "Git diff"))
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 280).isActive = true
        return scroll
    }

    // MARK: Focus

    private func focusedButtonTitle() -> String? {
        guard let button = view.window?.firstResponder as? NSButton, button.isDescendant(of: stack) else { return nil }
        return button.title
    }

    private func restoreFocus(toButtonTitled title: String) {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            for subview in view.subviews { if let match = find(subview) { return match } }
            return nil
        }
        guard let button = find(stack), button.canBecomeKeyView else { return }
        view.window?.makeFirstResponder(button)
    }

    // MARK: Building blocks

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -28).isActive = true
        if view is NSScrollView || view is NSGridView {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
    }

    private func addHeader(title: String, subtitle: String, symbol: String) {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        let titleLabel = ViewFactory.label(title, font: .systemFont(ofSize: 16, weight: .semibold), selectable: true)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        let subtitleLabel = ViewFactory.label(subtitle, color: .secondaryLabelColor, selectable: true)
        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let header = NSStackView(views: [icon, text])
        header.spacing = 8
        header.alignment = .centerY
        add(header)
    }

    private func addSection(_ title: String) {
        let box = NSBox()
        box.boxType = .separator
        add(box)
        box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        add(ViewFactory.sectionHeader(title.uppercased(with: .current)))
    }

    private func addGrid(_ rows: [(String, String)]) {
        let grid = NSGridView(views: rows.map { key, value in
            let keyLabel = ViewFactory.label(key, color: .secondaryLabelColor)
            keyLabel.alignment = .right
            let valueLabel = ViewFactory.label(value, selectable: true)
            valueLabel.lineBreakMode = .byTruncatingMiddle
            valueLabel.toolTip = value
            valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return [keyLabel, valueLabel]
        })
        grid.rowSpacing = 4
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        add(grid)
    }

    private func addNote(_ text: String) {
        add(ViewFactory.label(text, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, wraps: true))
    }

    private func addActions(_ views: [NSView]) {
        guard !views.isEmpty else { return }
        let row = NSStackView(views: views)
        row.spacing = 6
        row.orientation = .horizontal
        add(row)
    }

    private var actionHandlers: [ObjectIdentifier: () -> Void] = [:]

    private func actionButton(_ title: String, symbol: String, handler: @escaping () -> Void) -> NSButton {
        let button = ViewFactory.button(title, symbol: symbol, target: self, action: #selector(runAction(_:)))
        button.controlSize = .small
        button.setAccessibilityLabel(title)
        actionHandlers[ObjectIdentifier(button)] = handler
        return button
    }

    @objc private func runAction(_ sender: NSButton) {
        actionHandlers[ObjectIdentifier(sender)]?()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Confirmation and feedback for explicit Stop / Force Quit, shared by lists and the inspector.
@MainActor
enum ProcessControlUI {
    static func confirmAndPerform(_ operation: ControlOperation, target: ExecutionIdentity, record: ExecutionRecord?,
                                  viewModel: ActivityViewModel, window: NSWindow, activeAgents: [String] = []) {
        let name = DisplayText.executableName(record)
        let pid = Int(target.process.pid)
        let alert = NSAlert()
        switch operation {
        case .stop:
            alert.messageText = String(localized: "Stop “\(name)” (PID \(pid))?")
            alert.informativeText = String(localized: "Sidewatch sends a termination request (SIGTERM) to this exact process only. It may take time to exit or may ignore the request.")
            alert.addButton(withTitle: String(localized: "Stop"))
        case .forceQuit:
            alert.messageText = String(localized: "Force Quit “\(name)” (PID \(pid))?")
            alert.informativeText = String(localized: "Sidewatch immediately ends this exact process (SIGKILL). Unsaved work in that process will be lost.")
            alert.addButton(withTitle: String(localized: "Force Quit"))
            alert.alertStyle = .critical
        }
        if !activeAgents.isEmpty {
            alert.informativeText += "\n\n" + String(localized: "\(activeAgents.formatted(.list(type: .and))) may still be using this service.")
        }
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                let feedback = await viewModel.control(operation, target: target)
                if !feedback.signalSent {
                    let failure = NSAlert()
                    failure.messageText = operation == .stop
                        ? String(localized: "Couldn't Stop “\(name)”")
                        : String(localized: "Couldn't Force Quit “\(name)”")
                    failure.informativeText = DisplayText.controlFeedback(feedback)
                    failure.beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    static func reveal(_ path: String, in window: NSWindow?) {
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "The Item No Longer Exists")
        alert.informativeText = String(localized: "“\((path as NSString).lastPathComponent)” was moved or deleted after this activity was recorded.")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
