import AppKit
import SwiftUI

/// Shared key handling for the command palettes (⌘K sessions, ⌘I inbox,
/// ⌘Y history). Every palette follows the same contract: the search field is
/// focused on open and typing filters immediately, arrows move the selection,
/// Return fires the primary action, and command chords carry the secondary
/// actions so bare letters always reach the search field.
struct PaletteKeyMonitor: NSViewRepresentable {
    var onMove: (Int) -> Void
    var onSelect: () -> Void
    var onCommandReturn: (() -> Void)?
    var onCommandDelete: (() -> Void)?
    var onShiftCommandDelete: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onMove: onMove, onSelect: onSelect,
                    onCommandReturn: onCommandReturn,
                    onCommandDelete: onCommandDelete,
                    onShiftCommandDelete: onShiftCommandDelete)
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
            default: return event
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
        var monitor: Any?

        init(onMove: @escaping (Int) -> Void, onSelect: @escaping () -> Void,
             onCommandReturn: (() -> Void)?,
             onCommandDelete: (() -> Void)?,
             onShiftCommandDelete: (() -> Void)?) {
            self.onMove = onMove
            self.onSelect = onSelect
            self.onCommandReturn = onCommandReturn
            self.onCommandDelete = onCommandDelete
            self.onShiftCommandDelete = onShiftCommandDelete
        }
    }
}
