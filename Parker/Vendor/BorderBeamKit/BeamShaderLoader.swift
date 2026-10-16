import SwiftUI

/// Parker patch: the Metal shaders are compiled by build-app.sh into
/// `Parker.app/Contents/Resources/BorderBeam.metallib` (SwiftPM alone cannot compile
/// `.metal` files). When the library is missing, `isAvailable` is false and callers
/// draw a plain border instead.
public enum BeamShaders {
    static let url: URL? = Bundle.main.url(forResource: "BorderBeam", withExtension: "metallib")

    /// True when the compiled shader library ships with the app.
    public static var isAvailable: Bool { url != nil }

    static let library: ShaderLibrary = {
        if let url { return ShaderLibrary(url: url) }
        return ShaderLibrary.default
    }()
}
