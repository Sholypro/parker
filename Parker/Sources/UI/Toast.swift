import Cocoa
import SwiftUI
import ThinkingOrbsKit

enum ToastStyle {
    case success
    case error
    case info

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success: return Color(red: 0.30, green: 0.85, blue: 0.48)
        case .error: return Color(red: 1.0, green: 0.42, blue: 0.40)
        case .info: return Color(red: 0.55, green: 0.66, blue: 1.0)
        }
    }
}

/// Small capsule at the bottom of the screen.
/// `show` displays a result for a few seconds; `showActivity` displays a thinking orb
/// with a label until the next toast replaces it (use it only for waits of 2 s or more).
enum Toast {
    private static var toastWindow: NSWindow?

    static func show(message: String, style: ToastStyle = .success, duration: TimeInterval = 2.0) {
        present(AnyView(ResultPill(text: message, symbol: style.icon, tint: style.tint)), duration: duration)
    }

    static func showActivity(message: String, state: OrbState = .working) {
        present(AnyView(ActivityPill(text: message, state: state)), duration: nil)
    }

    private static func present(_ content: AnyView, duration: TimeInterval?) {
        DispatchQueue.main.async {
            toastWindow?.orderOut(nil)

            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }

            let hosting = NSHostingView(rootView: content)
            let size = hosting.fittingSize
            hosting.frame = NSRect(origin: .zero, size: size)

            let x = screen.frame.midX - size.width / 2
            let y = screen.visibleFrame.minY + 60
            let window = NSWindow(
                contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = .floating
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.ignoresMouseEvents = true
            window.sharingType = .none   // never appears in captures
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            window.contentView = hosting
            window.alphaValue = 0
            window.orderFrontRegardless()

            // Slide up + fade in
            let startFrame = window.frame
            window.setFrame(startFrame.offsetBy(dx: 0, dy: -10), display: false)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1.0
                window.animator().setFrame(startFrame, display: true)
            }
            toastWindow = window

            guard let duration = duration else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                guard toastWindow === window else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    window.animator().alphaValue = 0
                    window.animator().setFrame(startFrame.offsetBy(dx: 0, dy: -10), display: true)
                }, completionHandler: {
                    window.orderOut(nil)
                    if toastWindow === window { toastWindow = nil }
                })
            }
        }
    }
}
