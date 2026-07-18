import SwiftUI

/// Caption and voice-input settings. The voice a character speaks with is now
/// chosen per-personality in the Personalities editor, so this pane holds only
/// caption display and conversation-input controls.
struct VoicePane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Voice & Captions").typoTitle()

            Text("Captions").typoBody(.semibold)
            Toggle("Show captions", isOn: $model.captionsEnabled)
            settingRow("Caption size") {
                Slider(value: $model.captionFontSize, in: AppModel.captionFontRange, step: 1)
                    .frame(width: 200)
                    .accessibilityLabel("Caption size")
                Text("\(Int(model.captionFontSize)) pt")
                    .typoCaption(.medium, monoDigit: true)
                    .foregroundStyle(.secondary)
            }
            fixedStepperRow(
                "Caption lines",
                value: "\(model.captionLineCount)",
                binding: $model.captionLineCount,
                range: AppModel.captionLineRange,
                step: 1
            )
            fixedStepperRow(
                "Skip interval",
                value: "\(model.seekStepSeconds)s",
                binding: $model.seekStepSeconds,
                range: 2...30,
                step: 1
            )
            fixedStepperRow(
                "Caption timing",
                value: "\(model.captionSyncOffsetMs) ms",
                binding: $model.captionSyncOffsetMs,
                range: -2000...2000,
                step: 50
            )
            settingRow("Audio replay") {
                Picker("", selection: replayRetentionBinding) {
                    ForEach(AppModel.audioCacheRetentionOptions, id: \.minutes) { option in
                        Text(option.label).tag(option.minutes)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Button("Clean now") { model.cleanExpiredAudioCache() }
            }
            Text("Cached recap audio is reused when replaying cards with the same voice. Session history and text cards stay available after cached audio expires.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PremiumVoiceRemovalRow(weights: model.premiumVoiceWeights)

            Divider().padding(.vertical, 4)
            Text("Conversation").typoBody(.semibold)
            settingRow("Voice input") {
                Picker("", selection: $model.voiceInputMode) {
                    ForEach(AttacheVoiceInputMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 200)
            }
            settingRow("Input source") {
                Picker("", selection: $model.microphoneDeviceID) {
                    Text("System default").tag("")
                    ForEach(model.microphoneDevices) { device in
                        Text(device.isDefault ? "\(device.name) (default)" : device.name)
                            .tag(device.id)
                    }
                }
                .labelsHidden()
                .frame(width: 280)
                Button {
                    model.refreshMicrophoneDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh input sources")
            }
            settingRow("Mic test") {
                Button {
                    model.micTranscript.isTesting ? model.stopMicrophoneTest() : model.startMicrophoneTest()
                } label: {
                    Label(
                        model.micTranscript.isTesting ? "Stop test" : "Start test",
                        systemImage: model.micTranscript.isTesting ? "stop.circle" : "waveform"
                    )
                }
                MicrophoneLevelMeter(controller: model.micTranscript, accent: model.theme.signatureColor)
                    .frame(width: 150)
            }
            if microphoneStatusVisible {
                Text(model.micTranscript.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            settingRow("Spoken language") {
                Picker("", selection: $model.spokenLanguage) {
                    ForEach(AttacheCaptionLanguage.all) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 200)
            }
            Text("Attaché uses responsive transcription and may use Apple's network-assisted recognizer when it improves accuracy.")
                .typoCaption()
                .foregroundStyle(.secondary)
            Text(model.voiceInputMode.detail)
                .typoCaption()
                .foregroundStyle(.secondary)
        }
        .onAppear { model.refreshMicrophoneDevices() }
    }

    private var replayRetentionBinding: Binding<Int> {
        Binding(
            get: { model.audioCacheRetentionMinutes },
            set: { model.audioCacheRetentionMinutes = $0 }
        )
    }

    private var microphoneStatusVisible: Bool {
        model.micTranscript.isTesting
            || model.micTranscript.isPreparing
            || !["", "Voice input off."].contains(model.micTranscript.status)
    }

    private func fixedStepperRow(
        _ label: String,
        value: String,
        binding: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        settingRow(label) {
            HStack(spacing: 8) {
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 78, alignment: .trailing)
                Stepper("", value: binding, in: range, step: step)
                    .labelsHidden()
                    .frame(width: 28, alignment: .leading)
            }
        }
    }

}

/// A downloaded on-device premium voice occupies real disk space, so the app
/// offers an explicit reclaim. Visible only when the Attaché Premium (Azelma)
/// weights are installed; removing them falls personalities back to the system
/// voice through the existing `resolvedForPlayback` path.
private struct PremiumVoiceRemovalRow: View {
    @ObservedObject var weights: PremiumVoiceWeightsManager

    var body: some View {
        if case .installed(let version) = weights.state {
            Divider().padding(.vertical, 4)
            Text("On-device premium voice").typoBody(.semibold)
            settingRow("Attaché Premium (Azelma)") {
                Text("\(version) · \(sizeText)")
                    .typoCaption(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Remove downloaded voice", role: .destructive) {
                    weights.remove()
                }
                .accessibilityIdentifier("Premium Voice Remove")
            }
            Text("Removing frees the download from this Mac. Characters using Azelma fall back to a system voice until you download it again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB]
        formatter.includesActualByteCount = false
        return formatter.string(fromByteCount: weights.release.unpackedSizeBytes)
    }
}

private struct MicrophoneLevelMeter: View {
    @ObservedObject var controller: MicTranscriptController
    var accent: Color

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<12, id: \.self) { index in
                let threshold = Double(index + 1) / 12.0
                Capsule()
                    .fill(controller.audioLevel >= threshold ? accent : Color.primary.opacity(0.16))
                    .frame(width: 7, height: CGFloat(8 + index * 2))
                    .animation(.easeOut(duration: 0.08), value: controller.audioLevel)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.10)))
        .accessibilityLabel("Microphone input level")
    }
}
