import AppKit
import QuartzCore

// Grouped-form building blocks for the Settings window, in the style of System Settings:
// captioned, rounded inset groups whose rows are separated by inset hairlines.

/// A captioned group of rows with an optional footer.
final class SettingsSection: NSStackView {
    private let box = SettingsGroupBox()
    private let footerLabel = ViewFactory.label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, wraps: true)

    init(title: String?, rows: [NSView] = [], footer: String? = nil) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        detachesHiddenViews = true
        if let title {
            let caption = ViewFactory.label(title, font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold))
            caption.setAccessibilityRole(.staticText)
            addArrangedSubview(caption)
            setCustomSpacing(8, after: caption)
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
        }
        addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        addArrangedSubview(footerLabel)
        footerLabel.widthAnchor.constraint(equalTo: widthAnchor, constant: -4).isActive = true
        setFooter(footer)
        box.setRows(rows)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setRows(_ rows: [NSView]) { box.setRows(rows) }

    func setFooter(_ text: String?, color: NSColor = .secondaryLabelColor) {
        footerLabel.stringValue = text ?? ""
        footerLabel.textColor = color
        footerLabel.isHidden = (text ?? "").isEmpty
    }
}

/// The rounded group background holding rows and their separators.
private final class SettingsGroupBox: AppearanceAwareView {
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.detachesHiddenViews = true
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

    func setRows(_ rows: [NSView]) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = HairlineView()
                stack.addArrangedSubview(separator)
                separator.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12).isActive = true
                separator.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -12).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    override func updateColors() {
        layer?.backgroundColor = resolved(.quaternarySystemFill)
        layer?.borderColor = resolved(NSColor.separatorColor.withAlphaComponent(0.4))
        layer?.borderWidth = 0.5
    }
}

private final class HairlineView: AppearanceAwareView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateColors() { layer?.backgroundColor = resolved(.separatorColor) }
}

/// One form row: optional leading view, a title with optional detail, and trailing accessories.
final class SettingsRow: NSView {
    let titleLabel = ViewFactory.label("")
    let detailLabel = ViewFactory.label("", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, wraps: true)
    private let accessories = NSStackView()

    init(title: String, detail: String? = nil, leading: NSView? = nil, accessories views: [NSView] = []) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setDetail(detail)

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.detachesHiddenViews = true
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The text column absorbs free width so accessories sit flush right.
        text.setContentHuggingPriority(.init(1), for: .horizontal)

        accessories.spacing = 8
        accessories.alignment = .centerY
        accessories.setContentHuggingPriority(.required, for: .horizontal)
        accessories.setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessories(views)

        var arranged: [NSView] = []
        if let leading { arranged.append(leading) }
        arranged.append(contentsOf: [text, accessories])
        let row = NSStackView(views: arranged)
        row.spacing = 12
        row.alignment = .centerY
        row.distribution = .fill
        row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setDetail(_ text: String?, color: NSColor = .secondaryLabelColor) {
        let value = text ?? ""
        if detailLabel.stringValue != value, !detailLabel.stringValue.isEmpty, !value.isEmpty { Motion.fade(detailLabel) }
        detailLabel.stringValue = value
        detailLabel.textColor = color
        detailLabel.isHidden = value.isEmpty
    }

    func setAccessories(_ views: [NSView]) {
        guard views != accessories.arrangedSubviews else { return }
        for view in accessories.arrangedSubviews { accessories.removeArrangedSubview(view); view.removeFromSuperview() }
        for view in views { accessories.addArrangedSubview(view) }
    }

    /// A right-aligned value label, used for read-only facts.
    static func valueLabel(monospaced: Bool = false) -> NSTextField {
        let label = ViewFactory.label("", font: monospaced
            ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            color: .secondaryLabelColor, selectable: monospaced)
        label.alignment = .right
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

// MARK: - Status glyph

/// Status of one requirement, drawn as a filled SF Symbol or a small spinner while checking.
enum RequirementState: Equatable {
    case ok, warning, error, inactive, working

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        case .inactive, .working: "minus.circle.fill"
        }
    }

    var color: NSColor {
        switch self {
        case .ok: .systemGreen
        case .warning: .systemOrange
        case .error: .systemRed
        case .inactive, .working: .tertiaryLabelColor
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .ok: String(localized: "OK")
        case .warning: String(localized: "Needs attention")
        case .error: String(localized: "Problem")
        case .inactive: String(localized: "Inactive")
        case .working: String(localized: "Checking")
        }
    }
}

