import AppKit
import Carbon.HIToolbox
import AttacheCore

/// Registers Attaché's user-configurable global summon hotkey (INF-365) with
/// `RegisterEventHotKey`. This is the Carbon API Apple documents for an app's
/// own global shortcuts; unlike a `CGEventTap` it does not require Input
/// Monitoring / Accessibility permission, so summon-from-anywhere works the
/// moment a user records a shortcut.
///
/// Owns at most one live Carbon registration at a time. Callers drive it
/// through `GlobalHotKeyStateMachine` (AttacheCore) so "set / persist / clear"
/// is decided by pure, tested logic; this class only performs the side
/// effects that logic dictates.
final class GlobalHotKeyMonitor {
    static let shared = GlobalHotKeyMonitor()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (() -> Void)?
    private let hotKeyID = EventHotKeyID(signature: OSType(bitPattern: 0x4174_7448), id: 1) // 'AttH'

    private init() {}

    /// Registers `spec` and arms `action` to run when it fires. Replaces any
    /// existing registration. Call `unregister()` first if you are following
    /// `GlobalHotKeyStateMachine.Transition.shouldUnregisterPrevious`.
    func register(_ spec: GlobalHotKeySpec, action: @escaping () -> Void) {
        self.action = action
        installEventHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(spec.keyCode),
            carbonModifiers(for: spec.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            hotKeyRef = nil
        }
    }

    /// Unregisters the current hotkey, if any. Idempotent: safe to call when
    /// nothing is registered (the cleared-by-default and double-clear paths).
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData, let eventRef else { return noErr }
                let monitor = Unmanaged<GlobalHotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                var receivedID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                if status == noErr, receivedID.id == monitor.hotKeyID.id {
                    DispatchQueue.main.async {
                        monitor.action?()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )
    }

    private func carbonModifiers(for modifiers: GlobalHotKeyModifiers) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}

extension GlobalHotKeyModifiers {
    /// Maps to/from `NSEvent.ModifierFlags` for the recorder UI, restricted
    /// to the four modifier keys a global shortcut can use.
    init(nsEventModifiers flags: NSEvent.ModifierFlags) {
        var result: GlobalHotKeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        self = result
    }

    var nsEventModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        if contains(.shift) { flags.insert(.shift) }
        return flags
    }
}
