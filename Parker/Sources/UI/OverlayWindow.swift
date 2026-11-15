import Cocoa

/// Borderless full-screen overlay that takes the keyboard without activating Parker.
///
/// It is a non-activating panel: it can become key (so Escape, Space and the arrows reach the
/// content view) while the app in front stays active. That matters for what is on screen:
/// activating Parker would deactivate the other app, and macOS then closes its open menus,
/// pop-ups, popovers and tooltips before the capture (CleanShot keeps them for the same reason).
/// It never becomes main, so it does not steal that role from other windows either.
final class KeyableOverlayWindow: NSPanel {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style.union(.nonactivatingPanel), backing: backingStoreType, defer: flag)
        // Always on the current desktop (and over full-screen apps), never tied to another one
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
