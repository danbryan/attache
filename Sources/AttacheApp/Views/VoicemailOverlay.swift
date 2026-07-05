import AttacheCore
import SwiftUI

extension CompanionRootView {
    var voicemailModeOverlay: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 920
            Group {
                if compact {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            voicemailInboxPanel
                            cardControlPanel
                        }
                        .frame(maxWidth: min(620, proxy.size.width - 36), alignment: .topLeading)
                        .padding(.horizontal, 18)
                        .padding(.top, 78)
                        .padding(.bottom, 24)
                    }
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        voicemailInboxPanel
                            .frame(width: 360)
                        cardControlPanel
                            .frame(width: 500)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 86)
                    .padding(.horizontal, 24)
                }
            }
            .background(Color.black.opacity(0.18).ignoresSafeArea())
        }
    }

    var voicemailInboxPanel: some View {
        let visibleCards = model.scopedUnreadCards
        return VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Inbox")
                        .typoDisplay(size: 20, .bold)
                    Text("Updates waiting for you. Press Esc to return.")
                        .typoCaption(.medium)
                        .foregroundStyle(.primary.opacity(0.58))
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        surfaceMode = .live
                    }
                } label: {
                    Image(systemName: "xmark")
                        .typoIcon(size: 11, .bold)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary.opacity(0.70))
                .background(Color.primary.opacity(0.07), in: Circle())
                .help("Back to Live")
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Picker("", selection: $model.inboxScope) {
                ForEach(VoicemailInboxScope.allCases) { scope in
                    Text(scope.titleWithCount(model.unreadCount(for: scope))).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            Divider().overlay(Color.primary.opacity(0.12))

            if visibleCards.isEmpty {
                VStack(spacing: 12) {
                    Spacer(minLength: 48)
                    Image(systemName: "tray")
                        .typoIcon(size: 28, .regular)
                        .foregroundStyle(.secondary)
                    Text("No voicemail")
                        .typoBody(.semibold)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 48)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleCards) { card in
                            CardRow(
                                card: card,
                                selected: card.id == model.selectedCard?.id,
                                playing: playback.currentCardID == card.id && playback.isPlaying
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectedCardID = card.id
                            }
                            .onTapGesture(count: 2) {
                                model.selectedCardID = card.id
                                model.playSelected()
                            }
                            .contextMenu {
                                Button("Delete Voicemail") {
                                    model.selectedCardID = card.id
                                    model.archiveSelected()
                                }
                            }
                        }
                    }
                    .padding(14)
                }
                .frame(maxHeight: 420)
            }

            Divider().overlay(Color.primary.opacity(0.10))

            HStack(spacing: 10) {
                Button {
                    model.archiveCards(visibleCards)
                } label: {
                    Label("Clear Visible", systemImage: "trash")
                }
                .disabled(visibleCards.isEmpty)

                Button {
                    model.simulateEvent()
                } label: {
                    Label("Add sample", systemImage: "waveform.badge.plus")
                }

                Spacer()

                Text("\(visibleCards.count) of \(model.unreadCount) unread")
                    .typoCaption(.semibold, design: .rounded)
                    .foregroundStyle(visibleCards.isEmpty ? Color.primary.opacity(0.45) : accent)
            }
            .buttonStyle(.bordered)
            .padding(14)
        }
        .background(.ultraThinMaterial.opacity(0.86), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.13))
        )
    }

    @ViewBuilder
    var cardControlPanel: some View {
        if let card = model.selectedCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.sessionTitle ?? card.summary)
                            .typoTitle()
                            .lineLimit(1)
                        Text(cardContext(card))
                            .typoCaption(.medium, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    StatusPill(status: card.status)
                }

                codexAttachmentControl

                playbackControls(for: card)

                Text(card.summary)
                    .typoBody(.medium)
                    .foregroundStyle(.primary.opacity(0.82))
                    .lineLimit(3)

                if let notice = presentationNotice(for: card) {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .typoCaption(.medium)
                        .foregroundStyle(.yellow.opacity(0.92))
                        .lineLimit(3)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.yellow.opacity(0.18))
                        )
                }

                followUp(for: card)

                HStack {
                    Text(model.intakeStatus)
                        .typoCaption(design: .monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        controlsPinned.toggle()
                    } label: {
                        Image(systemName: controlsPinned ? "pin.slash" : "pin")
                    }
                    .buttonStyle(.borderless)
                    .help(controlsPinned ? "Unpin overlay" : "Pin overlay")
                }
            }
            .padding(16)
            .background(.ultraThinMaterial.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.12))
            )
        }
    }

    func liveSessionComposer(for target: CodexSessionTarget) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label("Ask Attaché about \(target.displayTitle)", systemImage: "bubble.left.and.bubble.right")
                    .typoLabel(.bold)
                    .foregroundStyle(accent)
                    .lineLimit(1)
                Spacer()
                Text(target.activityLabel)
                    .typoCaption(.medium)
                    .foregroundStyle(.primary.opacity(0.52))
                    .lineLimit(1)
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        liveComposerVisible = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .typoIcon(size: 9, .bold)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary.opacity(0.62))
                .background(Color.primary.opacity(0.08), in: Circle())
                .help("Hide composer")
            }

            TextEditor(text: $model.liveFollowUpText)
                .typoBody()
                .scrollContentBackground(.hidden)
                .frame(minHeight: 46, maxHeight: 68)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.10))
                )

            HStack(spacing: 8) {
                Text(model.liveFollowUpStatus)
                    .typoCaption()
                    .foregroundStyle(.primary.opacity(0.58))
                    .lineLimit(2)
                Spacer()
                Button {
                    if micTranscript.isListening {
                        model.useMicTranscriptForLiveFollowUp()
                    } else {
                        model.toggleVoiceInput()
                    }
                } label: {
                    Label(micTranscript.isListening ? "Use Transcript" : "Dictate", systemImage: micTranscript.isListening ? "checkmark.circle" : "mic")
                }
                Button {
                    model.createLiveFollowUpAnswer()
                } label: {
                    if model.isGeneratingLiveFollowUpAnswer {
                        Label("Answering", systemImage: "hourglass")
                    } else {
                        Label(model.liveFollowUpAnswerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Ask Attaché" : "Ask Again", systemImage: "sparkles")
                    }
                }
                .disabled(model.isGeneratingLiveFollowUpAnswer || directFollowUpQuestionDisabled)
                // Distinct direction: this sends INTO the agent, not to Attaché.
                // Different icon + orange tint so the two are unmistakable.
                if model.canSendToAgent {
                    Button {
                        model.requestSendToAgent()
                    } label: {
                        Label("Send to Agent", systemImage: "paperplane.fill")
                    }
                    .tint(.orange)
                    .disabled(directFollowUpQuestionDisabled)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if model.isGeneratingLiveFollowUpAnswer {
                ProgressView()
                    .controlSize(.small)
            }

            if !model.liveFollowUpAnswerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Answer")
                            .typoLabel(.semibold)
                            .foregroundStyle(.primary.opacity(0.72))
                        Spacer()
                        Button {
                            model.copyLiveFollowUpAnswer()
                        } label: {
                            Label("Copy Answer", systemImage: "doc.on.doc")
                        }
                        Button {
                            model.clearLiveFollowUpAnswer()
                        } label: {
                            Label("Clear", systemImage: "xmark.circle")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text("An answer from what it observed. Nothing is sent back to the agent.")
                        .typoCaption(.medium)
                        .foregroundStyle(.primary.opacity(0.54))
                        .lineLimit(2)

                    TextEditor(text: $model.liveFollowUpAnswerText)
                        .typoLabel(design: .monospaced)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 82, maxHeight: 132)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(accent.opacity(0.22))
                        )
                }
            }
        }
        .padding(13)
        .frame(width: 520)
        .background(.ultraThinMaterial.opacity(0.68), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accent.opacity(0.18))
        )
    }

    func followUp(for card: VoicemailCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ask Attaché")
                    .typoLabel(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(followUpTargetLabel(for: card))
                    .typoCaption(.medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            TextEditor(text: $model.followUpText)
                .typoBody()
                .scrollContentBackground(.hidden)
                .frame(minHeight: 58, maxHeight: 76)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.10))
                )

            HStack {
                Text(model.followUpStatus)
                    .typoCaption()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Spacer()
                Button {
                    model.createFollowUpAnswer()
                } label: {
                    if model.isGeneratingFollowUpAnswer {
                        Label("Answering", systemImage: "hourglass")
                    } else {
                        Label(model.followUpAnswerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Ask Attaché" : "Ask Again", systemImage: "sparkles")
                    }
                }
                .disabled(model.isGeneratingFollowUpAnswer || model.followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if model.isGeneratingFollowUpAnswer {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !model.followUpAnswerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Answer")
                            .typoLabel(.semibold)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            model.copyFollowUpAnswer()
                        } label: {
                            Label("Copy Answer", systemImage: "doc.on.doc")
                        }
                        Button {
                            model.clearFollowUpAnswer()
                        } label: {
                            Label("Clear", systemImage: "xmark.circle")
                        }
                    }
                    .buttonStyle(.bordered)

                    Text("An answer from what it observed. Nothing is sent back to the agent.")
                        .typoCaption(.medium)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    TextEditor(text: $model.followUpAnswerText)
                        .typoLabel(design: .monospaced)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 112, maxHeight: 168)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(accent.opacity(0.22))
                        )
                }
            }
        }
    }

    var directFollowUpQuestionDisabled: Bool {
        let typed = model.liveFollowUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = micTranscript.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty && spoken.isEmpty
    }

    func playbackControls(for card: VoicemailCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Button {
                    model.toggleSelectedPlayback()
                } label: {
                    Image(systemName: primaryPlaybackIcon(for: card))
                }
                .help(primaryPlaybackHelp(for: card))
                .accessibilityLabel(primaryPlaybackHelp(for: card))

                Button {
                    model.replaySelected()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Replay")
                .accessibilityLabel("Replay")

                Button {
                    model.skipBackward()
                } label: {
                    Image(systemName: "gobackward")
                }
                .disabled(!canSeek(card))
                .help("Back \(model.seekStepSeconds)s")

                Button {
                    model.skipForward()
                } label: {
                    Image(systemName: "goforward")
                }
                .disabled(!canSeek(card))
                .help("Forward \(model.seekStepSeconds)s")

                Button {
                    model.cyclePlaybackSpeed()
                } label: {
                    Text(model.playbackSpeedLabel)
                        .typoCaption(.bold, monoDigit: true)
                        .foregroundStyle(abs(model.playbackSpeed - 1.0) < 0.01 ? Color.secondary : accent)
                }
                .disabled(!canSeek(card))
                .help("Playback speed. Click to cycle; S slower, D faster, R resets.")
                .accessibilityLabel("Playback speed \(model.playbackSpeedLabel)")

                Divider().frame(height: 22)

                Button {
                    model.markSelectedHeard()
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .help("Mark heard")

                Button {
                    model.archiveSelected()
                } label: {
                    Image(systemName: "archivebox")
                }
                .help("Archive")

                Spacer()

                PlaybackTimeLabel(
                    timeline: playback.clock,
                    isActiveCard: isActiveCard(card),
                    playbackDurationMs: playback.durationMs,
                    cardDurationMs: card.durationMs,
                    fallbackProgress: model.selectedStartProgress
                )
            }
            .buttonStyle(.bordered)

            HStack(spacing: 10) {
                PlaybackScrubberSlider(
                    timeline: playback.clock,
                    isActiveCard: isActiveCard(card),
                    playbackDurationMs: playback.durationMs,
                    fallbackProgress: model.selectedStartProgress,
                    canSeek: canSeek(card),
                    onSeek: { model.seekSelected(to: $0) }
                )
                Stepper(value: $model.seekStepSeconds, in: 2...30, step: 1) {
                    Text("\(model.seekStepSeconds)s")
                        .typoCaption(.medium, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                .help("Skip interval")
            }
        }
    }

    var codexAttachmentControl: some View {
        Menu {
            codexSessionCommands
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.attachedCodexSessionID == nil ? "link.badge.plus" : "link")
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.attachedCodexSessionID == nil ? "Attach a session" : "Attached to")
                        .typoCaption(.semibold)
                        .foregroundStyle(.secondary)
                    Text(model.attachedCodexSessionLabel)
                        .typoCaption(.medium, design: .monospaced)
                        .lineLimit(1)
                }
                Spacer()
                Circle()
                    .fill(model.attachedCodexSessionID == nil ? Color.primary.opacity(0.28) : accent)
                    .frame(width: 7, height: 7)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    func presentationNotice(for card: VoicemailCard) -> String? {
        let metadata = metadataDictionary(for: card)
        let strategy = metadata["companion_presentation_strategy"] ?? ""
        switch strategy {
        case "companion-personality-llm":
            return nil
        case "plain-readback":
            return "Read the source output verbatim because personality summary is off."
        case "plain-readback-personality-unavailable":
            return "Read the source output verbatim because personality summary is not configured."
        case "plain-readback-after-llm-error":
            return "Read the source output verbatim because personality summary couldn't run."
        default:
            return nil
        }
    }

    func metadataDictionary(for card: VoicemailCard) -> [String: String] {
        guard let data = card.metadataJSON.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in raw {
            if let string = value as? String {
                result[key] = string
            } else {
                result[key] = String(describing: value)
            }
        }
        return result
    }

    func followUpTargetLabel(for card: VoicemailCard) -> String {
        if let title = card.sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return "this session"
    }

    var codexSessionCommands: some View {
        Group {
            Button("Refresh sessions") {
                model.refreshCodexSessions()
            }
            Button("Detach") {
                model.attachCodexSession(nil)
            }
            .disabled(model.attachedCodexSessionID == nil)
            Divider()
            if model.codexSessions.isEmpty {
                Text("No active sessions")
            }
            if !model.codexSessions.isEmpty {
                Text("Active sessions")
                ForEach(model.codexSessions) { session in
                    codexTargetButton(session)
                }
            }
            if !model.archivedCodexSessions.isEmpty {
                Divider()
                Menu("Archived sessions") {
                    ForEach(model.archivedCodexSessions) { session in
                        codexTargetButton(session)
                    }
                }
            }
        }
    }

    func codexTargetButton(_ target: CodexSessionTarget) -> some View {
        Button {
            model.attachCodexSession(target)
        } label: {
            selectedLabel(codexSessionLabel(target), selected: model.attachedCodexSessionID == target.id)
        }
    }

    func voiceButton(_ voice: CompanionVoiceOption) -> some View {
        Button {
            model.selectSpeechVoice(voice)
        } label: {
            selectedLabel(voice.title, selected: model.speechProvider == .system && model.speechVoiceIdentifier == voice.id)
        }
    }

    func remoteVoiceButton(_ voice: RemoteVoiceOption) -> some View {
        Button {
            switch voice.provider {
            case .elevenLabs:
                model.selectElevenLabsVoice(voice)
            case .xai:
                model.selectXAIVoice(voice)
            case .openai:
                model.selectOpenAIVoice(voice)
            case .system:
                break
            }
        } label: {
            let selected = (voice.provider == .elevenLabs && model.speechProvider == .elevenLabs && model.elevenLabsVoiceID == voice.id)
                || (voice.provider == .xai && model.speechProvider == .xai && model.xaiVoiceID == voice.id)
                || (voice.provider == .openai && model.speechProvider == .openai && model.openaiVoiceID == voice.id)
            selectedLabel(voice.title, selected: selected)
        }
    }

    func codexSessionLabel(_ session: CodexSessionTarget) -> String {
        "\(session.displayTitle) — \(session.activityLabel)"
    }

    var primaryPlaybackContextTitle: String {
        guard let card = model.selectedCard else { return "Play Card" }
        return primaryPlaybackHelp(for: card)
    }

    @ViewBuilder
    func selectedLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    func brightnessButton(_ title: String, level: Int) -> some View {
        Button {
            model.brightnessLevel = level
        } label: {
            selectedLabel(title, selected: model.brightnessLevel == level)
        }
    }

    func intensityButton(_ title: String, value: Double) -> some View {
        Button {
            model.visualIntensity = value
        } label: {
            selectedLabel(title, selected: abs(model.visualIntensity - value) < 0.01)
        }
    }

    var captionOffsets: [Int] {
        [-2_000, -1_500, -1_000, -750, -500, -330, -250, 0, 250, 330, 500, 750, 1_000, 1_500, 2_000, 3_000, 4_000, 5_000, 6_000, 8_000, 10_000]
    }

    func offsetLabel(_ milliseconds: Int) -> String {
        if milliseconds == 0 { return "0s" }
        let seconds = Double(milliseconds) / 1000.0
        let sign = seconds > 0 ? "+" : ""
        if milliseconds % 1000 == 0 {
            return "\(sign)\(milliseconds / 1000)s"
        }
        return "\(sign)\(String(format: "%.2f", seconds))s"
    }
}

/// Transient chip that pokes through the ambient glow when news arrives.
private struct HomeNoticeChip: View {
    let notice: HomeNotice
    var onTap: () -> Void
    @Environment(\.themeAccent) private var accent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .typoIcon(size: 12, .semibold)
                .foregroundStyle(accent)
            Text(notice.text)
                .typoLabel(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if notice.kind == .voicemail {
                Image(systemName: "chevron.right")
                    .typoIcon(size: 9, .bold)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(accent.opacity(0.30)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
        .help(notice.kind == .voicemail ? "Open the inbox" : notice.text)
    }

    private var icon: String {
        switch notice.kind {
        case .voicemail: return "voicemail"
        case .mode: return "bell.badge"
        case .info: return "info.circle"
        }
    }
}
