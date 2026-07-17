import AppKit
import SwiftUI

/// Shared key handling for the command palettes (⌘K sessions, ⌘I inbox,
/// ⌘Y history). Every palette follows the same contract: the search field is
/// focused on open and typing filters immediately, arrows move the selection,
/// Return fires the primary action, and command chords carry the secondary
/// actions so bare letters always reach the search field.
///
/// Two extra affordances are gated on the search field being unfocused (or,
/// for digits, empty) so typing a search query is never intercepted:
/// - `onDigit`: bare 1-9 (INF-365). Only invoked when `isFieldFocused` is
///   false OR the field is empty; the closure itself decides whether the
///   digit maps to a row and returns whether it consumed the key.
/// - `vimKeysEnabled` + `isFieldFocused`: bare j/k mirror the arrow keys
///   (INF-365), but only while the search field does not have keyboard
///   focus, so "j"/"k" typed while searching still reach the text field.
struct PaletteKeyMonitor: NSViewRepresentable {
    var onMove: (Int) -> Void
    var onSelect: () -> Void
    var onCommandReturn: (() -> Void)?
    var onCommandDelete: (() -> Void)?
    var onShiftCommandDelete: (() -> Void)?
    var onDigit: ((Int) -> Bool)? = nil
    var vimKeysEnabled: Bool = false
    var isFieldFocused: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(onMove: onMove, onSelect: onSelect,
                    onCommandReturn: onCommandReturn,
                    onCommandDelete: onCommandDelete,
                    onShiftCommandDelete: onShiftCommandDelete,
                    onDigit: onDigit,
                    vimKeysEnabled: vimKeysEnabled,
                    isFieldFocused: isFieldFocused)
    }

    /// Claims key status for the window a palette opens in. The attache
    /// window is often main but not key at that moment; without key status
    /// the search field cannot take focus, so typing beeps and goes nowhere
    /// and Escape never reaches the overlay.
    private final class KeyClaimingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        let view = KeyClaimingView(frame: .zero)
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            // Accept events for this window, and events carrying no window at
            // all: when the app is frontmost without a key window (a state
            // this window can reach), key events arrive windowless and every
            // overlay would otherwise go deaf to Escape and arrows.
            guard let window = view?.window, event.window === window || event.window == nil else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch event.keyCode {
            case 126 where modifiers.isEmpty: coordinator.onMove(-1); return nil
            case 125 where modifiers.isEmpty: coordinator.onMove(1); return nil
            case 36, 76:
                if modifiers == [.command], let action = coordinator.onCommandReturn {
                    action(); return nil
                }
                if modifiers.isEmpty { coordinator.onSelect(); return nil }
                return event
            case 51, 117:
                if modifiers == [.command], let action = coordinator.onCommandDelete {
                    action(); return nil
                }
                if modifiers == [.command, .shift], let action = coordinator.onShiftCommandDelete {
                    action(); return nil
                }
                return event
            default:
                guard modifiers.isEmpty, let chars = event.charactersIgnoringModifiers?.lowercased() else {
                    return event
                }
                if coordinator.vimKeysEnabled, !coordinator.isFieldFocused {
                    if chars == "j" { coordinator.onMove(1); return nil }
                    if chars == "k" { coordinator.onMove(-1); return nil }
                }
                if let onDigit = coordinator.onDigit, chars.count == 1, let digit = Int(chars), (1...9).contains(digit) {
                    if onDigit(digit) { return nil }
                }
                return event
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onMove = onMove
        context.coordinator.onSelect = onSelect
        context.coordinator.onCommandReturn = onCommandReturn
        context.coordinator.onCommandDelete = onCommandDelete
        context.coordinator.onShiftCommandDelete = onShiftCommandDelete
        context.coordinator.onDigit = onDigit
        context.coordinator.vimKeysEnabled = vimKeysEnabled
        context.coordinator.isFieldFocused = isFieldFocused
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    final class Coordinator {
        var onMove: (Int) -> Void
        var onSelect: () -> Void
        var onCommandReturn: (() -> Void)?
        var onCommandDelete: (() -> Void)?
        var onShiftCommandDelete: (() -> Void)?
        var onDigit: ((Int) -> Bool)?
        var vimKeysEnabled: Bool
        var isFieldFocused: Bool
        var monitor: Any?

        init(onMove: @escaping (Int) -> Void, onSelect: @escaping () -> Void,
             onCommandReturn: (() -> Void)?,
             onCommandDelete: (() -> Void)?,
             onShiftCommandDelete: (() -> Void)?,
             onDigit: ((Int) -> Bool)?,
             vimKeysEnabled: Bool,
             isFieldFocused: Bool) {
            self.onMove = onMove
            self.onSelect = onSelect
            self.onCommandReturn = onCommandReturn
            self.onCommandDelete = onCommandDelete
            self.onShiftCommandDelete = onShiftCommandDelete
            self.onDigit = onDigit
            self.vimKeysEnabled = vimKeysEnabled
            self.isFieldFocused = isFieldFocused
        }
    }
}
