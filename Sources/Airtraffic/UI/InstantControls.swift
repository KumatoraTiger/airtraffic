import AppKit
import SwiftUI

// MARK: - Why this file exists
//
// Every clickable thing inside a board row lives on top of an `NSTableView`,
// because the rows are draggable (`onMove`). That table takes the mouse-down
// first: a SwiftUI `Button` is not an `NSView`, so the hosting view forwards
// the press to the table and the button only acts when the mouse is RELEASED.
// Two things follow, both of which the user feels as "the board is heavy":
//
// - nothing at all happens while the button is held, since `.buttonStyle(.plain)`
//   has no pressed appearance either, and
// - a press that drifts past the drag threshold is swallowed entirely — the
//   button never fires and no row moves, so the click simply vanishes.
//
// The cure is to put a real `NSView` in the way. AppKit hit-tests it before the
// table, delivers the press to it directly, and the table never arbitrates.
// Everything here is that one idea in three shapes: a chevron, a text button, a
// menu, and a catcher that lends the behaviour to any SwiftUI content.
//
// Text fields are deliberately left alone. Moving the caret on release is what
// every macOS text field does, and taking their mouse events away would break
// selection and cursor placement for nothing.

// MARK: - Any SwiftUI content, clicked instantly

extension View {
    /// Turns this view into a button that acts the instant it is pressed.
    ///
    /// Use it where the visuals are SwiftUI's — an SF Symbol, a capsule badge —
    /// and only the click needs to come from AppKit.
    func instantClick(
        _ label: String, enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        modifier(InstantClick(label: label, enabled: enabled, action: action))
    }
}

private struct InstantClick: ViewModifier {
    let label: String
    let enabled: Bool
    let action: () -> Void
    @State private var pressed = false

    func body(content: Content) -> some View {
        content
            // The press feedback the plain button style never had.
            .opacity(enabled ? (pressed ? 0.45 : 1) : 0.4)
            .overlay {
                if enabled {
                    ClickCatcher(action: action, onPress: { pressed = $0 })
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
            .accessibilityAction { action() }
    }
}

/// A transparent `NSView` laid over SwiftUI content. It answers the hit test,
/// so the press stops here instead of reaching the table underneath.
private struct ClickCatcher: NSViewRepresentable {
    let action: () -> Void
    let onPress: (Bool) -> Void

    final class Catcher: NSView {
        var action: () -> Void = {}
        var onPress: (Bool) -> Void = { _ in }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            onPress(true)
            action()
        }

        // Swallowed rather than passed on: letting either reach the table
        // would hand the gesture back to the row drag we just escaped.
        override func mouseDragged(with event: NSEvent) {}

        override func mouseUp(with event: NSEvent) { onPress(false) }
    }

    func makeNSView(context: Context) -> Catcher { Catcher() }

    func updateNSView(_ view: Catcher, context: Context) {
        view.action = action
        view.onPress = onPress
    }
}

// MARK: - Chevron

/// The expand / collapse chevron used on every board row.
struct DisclosureChevron: View {
    @Binding var expanded: Bool
    var help: (open: String, closed: String)
    /// Point size of the glyph, so a subtask can sit a notch smaller.
    var size: CGFloat = 9

    var body: some View {
        InstantSymbolButton(
            symbol: expanded ? "chevron.down" : "chevron.right",
            size: size,
            help: expanded ? help.open : help.closed
        ) {
            withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
        }
        .frame(width: size + 5, height: size + 5)
        .accessibilityLabel(expanded ? help.open : help.closed)
    }
}

/// An `NSButton` showing one SF Symbol, firing on press.
private struct InstantSymbolButton: NSViewRepresentable {
    let symbol: String
    let size: CGFloat
    let help: String
    let action: () -> Void

    func makeCoordinator() -> ActionCoordinator { ActionCoordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.title = ""
        button.contentTintColor = .tertiaryLabelColor
        button.target = context.coordinator
        button.action = #selector(ActionCoordinator.fire(_:))
        button.sendAction(on: [.leftMouseDown])
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.image = image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: size, weight: .semibold))
        button.toolTip = help
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSButton, context: Context
    ) -> CGSize? {
        CGSize(width: size + 5, height: size + 5)
    }
}

// MARK: - Text button

/// A text button that acts on press. `NSButton` keeps the native chrome that a
/// hand-drawn capsule would only approximate.
struct InstantButton: NSViewRepresentable {
    enum Look {
        /// Small bordered button, like `.buttonStyle(.bordered)` at `.small`.
        case bordered
        /// Borderless blue text, like `.buttonStyle(.link)`.
        case link
    }

    let title: String
    var look: Look = .bordered
    var help: String = ""
    var enabled: Bool = true
    let action: () -> Void

    func makeCoordinator() -> ActionCoordinator { ActionCoordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.target = context.coordinator
        button.action = #selector(ActionCoordinator.fire(_:))
        button.sendAction(on: [.leftMouseDown])
        button.controlSize = .small
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = enabled
        button.toolTip = help
        switch look {
        case .bordered:
            button.isBordered = true
            button.bezelStyle = .rounded
            button.title = title
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        case .link:
            button.isBordered = false
            button.bezelStyle = .inline
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .foregroundColor: enabled ? NSColor.linkColor : NSColor.disabledControlTextColor,
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                ])
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSButton, context: Context
    ) -> CGSize? {
        nsView.sizeToFit()
        return nsView.fittingSize
    }
}

// MARK: - Menu

/// A label that drops a native menu the instant it is pressed.
///
/// SwiftUI's `Menu` is a `Button` underneath and inherits the same problem, so
/// the menu is built and popped from AppKit instead.
struct InstantMenuButton: View {
    struct Item {
        let title: String
        let action: () -> Void
    }

    let title: String
    var help: String = ""
    var enabled: Bool = true
    /// Built on press, so a long task list costs nothing until it is asked for.
    let items: () -> [Item]

    var body: some View {
        HStack(spacing: 2) {
            Text(title)
            Image(systemName: "chevron.down")
                .font(.caption2)
        }
        .font(.callout)
        .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
        .fixedSize()
        .overlay { if enabled { MenuCatcher(items: items) } }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

private struct MenuCatcher: NSViewRepresentable {
    let items: () -> [InstantMenuButton.Item]

    final class Catcher: NSView {
        var items: () -> [InstantMenuButton.Item] = { [] }
        private var actions: [() -> Void] = []

        override var isFlipped: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            let entries = items()
            guard !entries.isEmpty else { return }
            actions = entries.map(\.action)
            let menu = NSMenu()
            for (index, entry) in entries.enumerated() {
                let item = NSMenuItem(
                    title: entry.title, action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
        }

        override func mouseDragged(with event: NSEvent) {}

        @objc private func pick(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            actions[sender.tag]()
        }
    }

    func makeNSView(context: Context) -> Catcher { Catcher() }

    func updateNSView(_ view: Catcher, context: Context) { view.items = items }
}

// MARK: - Shared target for the AppKit buttons

final class ActionCoordinator: NSObject {
    var action: () -> Void = {}
    @objc func fire(_ sender: Any?) { action() }
}
