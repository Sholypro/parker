import Cocoa

/// Borderless full-screen overlay window that can receive keyboard events.
///
/// A plain borderless NSWindow returns false from `canBecomeKey`, so `keyDown` (Escape, Space)
/// never reaches the overlay's content view. This subclass can become key (keyboard focus)
/// without becoming main, so it does not steal the "main window" role from other windows.
final class KeyableOverlayWindow: NSWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        // Always on the current desktop (and over full-screen apps), never tied to another one
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
