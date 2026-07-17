import AppKit
import AttacheCore
import SwiftUI

/// Captures a global-hotkey shortcut from the keyboard (INF-365). Click to
/// start recording, then press a modifier-plus-key chord; the first
/// qualifying keyDown lands the shortcut. Escape while recording cancels
/// without changing the stored shortcut.
///
/// This only *records* locally (a plain `NSEvent` monitor scoped to this
/// app while the button has focus); it does not itself claim the global
/// shortcut. `GlobalHotKeyMonitor` (driven by `AppModel.globalHotKeySpec`)
/// is what calls `RegisterEventHotKey` so the shortcut works from any app.
struct GlobalHotKeyRecorderView: View {
    @Binding var spec: GlobalHotKeySpec?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(label)
                    .frame(minWidth: 170)
            }
            .accessibilityLabel("Record global summon shortcut")

            if spec != nil, !isRecording {
                Button {
                    spec = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear global summon shortcut")
            }
        }
        .onDisappear { stopRecording() }
    }

    private var label: String {
        if isRecording { return "Press a shortcut… (Esc to cancel)" }
        if let spec { return GlobalHotKeyLabelFormatter.label(for: spec) }
        return "Click to record shortcut"
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            let modifiers = GlobalHotKeyModifiers(nsEventModifiers: event.modifierFlags)
            // A bare key would fight every other app's typing, so a global
            // summon shortcut always needs at least one modifier.
            guard !modifiers.isEmpty else { return nil }
            spec = GlobalHotKeySpec(keyCode: Int(event.keyCode), modifiers: modifiers)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
