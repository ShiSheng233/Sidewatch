import AppKit

/// Small helpers for building standard AppKit controls in code.
@MainActor
enum ViewFactory {
    static func label(_ text: String = "", font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
                      color: NSColor = .labelColor, selectable: Bool = false, wraps: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = selectable
        if !wraps { field.lineBreakMode = .byTruncatingMiddle }
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func sectionHeader(_ text: String) -> NSTextField {
        let field = label(text, font: .boldSystemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
        field.setAccessibilityRole(.staticText)
        return field
    }

    static func button(_ title: String, symbol: String? = nil, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .push
        button.controlSize = .regular
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            button.image = image
            button.imagePosition = .imageLeading
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    static func scrollingTable(_ table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    static func column(_ identifier: String, title: String, width: CGFloat, minWidth: CGFloat = 40,
                       alignment: NSTextAlignment = .left) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.headerCell.alignment = alignment
        column.headerCell.setAccessibilityLabel(title)
        return column
    }

    /// Reusable text cell for view-based tables: an optional symbol followed by text.
    static func textCell(in table: NSTableView, identifier: String) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("cell." + identifier)
        if let cell = table.makeView(withIdentifier: id, owner: nil) as? NSTableCellView { return cell }
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.allowsDefaultTighteningForTruncation = true
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        let image = NSImageView()
        image.isHidden = true
        image.setContentHuggingPriority(.required, for: .horizontal)
        image.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [image, text])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.textField = text
        cell.imageView = image
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    /// `monospaced` is for commands, paths, and addresses; `numeric` uses tabular digits so
    /// PIDs, ports, and counts line up.
    static func configure(_ cell: NSTableCellView, text: String, color: NSColor = .labelColor,
                          monospaced: Bool = false, numeric: Bool = false, alignment: NSTextAlignment = .left,
                          symbol: String? = nil, symbolColor: NSColor? = nil,
                          symbolSize: CGFloat = 13, tooltip: String? = nil) {
        cell.textField?.stringValue = text
        cell.textField?.textColor = color
        cell.textField?.alignment = alignment
        if monospaced {
            cell.textField?.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        } else if numeric {
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } else {
            cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize)
        }
        cell.imageView?.symbolConfiguration = .init(pointSize: symbolSize, weight: .regular)
        cell.toolTip = tooltip ?? (text.count > 40 ? text : nil)
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            cell.imageView?.image = image
            cell.imageView?.contentTintColor = symbolColor
            cell.imageView?.isHidden = false
        } else {
            cell.imageView?.image = nil
            cell.imageView?.isHidden = true
        }
    }

    static func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Centered empty/error message shown over an empty list.
final class EmptyStateView: NSView {
    private let title = ViewFactory.label("", font: .systemFont(ofSize: 17, weight: .semibold), color: .secondaryLabelColor)
    private let detail = ViewFactory.label("", font: .systemFont(ofSize: NSFont.systemFontSize), color: .tertiaryLabelColor, wraps: true)

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        detail.alignment = .center
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(title: String, detail: String) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        setAccessibilityLabel(detail.isEmpty ? title : title + ". " + detail)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
