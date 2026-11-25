import Foundation
import HotKey

/// Apple's built-in screenshot shortcuts (macOS "symbolic hotkeys").
///
/// With the Cmd+Shift profile, Cmd+Shift+3/4/5 (and 6 since macOS 27) would also trigger Apple's own screenshot tool,
/// which macOS handles before any app. While Parker runs with that profile, it switches those
/// three Apple shortcuts off, and turns them back on when Parker quits or the profile changes.
///
/// The switch is a session setting of the window server, not a saved preference: if Parker
/// crashes, Apple's shortcuts come back at the next login. Parker only turns back on the
/// shortcuts it turned off itself; ones the user already disabled stay disabled.
enum SystemScreenshotShortcuts {
    /// 28: Cmd+Shift+3, 30: Cmd+Shift+4, 184: Cmd+Shift+5 (screenshot and recording options).
    private static let knownIDs: [Int32] = [28, 30, 184]

    /// Known ones, plus any Apple shortcut found on Cmd+Shift + one of Parker's keys. Since macOS 27,
    /// Cmd+Shift+6 opens Visual Intelligence (Siri AI) over Parker's scrolling capture: its internal
    /// number is not documented, so Parker looks it up by its keys instead.
    private static let conflictingIDs: [Int32] = {
        var ids = knownIDs
        guard let getValue else { return ids }
        let parkerKeys = Set(ShortcutAction.allCases.map { UInt16($0.key.carbonKeyCode) })
        let commandShift: UInt64 = 0x120000      // Shift (0x20000) + Command (0x100000)
        let modifierMask: UInt64 = 0x1E0000      // Shift, Control, Option, Command
        for id in Int32(0)..<Int32(1024) where !ids.contains(id) {
            var character: UInt16 = 0
            var keyCode: UInt16 = 0
            var modifiers: UInt64 = 0
            guard getValue(id, &character, &keyCode, &modifiers) == 0 else { continue }
            if parkerKeys.contains(keyCode) && (modifiers & modifierMask) == commandShift {
                ids.append(id)
            }
        }
        return ids
    }()

    private typealias SetEnabledFunction = @convention(c) (Int32, Bool) -> Int32
    private typealias IsEnabledFunction = @convention(c) (Int32) -> Bool
    private typealias GetValueFunction = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt64>) -> Int32

    private static let setEnabled: SetEnabledFunction? = lookup(["CGSSetSymbolicHotKeyEnabled", "SLSSetSymbolicHotKeyEnabled"])
    private static let isEnabled: IsEnabledFunction? = lookup(["CGSIsSymbolicHotKeyEnabled", "SLSIsSymbolicHotKeyEnabled"])
    private static let getValue: GetValueFunction? = lookup(["CGSGetSymbolicHotKeyValue", "SLSGetSymbolicHotKeyValue"])

    private static var disabledByParker: Set<Int32> = []

    /// False if this macOS version no longer offers the switch (Parker then behaves as before).
    static var isSupported: Bool { setEnabled != nil && isEnabled != nil }

    /// Matches Apple's shortcuts to the current Parker profile.
    static func sync(with profile: ShortcutModifierProfile) {
        if profile == .commandShift {
            suppress()
        } else {
            restore()
        }
    }

    /// Turns Apple's conflicting shortcuts off (only those currently on).
    static func suppress() {
        guard let setEnabled, let isEnabled else { return }
        for id in conflictingIDs where isEnabled(id) {
            if setEnabled(id, false) == 0 {
                disabledByParker.insert(id)
            }
        }
    }

    /// Turns back on the shortcuts Parker turned off.
    static func restore() {
        guard let setEnabled else { return }
        for id in disabledByParker {
            _ = setEnabled(id, true)
        }
        disabledByParker.removeAll()
    }

    private static func lookup<T>(_ names: [String]) -> T? {
        let handles: [UnsafeMutableRawPointer?] = [
            UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
            dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
        ]
        for handle in handles {
            for name in names {
                if let symbol = dlsym(handle, name) {
                    return unsafeBitCast(symbol, to: T.self)
                }
            }
        }
        return nil
    }
}
