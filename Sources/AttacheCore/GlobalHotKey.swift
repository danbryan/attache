import Foundation

/// Modifier keys for the global summon hotkey (INF-365), defined independent
/// of AppKit/Carbon so this model stays testable in AttacheCore. The
/// AttacheApp layer maps this to `NSEvent.ModifierFlags` for the recorder UI
/// and to Carbon's `cmdKey`/`optionKey`/`controlKey`/`shiftKey` masks for
/// `RegisterEventHotKey`.
public struct GlobalHotKeyModifiers: OptionSet, Codable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = GlobalHotKeyModifiers(rawValue: 1 << 0)
    public static let option = GlobalHotKeyModifiers(rawValue: 1 << 1)
    public static let control = GlobalHotKeyModifiers(rawValue: 1 << 2)
    public static let shift = GlobalHotKeyModifiers(rawValue: 1 << 3)
}

/// A user-chosen global shortcut: a virtual key code plus modifiers. There is
/// no default value; the global summon hotkey ships off until a user records
/// one (see Decisions of Record / INF-365 acceptance criteria: "defaults off").
public struct GlobalHotKeySpec: Codable, Equatable {
    public var keyCode: Int
    public var modifiers: GlobalHotKeyModifiers

    public init(keyCode: Int, modifiers: GlobalHotKeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// What is actually registered with the OS right now.
public enum GlobalHotKeyRegistrationState: Equatable {
    case unregistered
    case registered(GlobalHotKeySpec)
}

/// Pure state-machine transition for the global summon hotkey (INF-365).
/// Given the OS-registration state Attaché believes it is in and a new user
/// choice (`nil` clears the hotkey, a spec sets/replaces it), decides the
/// next state and exactly which side effects the AppKit/Carbon layer must
/// perform to reach it. Kept side-effect-free so "set, persist, clear" is
/// unit-testable without touching `RegisterEventHotKey`.
public enum GlobalHotKeyStateMachine {
    public struct Transition: Equatable {
        public let next: GlobalHotKeyRegistrationState
        /// True when the caller must call `UnregisterEventHotKey` on the
        /// previously registered spec before doing anything else.
        public let shouldUnregisterPrevious: Bool
        /// Non-nil when the caller must call `RegisterEventHotKey` with this
        /// spec after unregistering (if needed).
        public let shouldRegister: GlobalHotKeySpec?
    }

    public static func apply(_ choice: GlobalHotKeySpec?, to current: GlobalHotKeyRegistrationState) -> Transition {
        switch (current, choice) {
        case (.unregistered, nil):
            // Already off; nothing to do. Covers "defaults off" at first launch.
            return Transition(next: .unregistered, shouldUnregisterPrevious: false, shouldRegister: nil)
        case (.unregistered, .some(let spec)):
            // First-time set.
            return Transition(next: .registered(spec), shouldUnregisterPrevious: false, shouldRegister: spec)
        case (.registered, nil):
            // Clearing: unregister immediately, nothing to re-register.
            return Transition(next: .unregistered, shouldUnregisterPrevious: true, shouldRegister: nil)
        case (.registered(let old), .some(let spec)):
            guard old != spec else {
                // Re-applying the same choice is a no-op; do not thrash the
                // OS registration.
                return Transition(next: .registered(old), shouldUnregisterPrevious: false, shouldRegister: nil)
            }
            // Changing to a different shortcut: unregister the old one first.
            return Transition(next: .registered(spec), shouldUnregisterPrevious: true, shouldRegister: spec)
        }
    }
}

/// Renders a `GlobalHotKeySpec` as a human-readable shortcut label (e.g.
/// "⌃⌥Space") for the recorder button and any confirmation text. Uses a
/// static ANSI-US virtual-keycode table rather than the current keyboard
/// layout, matching the simplicity of the app's other hardcoded keyCode
/// checks (see `PaletteKeyMonitor`); layout-exact glyphs are not required
/// for a settings label.
public enum GlobalHotKeyLabelFormatter {
    public static func label(for spec: GlobalHotKeySpec) -> String {
        modifierSymbols(spec.modifiers) + keySymbol(for: spec.keyCode)
    }

    private static func modifierSymbols(_ modifiers: GlobalHotKeyModifiers) -> String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "\u{2303}" }
        if modifiers.contains(.option) { symbols += "\u{2325}" }
        if modifiers.contains(.shift) { symbols += "\u{21E7}" }
        if modifiers.contains(.command) { symbols += "\u{2318}" }
        return symbols
    }

    private static let keyCodeSymbols: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 50: "`",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]

    private static func keySymbol(for keyCode: Int) -> String {
        keyCodeSymbols[keyCode] ?? "Key \(keyCode)"
    }
}
