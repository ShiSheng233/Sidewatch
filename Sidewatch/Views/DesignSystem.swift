import AppKit
import QuartzCore

// MARK: - Motion

/// Central animation policy. Every animation goes through here so Reduce Motion is honored
/// consistently: movement is replaced by an instant change (or a short fade at most).
@MainActor
enum Motion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static let quick: TimeInterval = 0.18
    static let standard: TimeInterval = 0.28
    static let gentle: TimeInterval = 0.45

    static let easeOut = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
    static let easeInOut = CAMediaTimingFunction(name: .easeInEaseOut)

    static func animate(_ duration: TimeInterval = standard, _ changes: @escaping () -> Void, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard !reduceMotion else {
            changes()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = easeOut
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: { MainActor.assumeIsolated { completion?() } })
    }

    /// Cross-fades the next content change of a layer-backed view.
    static func fade(_ view: NSView, duration: TimeInterval = quick) {
        guard !reduceMotion else { return }
        view.wantsLayer = true
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        transition.timingFunction = easeInOut
        view.layer?.add(transition, forKey: "fade")
    }

    /// Rolls changed text vertically, like an odometer digit.
    static func roll(_ view: NSView, upward: Bool) {
        view.wantsLayer = true
        let transition = CATransition()
        if reduceMotion {
            transition.type = .fade
            transition.duration = quick
        } else {
            transition.type = .push
            transition.subtype = upward ? .fromTop : .fromBottom
            transition.duration = standard
            transition.timingFunction = easeOut
        }
        view.layer?.add(transition, forKey: "roll")
    }

    /// Slides a newly inserted view up while fading it in.
    static func entrance(_ view: NSView, delay: TimeInterval = 0) {
        guard !reduceMotion, let layer = view.layer ?? { view.wantsLayer = true; return view.layer }() else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = -6
        slide.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fade, slide]
        group.duration = gentle
        group.beginTime = CACurrentMediaTime() + delay
        group.fillMode = .backwards
        group.timingFunction = easeOut
        layer.add(group, forKey: "entrance")
    }
}

// MARK: - Palette

@MainActor
enum Palette {
    static func modeColor(_ mode: MonitoringMode?) -> NSColor {
        switch mode {
        case .recordOnly: .systemBlue
        case .dryRun: .systemOrange
        case .protect: .systemGreen
        case nil: .systemGray
        }
    }

    static func severityColor(_ severity: StatusNotice.Severity) -> NSColor {
        switch severity {
        case .info: .systemBlue
        case .warning: .systemOrange
        case .error: .systemRed
        }
    }

