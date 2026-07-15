import SwiftUI

/// Voice engine and caption settings. Selection-only; provider credentials live
/// in Integrations.
struct VoicePane: View {
    @ObservedObject var model: AppModel
    @State private var pendingCloudEngine: AttacheSpeechProvider?

    // Show every voice engine, not just connected ones, so providers like OpenAI are
    // discoverable here (selecting an unconfigured one points you to Integrations to
    // add its key) instead of silently hidden until a key exists.
    private var engineOptions: [AttacheSpeechProvider] {
        AttacheSpeechProvider.allCases
    }

    private var engineNeedsKey: Bool {
        !model.connectedVoiceEngines.contains(model.speechProvider) && model.speechProvider != .system
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Voice & Captions").typoTitle()
            activeHeader

            settingRow("Voice engine") {
                Picker("", selection: engineBinding) {
                    ForEach(engineOptions) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
                .accessibilityLabel("Voice engine")
            }
            dataResidencyCaption

            if engineNeedsKey {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(model.speechProvider.title) needs an")
                    Button("API key") { model.focusIntegration(for: model.speechProvider) }
                        .buttonStyle(.link)
                    Text("under Integrations, then Save & Test.")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let fallback = model.voicePlaybackFallbackDescription {
                Label(fallback, systemImage: "speaker.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            engineControls

            HStack {
                Button { model.previewAssistantVoice() } label: { Label("Preview voice", systemImage: "play.circle") }
                Spacer()
            }
            if !model.voiceProviderStatus.isEmpty {
                Text(model.voiceProviderStatus).font(.caption).foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 4)
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

            Divider().padding(.vertical, 4)
            Text("Narration").typoBody(.semibold)
            settingRow("Detail") {
                Picker("", selection: $model.narrationDetail) {
                    ForEach(AttacheNarrationDetail.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 200)
            }
            Text(model.narrationDetail.detail)
                .typoCaption().foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
        .sheet(item: $pendingCloudEngine) { engine in
            CloudConsentSheet(
                providerName: engine.title,
                produces: "speech",
                sends: "your agent's recap text",
                onEnable: {
                    model.cloudConsentVoiceAcknowledged = true
                    model.speechProvider = engine
                    pendingCloudEngine = nil
                },
                onCancel: { pendingCloudEngine = nil }
            )
        }
    }

    private var engineBinding: Binding<AttacheSpeechProvider> {
        Binding(
            get: { model.speechProvider },
            set: { engine in
                if engine != model.speechProvider,
                   engine.sendsToCloud,
                   !model.cloudConsentVoiceAcknowledged {
                    pendingCloudEngine = engine
                } else {
                    model.speechProvider = engine
                }
            }
        )
    }

    @ViewBuilder private var dataResidencyCaption: some View {
        if model.voiceSendsToCloud {
            Label("Cloud voice: recap text leaves this Mac.", systemImage: "cloud")
                .font(.caption).foregroundStyle(.orange)
        } else {
            Label("On-device voice: nothing leaves this Mac.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var activeHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.green)
            Text("Active voice: \(model.currentVoiceSummary)")
                .typoLabel(.medium)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
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

    @ViewBuilder private var engineControls: some View {
        switch model.speechProvider {
        case .system: systemControls
        case .elevenLabs: remoteControls(
            options: model.elevenLabsVoiceOptions,
            selectedID: model.elevenLabsVoiceID,
            reload: { model.loadElevenLabsVoices() },
            select: { model.selectElevenLabsVoice($0) }
        )
        case .xai: remoteControls(
            options: model.xaiVoiceOptions,
            selectedID: model.xaiVoiceID,
            reload: { model.loadXAIVoices() },
            select: { model.selectXAIVoice($0) }
        )
        case .openai: remoteControls(
            options: model.openaiVoiceOptions,
            selectedID: model.openaiVoiceID,
            reload: { model.loadOpenAIVoices() },
            select: { model.selectOpenAIVoice($0) }
        )
        }
    }

    private var systemControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingRow("Voice") {
                Picker("", selection: systemVoiceBinding) {
                    Text("System default").tag(String?.none)
                    ForEach(model.speechVoiceOptions) { Text($0.title).tag(Optional($0.id)) }
                }
                .labelsHidden().frame(width: 280)
            }
            Text("Tip: download a free Premium voice in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices for much better quality.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func remoteControls(options: [RemoteVoiceOption], selectedID: String, reload: @escaping () -> Void, select: @escaping (RemoteVoiceOption) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            settingRow("Voice") {
                if options.isEmpty {
                    Text("No voices loaded.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("", selection: Binding(
                        get: { selectedID },
                        set: { id in if let voice = options.first(where: { $0.id == id }) { select(voice) } }
                    )) {
                        ForEach(options) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 280)
                }
                Button("Reload", action: reload)
            }
            Button {
                model.focusIntegration(for: model.speechProvider)
            } label: {
                Label("Set this provider's key in Integrations.", systemImage: "link")
            }
            .buttonStyle(.link)
            .font(.caption2)
        }
    }

    private var systemVoiceBinding: Binding<String?> {
        Binding(
            get: { model.speechVoiceIdentifier },
            set: { id in
                if let id, let option = model.speechVoiceOptions.first(where: { $0.id == id }) {
                    model.selectSpeechVoice(option)
                } else {
                    model.selectSpeechVoice(nil)
                }
            }
        )
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
