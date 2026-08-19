import SwiftUI

/// Pins the hosting window above other apps' windows while `pinned` is true.
/// Level changes don't steal key focus, so typing in another app is untouched.
struct WindowLevelPin: NSViewRepresentable {
    let pinned: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // The window is nil during view construction; defer to the next
        // runloop turn so the first update after launch also lands.
        DispatchQueue.main.async {
            view.window?.level = pinned ? .floating : .normal
        }
    }
}
