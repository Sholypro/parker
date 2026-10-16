import SwiftUI
import Cocoa
import ThinkingOrbsKit
import BorderBeamKit

// Effects from libraries.dev (vendored SwiftUI ports), placed following the author's rules:
//  - waits of 2 s or more: a Thinking orb beside a text label;
//  - work lasting more than 3 s: also a Border beam on the element doing the work.
// Colours follow the settings window tokens (SettingsColor).

// MARK: - Activity label (orb + text)

/// Small dark capsule: thinking orb (20 pt) followed by a label. Used for waits ≥ 2 s.
struct ActivityPill: View {
    let text: String
    var state: OrbState = .working

    var body: some View {
        HStack(spacing: 10) {
            ThinkingOrb(state: state, size: .px20, theme: .dark)
                .frame(width: 20, height: 20)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SettingsColor.ink)
                .lineLimit(1)
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(height: 36)
        .background(Capsule().fill(Color(red: 17 / 255, green: 24 / 255, blue: 39 / 255).opacity(0.92)))
        .overlay(Capsule().stroke(SettingsColor.groupStroke, lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}

/// Result capsule (icon + text), same shape as `ActivityPill`.
struct ResultPill: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SettingsColor.ink)
                .lineLimit(1)
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(height: 36)
        .background(Capsule().fill(Color(red: 17 / 255, green: 24 / 255, blue: 39 / 255).opacity(0.92)))
        .overlay(Capsule().stroke(SettingsColor.groupStroke, lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Scroll capture frame (border beam)

/// Drawn around the scrolling-capture area while frames are being stitched.
/// The window that hosts it is never captured (own app excluded + sharingType none).
struct CaptureBeamFrame: View {
    /// Area in the hosting view's coordinates (top-left origin, points).
    let area: CGRect
    let cornerRadius: CGFloat = 8
    let outset: CGFloat = 4

    var body: some View {
        let rect = area.insetBy(dx: -outset, dy: -outset)
        ZStack(alignment: .topLeading) {
            Color.clear
            frame
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var frame: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if BeamShaders.isAvailable {
            BorderBeam(size: .md, colorVariant: .ocean, theme: .dark, borderRadius: Double(cornerRadius)) {
                shape
                    .fill(Color.clear)
                    .overlay(shape.stroke(SettingsColor.accent.opacity(0.55), lineWidth: 1.5))
            }
        } else {
            // Metal shaders unavailable (local build without Xcode): plain dashed border
            shape.stroke(SettingsColor.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
        }
    }
}