final class StatusGlyphView: NSView {
    private let image = NSImageView()
    private let spinner = NSProgressIndicator()
    private var state: RequirementState?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        image.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        image.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        addSubview(spinner)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(_ state: RequirementState) {
        guard state != self.state else { return }
        let previous = self.state
        self.state = state
        setAccessibilityLabel(state.accessibilityLabel)
        if state == .working {
            image.isHidden = true
            spinner.startAnimation(nil)
            return
        }
        spinner.stopAnimation(nil)
        image.isHidden = false
        image.contentTintColor = state.color
        guard let symbol = NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil) else { return }
        if previous == nil || Motion.reduceMotion {
            image.image = symbol
        } else {
            image.setSymbolImage(symbol, contentTransition: .replace)
            if state == .ok { image.addSymbolEffect(.bounce, options: .nonRepeating) }
        }
    }
}

// MARK: - Hero

/// Large status header: a tinted squircle badge with a symbol, a headline, and detail lines.
/// Color and symbol changes animate; while checking, the symbol pulses.
final class SettingsHeroView: AppearanceAwareView {
    private let badge = CAGradientLayer()
    private let badgeHost = AppearanceAwareView()
    private let symbol = NSImageView()
    private let title = ViewFactory.label("", font: .systemFont(ofSize: 17, weight: .semibold))
    private let liveDot = LiveDotView()
    private let detail = ViewFactory.label("", font: .systemFont(ofSize: NSFont.systemFontSize), color: .secondaryLabelColor, wraps: true)
    private let meta = ViewFactory.label("", font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular), color: .tertiaryLabelColor)
    private var tint: NSColor = .systemGray
    private var symbolName = ""
    private var pulsing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        badgeHost.translatesAutoresizingMaskIntoConstraints = false
        badgeHost.layer?.addSublayer(badge)
        badge.cornerRadius = 14
        badge.cornerCurve = .continuous
        badge.startPoint = CGPoint(x: 0.5, y: 1)
        badge.endPoint = CGPoint(x: 0.5, y: 0)
        symbol.symbolConfiguration = .init(pointSize: 26, weight: .semibold)
        symbol.contentTintColor = .white
        symbol.translatesAutoresizingMaskIntoConstraints = false
        badgeHost.addSubview(symbol)

        title.lineBreakMode = .byTruncatingTail
        let titleRow = NSStackView(views: [title, liveDot])
        titleRow.spacing = 8
        titleRow.alignment = .centerY
        let text = NSStackView(views: [titleRow, detail, meta])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setCustomSpacing(6, after: detail)
        text.detachesHiddenViews = true
        let row = NSStackView(views: [badgeHost, text])
        row.spacing = 14
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            badgeHost.widthAnchor.constraint(equalToConstant: 56),
            badgeHost.heightAnchor.constraint(equalToConstant: 56),
            symbol.centerXAnchor.constraint(equalTo: badgeHost.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: badgeHost.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -70)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badge.frame = badgeHost.bounds
        CATransaction.commit()
    }

    func set(title: String, detail: String, meta: String, symbol name: String, color: NSColor, live: Bool, checking: Bool) {
        if self.title.stringValue != title {
            if !self.title.stringValue.isEmpty { Motion.fade(self.title) }
            self.title.stringValue = title
        }
        if self.detail.stringValue != detail {
            if !self.detail.stringValue.isEmpty { Motion.fade(self.detail) }
            self.detail.stringValue = detail
        }
        self.meta.stringValue = meta
        self.meta.isHidden = meta.isEmpty
        liveDot.color = color
        liveDot.isLive = live
        liveDot.isHidden = !live

        if name != symbolName, let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            let first = symbolName.isEmpty
            symbolName = name
            if first || Motion.reduceMotion {
                symbol.image = image
            } else {
                symbol.setSymbolImage(image, contentTransition: .replace)
            }
        }
        if checking != pulsing {
            pulsing = checking
            if checking, !Motion.reduceMotion {
                symbol.addSymbolEffect(.pulse, options: .repeating)
            } else {
                symbol.removeAllSymbolEffects()
            }
        }
        if tint != color {
            tint = color
            updateColors(animated: window != nil && !Motion.reduceMotion)
        }
        setAccessibilityLabel([title, detail, meta].filter { !$0.isEmpty }.joined(separator: ". "))
    }

    override func updateColors() { updateColors(animated: false) }

    private func updateColors(animated: Bool) {
        let colors = [resolved(tint.blended(withFraction: 0.18, of: .white) ?? tint), resolved(tint.blended(withFraction: 0.12, of: .black) ?? tint)]
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? Motion.gentle : 0)
        CATransaction.setDisableActions(!animated)
        badge.colors = colors
        badge.shadowColor = resolved(tint)
        badge.shadowOpacity = 0.35
        badge.shadowRadius = 8
        badge.shadowOffset = CGSize(width: 0, height: -2)
        CATransaction.commit()
    }
}