    static func severitySymbol(_ severity: StatusNotice.Severity) -> String {
        switch severity {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

/// Layer-backed view that re-resolves dynamic colors when the appearance changes.
class AppearanceAwareView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        updateColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColors()
    }

    /// Subclasses assign CGColors here, inside the current appearance.
    func updateColors() {}

    func resolved(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }
}

// MARK: - Live indicator dot

/// A small status dot. When live, a soft halo breathes outward (disabled under Reduce Motion).
final class LiveDotView: AppearanceAwareView {
    private let halo = CALayer()
    private let dot = CALayer()
    var color: NSColor = .systemGreen { didSet { updateColors() } }
    var isLive = false { didSet { if isLive != oldValue { updateAnimation() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer?.addSublayer(halo)
        layer?.addSublayer(dot)
        widthAnchor.constraint(equalToConstant: 10).isActive = true
        heightAnchor.constraint(equalToConstant: 10).isActive = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        halo.frame = bounds
        halo.cornerRadius = bounds.width / 2
        dot.frame = bounds.insetBy(dx: 2, dy: 2)
        dot.cornerRadius = dot.frame.width / 2
    }

    override func updateColors() {
        dot.backgroundColor = resolved(color)
        halo.backgroundColor = resolved(color.withAlphaComponent(0.35))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    private func updateAnimation() {
        halo.removeAllAnimations()
        guard isLive, window != nil, !Motion.reduceMotion else {
            halo.opacity = isLive ? 1 : 0
            return
        }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.6
        scale.toValue = 1.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.8
        group.repeatCount = .infinity
        group.timingFunction = Motion.easeOut
        halo.add(group, forKey: "breathe")
    }
}

// MARK: - Pill

/// Capsule showing the extension-confirmed mode (or why none is active).
final class StatusPillView: AppearanceAwareView {
    private let dot = LiveDotView()
    private let label = NSTextField(labelWithString: "")
    private var tint: NSColor = .systemGray
    private let stack = NSStackView()
    /// When false the pill draws no capsule of its own, for hosts (such as the toolbar's glass
    /// item background) that already provide one.
    var drawsChrome = true { didSet { stack.edgeInsets = drawsChrome ? NSEdgeInsets(top: 3, left: 9, bottom: 3, right: 11) : NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 8); updateColors() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        stack.setViews([dot, label], in: .leading)
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 9, bottom: 3, right: 11)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    func set(text: String, color: NSColor, live: Bool, accessibilityText: String) {
        if label.stringValue != text {
            if !label.stringValue.isEmpty { Motion.fade(label) }
            label.stringValue = text
        }
        tint = color
        dot.color = color
        dot.isLive = live
        label.textColor = drawsChrome ? color : (live ? .labelColor : .secondaryLabelColor)
        setAccessibilityLabel(accessibilityText)
        toolTip = accessibilityText
        updateColors()
    }

    override func updateColors() {
        guard drawsChrome else {
            layer?.backgroundColor = nil
            layer?.borderWidth = 0
            return
        }
        layer?.backgroundColor = resolved(tint.withAlphaComponent(0.14))
        layer?.borderColor = resolved(tint.withAlphaComponent(0.35))
        layer?.borderWidth = 1
    }
}

// MARK: - Notices

/// Full-width info bar, one line per notice, separated by hairlines. Rows slide in and the
/// bar collapses smoothly when notices change.
final class NoticeStackView: NSView {
    var onAction: ((StatusNotice.Action) -> Void)?
    private let stack = NSStackView()
    private var current: [StatusNotice] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ notices: [StatusNotice]) {
        guard notices != current else { return }
        let previous = Set(current)
        current = notices
        let animated = window != nil
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, notice) in notices.enumerated() {
            let row = NoticeView(notice: notice) { [weak self] action in self?.onAction?(action) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if animated, !previous.contains(notice) {
                Motion.entrance(row, delay: Double(index) * 0.04)
            }
        }
        if animated {
            Motion.animate(Motion.standard) { self.superview?.layoutSubtreeIfNeeded() }
        }
    }
}

private final class NoticeView: AppearanceAwareView {
    private let notice: StatusNotice
    private let handler: (StatusNotice.Action) -> Void
    private let text: NSTextField
    private let topRule = CALayer()
    private let bottomRule = CALayer()

    init(notice: StatusNotice, handler: @escaping (StatusNotice.Action) -> Void) {
        self.notice = notice
        self.handler = handler
        // Headline and detail share one sentence-like line: bold lead-in, quiet detail.
        let body = NSMutableAttributedString()
        let size = NSFont.smallSystemFontSize + 1
        if let title = notice.title {
            body.append(NSAttributedString(string: title + "  ", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.labelColor
            ]))
        }
        body.append(NSAttributedString(string: notice.message, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: notice.title == nil ? NSColor.labelColor : NSColor.secondaryLabelColor
        ]))
        self.text = NSTextField(labelWithAttributedString: body)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer?.addSublayer(topRule)
        layer?.addSublayer(bottomRule)

        let icon = NSImageView(image: NSImage(systemSymbolName: Palette.severitySymbol(notice.severity), accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        icon.contentTintColor = Palette.severityColor(notice.severity)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        text.lineBreakMode = .byWordWrapping
        text.maximumNumberOfLines = 0
        text.cell?.wraps = true
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [icon, text]
        if let action = notice.action {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let button = NSButton(title: Self.title(for: action), target: self, action: #selector(performAction))
            button.bezelStyle = .push
            button.controlSize = .small
            button.setContentHuggingPriority(.required, for: .horizontal)
            views.append(contentsOf: [spacer, button])
        }
        let stack = NSStackView(views: views)
        stack.spacing = 10
        stack.alignment = .firstBaseline
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(notice.title.map { $0 + ". " + notice.message } ?? notice.message)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        topRule.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        bottomRule.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        CATransaction.commit()
        // A wrapping label needs its real width to report the height of every line.
        let width = text.frame.width
        if width > 0, abs(text.preferredMaxLayoutWidth - width) > 0.5 {
            text.preferredMaxLayoutWidth = width
            needsLayout = true
        }
    }

    override func updateColors() {
        let color = Palette.severityColor(notice.severity)
        layer?.backgroundColor = resolved(color.withAlphaComponent(0.07))
        topRule.backgroundColor = resolved(.separatorColor)
        bottomRule.backgroundColor = resolved(.separatorColor)
    }

    @objc private func performAction() {
        if let action = notice.action { handler(action) }
    }

    static func title(for action: StatusNotice.Action) -> String {
        switch action {
        case .installExtension: String(localized: "Install…")
        case .openExtensionSettings: String(localized: "Open System Settings")
        case .openFullDiskAccess: String(localized: "Open Full Disk Access")
        case .reconnect: String(localized: "Reconnect")
        case .refresh: String(localized: "Try Again")
        }
    }
}

// MARK: - Animated table updates

@MainActor
enum TableDiff {
    /// Applies an identity-based diff with row animations. Falls back to a plain reload when the
    /// change is large (or Reduce Motion is on), so big refreshes stay instant.
    static func apply(to table: NSTableView, old: [String], new: [String], changed: Set<String> = []) {
        let difference = new.difference(from: old).inferringMoves()
        let churn = difference.insertions.count + difference.removals.count
        // The common periodic refresh: same rows, some values changed. Reload just those
        // cells so selection, focus, and scroll position are untouched.
        if churn == 0, table.numberOfRows == new.count {
            let refreshed = IndexSet(new.enumerated().compactMap { changed.contains($0.element) ? $0.offset : nil })
            if !refreshed.isEmpty {
                table.reloadData(forRowIndexes: refreshed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
            return
        }
        guard window(of: table) != nil, !old.isEmpty, churn > 0, churn <= 60, !Motion.reduceMotion else {
            table.reloadData()
            return
        }
        table.beginUpdates()
        var removals = IndexSet()
        var insertions = IndexSet()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }
        table.removeRows(at: removals, withAnimation: [.effectFade, .slideUp])
        table.insertRows(at: insertions, withAnimation: [.effectFade, .slideDown])
        table.endUpdates()
        // Refresh content of rows that stayed but whose values changed.
        let refreshed = IndexSet(new.enumerated().compactMap { changed.contains($0.element) && !insertions.contains($0.offset) ? $0.offset : nil })
        if !refreshed.isEmpty {
            table.reloadData(forRowIndexes: refreshed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
    }

    private static func window(of view: NSView) -> NSWindow? { view.window }
}
