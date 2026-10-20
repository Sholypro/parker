import Cocoa

/// Focus changes that never make macOS switch to another desktop (Space).
///
/// Activating an app that has no window on the current desktop makes macOS jump to a desktop
/// where it has one. Parker used to do that right before a capture (re-activating the last app,
/// or activating itself while one of its windows was open on another desktop), and the capture
/// overlay then appeared in the middle of the desktop transition, leaving the screen stuck
/// between two desktops.
enum SpaceSafeFocus {
    /// True when the app has a normal window visible on the current desktop of any display.
    static func hasWindowOnActiveSpace(_ app: NSRunningApplication) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { window in
            (window[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                && (window[kCGWindowLayer as String] as? Int) == 0
        }
    }

    /// Brings `app` back in front, but only when that keeps the current desktop.
    /// When Parker is in front and `app` lives elsewhere, Parker simply steps back.
    static func restoreFocus(to app: NSRunningApplication?) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Another app is already in front: nothing to do (and nothing to risk)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID else { return }
        if let app, !app.isTerminated, app.processIdentifier != ownPID, hasWindowOnActiveSpace(app) {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        } else {
            NSApp.deactivate()
        }
    }

    /// Shows a capture overlay on the current desktop and gives it the keyboard.
    /// The window is put on screen *before* Parker is activated: macOS then has a Parker window
    /// on this desktop and does not jump to the desktop of another Parker window (settings…).
    static func present(_ window: NSWindow, firstResponder: NSResponder?) {
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        if let firstResponder { window.makeFirstResponder(firstResponder) }
    }
}
