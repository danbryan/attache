import AppKit
import AttacheCore
import SwiftUI

struct KeyboardShortcutMonitor: NSViewRepresentable {
    var onEscape: () -> Bool
    var onDelete: () -> Bool
    var onSpace: () -> Bool
    var onLeftArrow: () -> Bool
    var onRightArrow: () -> Bool
    var onCaptionResize: (Int) -> Bool
    var onTextZoom: (Int) -> Bool
    var onPreviousPersonality: () -> Bool
    var onNextPersonality: () -> Bool
    var onOpenShortcuts: () -> Bool
    /// -1 slower, +1 faster, 0 reset (S / D / R).
    var onSpeedKey: (Int) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onEscape: onEscape,
            onDelete: onDelete,
            onSpace: onSpace,
            onLeftArrow: onLeftArrow,
            onRightArrow: onRightArrow,
            onCaptionResize: onCaptionResize,
            onTextZoom: onTextZoom,
            onPreviousPersonality: onPreviousPersonality,
            onNextPersonality: onNextPersonality,
            onOpenShortcuts: onOpenShortcuts,
            onSpeedKey: onSpeedKey
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
        context.coordinator.onDelete = onDelete
        context.coordinator.onSpace = onSpace
        context.coordinator.onLeftArrow = onLeftArrow
        context.coordinator.onRightArrow = onRightArrow
        context.coordinator.onCaptionResize = onCaptionResize
        context.coordinator.onTextZoom = onTextZoom
        context.coordinator.onSpeedKey = onSpeedKey
        context.coordinator.onPreviousPersonality = onPreviousPersonality
        context.coordinator.onNextPersonality = onNextPersonality
        context.coordinator.onOpenShortcuts = onOpenShortcuts
        context.coordinator.view = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var onEscape: () -> Bool
        var onDelete: () -> Bool
        var onSpace: () -> Bool
        var onLeftArrow: () -> Bool
        var onRightArrow: () -> Bool
        var onCaptionResize: (Int) -> Bool
        var onTextZoom: (Int) -> Bool
        var onPreviousPersonality: () -> Bool
        var onNextPersonality: () -> Bool
        var onOpenShortcuts: () -> Bool
        var onSpeedKey: (Int) -> Bool
        weak var view: NSView?
        private var monitor: Any?

        init(
            onEscape: @escaping () -> Bool,
            onDelete: @escaping () -> Bool,
            onSpace: @escaping () -> Bool,
            onLeftArrow: @escaping () -> Bool,
            onRightArrow: @escaping () -> Bool,
            onCaptionResize: @escaping (Int) -> Bool,
            onTextZoom: @escaping (Int) -> Bool,
            onPreviousPersonality: @escaping () -> Bool,
            onNextPersonality: @escaping () -> Bool,
            onOpenShortcuts: @escaping () -> Bool,
            onSpeedKey: @escaping (Int) -> Bool
        ) {
            self.onEscape = onEscape
            self.onDelete = onDelete
            self.onSpace = onSpace
            self.onLeftArrow = onLeftArrow
            self.onRightArrow = onRightArrow
            self.onCaptionResize = onCaptionResize
            self.onTextZoom = onTextZoom
            self.onPreviousPersonality = onPreviousPersonality
            self.onNextPersonality = onNextPersonality
            self.onOpenShortcuts = onOpenShortcuts
            self.onSpeedKey = onSpeedKey
        }

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                // Windowless events occur when the app is frontmost with no
                // key window; without accepting them Escape and the playback
                // keys go dead in that state.
                guard let self,
                      let window = self.view?.window,
                      event.window === window || event.window == nil else {
                    return event
                }

                if event.keyCode == 53 {
                    return self.onEscape() ? nil : event
                }

                if event.modifierFlags.contains(.command),
                   event.modifierFlags.intersection([.option, .control]).isEmpty {
                    switch event.keyCode {
                    case 33:
                        return self.onPreviousPersonality() ? nil : event
                    case 30:
                        return self.onNextPersonality() ? nil : event
                    case 44:
                        return self.onOpenShortcuts() ? nil : event
                    default:
                        break
                    }
                }

                if event.keyCode == 123 || event.keyCode == 124 {
                    guard !Self.isEditingText(in: window),
                          event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
                        return event
                    }
                    let handled = event.keyCode == 123 ? self.onLeftArrow() : self.onRightArrow()
                    return handled ? nil : event
                }

                if event.keyCode == 51 || event.keyCode == 117 {
                    guard !Self.isEditingText(in: window),
                          event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
                        return event
                    }
                    return self.onDelete() ? nil : event
                }

                // S slows, D speeds up, R resets playback speed while a
                // recap is loaded; never while typing.
                if event.keyCode == 1 || event.keyCode == 2 || event.keyCode == 15 {
                    guard !Self.isEditingText(in: window),
                          event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                        return event
                    }
                    let delta = event.keyCode == 1 ? -1 : (event.keyCode == 2 ? 1 : 0)
                    return self.onSpeedKey(delta) ? nil : event
                }

                if event.keyCode == 49 {
                    guard !Self.isEditingText(in: window),
                          event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
                        return event
                    }
                    return self.onSpace() ? nil : event
                }

                // Command +/- zooms the whole UI text scale; bare +/-
                // still resizes the caption while it's on screen.
                if event.keyCode == 24 || event.keyCode == 27 {
                    let modifiers = event.modifierFlags.intersection([.command, .option, .control])
                    if modifiers == [.command] {
                        return self.onTextZoom(event.keyCode == 24 ? 1 : -1) ? nil : event
                    }
                    guard !Self.isEditingText(in: window), modifiers.isEmpty else {
                        return event
                    }
                    return self.onCaptionResize(event.keyCode == 24 ? 1 : -1) ? nil : event
                }

                return event
            }
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private static func isEditingText(in window: NSWindow) -> Bool {
            window.firstResponder is NSTextView
        }

        deinit {
            detach()
        }
    }
}

/// Tracks whether the user is actively typing in the app, feeding
/// `AttacheActivityState.userTyping`. Privacy contract: only the fact that
/// a key went down is recorded, never keycodes or characters, and the local
/// monitor observes events without consuming them. Local-only by design (no
/// Input Monitoring permission, no new data collection): it fires while an
/// Attaché window is receiving keys and stays false otherwise.
final class TypingActivityMonitor {
    var onChange: ((Bool) -> Void)?
    private(set) var isTyping = false
    private var monitor: Any?
    private var decayTimer: Timer?
    private let quietInterval: TimeInterval

    init(quietInterval: TimeInterval = 2.0) {
        self.quietInterval = quietInterval
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.registerKeystroke()
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        decayTimer?.invalidate()
        decayTimer = nil
        setTyping(false)
    }

    private func registerKeystroke() {
        decayTimer?.invalidate()
        decayTimer = Timer.scheduledTimer(withTimeInterval: quietInterval, repeats: false) { [weak self] _ in
            self?.setTyping(false)
        }
        setTyping(true)
    }

    private func setTyping(_ value: Bool) {
        guard isTyping != value else { return }
        isTyping = value
        onChange?(value)
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        decayTimer?.invalidate()
    }
}

// Scroll over the caption (mouse wheel / two-finger) to grow or shrink it.
struct CaptionScrollMonitor: NSViewRepresentable {
    var enabled: Bool
    /// Height of the stable scroll band, covering the tallest a caption can get.
    /// The band is anchored at the caption's (stable) bottom edge and extended
    /// upward to at least this height so repeated steps register from one fixed
    /// hover position across the whole line-count range (BUG 2).
    var maxBandHeight: CGFloat
    var onStep: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(enabled: enabled, maxBandHeight: maxBandHeight, onStep: onStep)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.maxBandHeight = maxBandHeight
        context.coordinator.onStep = onStep
        context.coordinator.view = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var enabled: Bool
        var maxBandHeight: CGFloat
        var onStep: (Int) -> Void
        weak var view: NSView?
        private var monitor: Any?
        private var accumulated: CGFloat = 0

        init(enabled: Bool, maxBandHeight: CGFloat, onStep: @escaping (Int) -> Void) {
            self.enabled = enabled
            self.maxBandHeight = maxBandHeight
            self.onStep = onStep
        }

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                guard let self,
                      self.enabled,
                      let view = self.view,
                      let window = view.window,
                      event.window === window else {
                    return event
                }
                // Hit-test a STABLE band in window coordinates rather than the
                // resizing caption box: anchored at the caption's fixed bottom
                // edge, extended up to the tallest a caption can be. The pointer
                // then stays inside it as the box grows and shrinks under it.
                let captionFrame = view.convert(view.bounds, to: nil)
                let region = CaptionScrollHitRegion.stableRegion(
                    captionFrame: captionFrame,
                    maxBandHeight: self.maxBandHeight
                )
                guard region.contains(event.locationInWindow) else { return event }
                guard event.momentumPhase == [] else { return nil }

                let vertical = event.scrollingDeltaY
                guard abs(vertical) >= abs(event.scrollingDeltaX), abs(vertical) >= 0.5 else {
                    return event
                }

                self.accumulated += vertical
                let threshold: CGFloat = 16
                if self.accumulated >= threshold {
                    self.accumulated = 0
                    self.onStep(1)
                } else if self.accumulated <= -threshold {
                    self.accumulated = 0
                    self.onStep(-1)
                }
                return nil
            }
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            detach()
        }
    }
}
