import SwiftUI

extension CompanionRootView {
    // Call / Hang up: start or end a live two-way with the focused session. While on a
    // call its updates speak; off a call everything waits in the inbox.
    var callButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                if model.onCall { model.endCall() } else { model.startCall() }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: model.onCall ? "phone.down.fill" : "phone.fill")
                    .typoIcon(size: 13, .semibold)
                Text(model.onCall ? "Hang up" : "Call")
                    .typoLabel(.medium)
            }
            .foregroundStyle(model.onCall ? Color.red : (hoveredDockItem == .talk ? accent : Color.primary.opacity(0.82)))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                Capsule().fill(Color.primary.opacity(0.06))
                    .overlay(Capsule().stroke(model.onCall ? Color.red.opacity(0.45) : Color.primary.opacity(0.12)))
            )
        }
        .buttonStyle(.plain)
        .onHover { hoveredDockItem = $0 ? .talk : nil }
        .help(model.onCall ? "Hang up (updates go to your inbox)" : "Call the focused session (talk live)")
    }

    // On a call: stay on the talking screen (the agent's voice plays on the visualizer
    // behind this). A compact HUD to talk back; Hang up lives in the dock.
    // The June design, restored: on a call the surface is just a typed
    // fallback capsule. The dock mic owns voice input, the mic status lives
    // in the tooltip, and there is no box.
    var onCallHUD: some View {
        HStack(spacing: 8) {
            callDestinationPicker
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField(callMessagePlaceholder, text: $model.conversationDraft)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Call message")
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(.regularMaterial.opacity(0.82), in: Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
                        .frame(width: 320)
                        .onSubmit(sendCallMessage)
                        .help(callMicStatusText)

                    Button(action: sendCallMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .typoIcon(size: 26)
                            .foregroundStyle(canSendCallMessage ? accent : Color.primary.opacity(0.28))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSendCallMessage)
                    .help("Send")
                    .accessibilityLabel("Send call message")
                }

                if callProgressVisible {
                    HStack(spacing: 7) {
                        if model.isConversing {
                            ProgressView().controlSize(.small)
                                .accessibilityHidden(true)
                        }
                        Text(model.conversationProgressText)
                            .typoCaption(.medium, design: .monospaced)
                            .foregroundStyle(.primary.opacity(0.68))
                            .lineLimit(1)
                            .help("Conversation status")
                    }
                    .padding(.horizontal, 10)
                }

                if callReplyVisible {
                    Text(callReplyText)
                        .typoBody(.regular)
                        .foregroundStyle(.primary.opacity(0.86))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.08))
                        )
                        .accessibilityIdentifier("Conversation reply")
                }
            }
            .frame(width: 374, alignment: .leading)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, onCallHUDBottomPadding)
    }

    var callDestinationPicker: some View {
        Picker("", selection: $model.conversationDestination) {
            ForEach(ConversationDestination.allCases) { destination in
                Text(destination.title).tag(destination)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(width: 206)
        .accessibilityLabel("Conversation destination")
        .help("Choose where this live turn goes")
    }

    var callMicActive: Bool {
        model.voiceInputMode == .pushToTalk
            ? (callHolding || micTranscript.isPreparing)
            : (micTranscript.isPreparing || micTranscript.isListening)
    }

    var callMicStatusText: String {
        if model.isConversing {
            return "Sent to \(callDestinationSummary). Waiting for reply."
        }
        if micTranscript.isPreparing {
            return "Starting microphone..."
        }
        if micTranscript.isListening {
            switch model.voiceInputMode {
            case .pushToTalk:
                return "Release the mic to send this turn to \(callDestinationSummary)."
            case .toggle:
                return "Click the mic again to send this turn to \(callDestinationSummary)."
            case .alwaysOn:
                return "Pause briefly to send this turn to \(callDestinationSummary)."
            }
        }
        let micStatus = micTranscript.status.trimmingCharacters(in: .whitespacesAndNewlines)
        if !micStatus.isEmpty, micStatus != "Voice input off." {
            return "\(micStatus) Right-click the mic for options."
        }
        return "Right-click the mic for options."
    }

    var callMessagePlaceholder: String {
        switch model.conversationDestination {
        case .attache: return "Type instead…"
        case .agent: return model.canSendToAgent ? "Tell the agent…" : "Focus an agent first…"
        }
    }

    var callDestinationSummary: String {
        switch model.conversationDestination {
        case .attache:
            return model.presentationProviderSummary
        case .agent:
            return model.twoWayTargetTitle ?? "the focused agent"
        }
    }

    var canSendCallMessage: Bool {
        !model.conversationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isAwaitingReply
    }

    var callProgressVisible: Bool {
        let status = model.conversationProgressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !status.isEmpty else { return false }
        if model.isAwaitingReply { return true }
        return status != idleCallStatusText
    }

    var callReplyText: String {
        model.liveConversationReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var callReplyVisible: Bool {
        !callReplyText.isEmpty
    }

    var idleCallStatusText: String {
        model.talkContextSession == nil
            ? "No session attached — I can still chat."
            : "Talking about \(model.talkContextSession?.displayTitle ?? "this session")."
    }

    func sendCallMessage() {
        let text = model.conversationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.sendConversationMessage(text)
    }

    @ViewBuilder var callMicButton: some View {
        let active = callMicActive
        let styled = VoiceInputMicButtonFace(
            mode: model.voiceInputMode,
            isListening: active,
            theme: model.theme,
            size: 46,
            symbolSize: 17
        )
        .contextMenu { voiceInputModeContextMenu }
        if model.voiceInputMode == .pushToTalk {
            styled.gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !callHolding { callHolding = true; model.beginConversationDictation() } }
                    .onEnded { _ in callHolding = false; model.endConversationDictationAndSend() }
            ).help("Hold to talk. Right-click for mic mode.")
        } else {
            styled.contentShape(Circle()).onTapGesture { model.toggleConversationDictation() }
                .help(model.voiceInputMode == .toggle
                      ? "Click to start, click again to send. Right-click for mic mode."
                      : "Hands-free. Right-click for mic mode.")
        }
    }

    @ViewBuilder var voiceInputModeContextMenu: some View {
        ForEach(CompanionVoiceInputMode.allCases) { mode in
            Button {
                model.voiceInputMode = mode
            } label: {
                Label(mode.title, systemImage: model.voiceInputMode == mode ? "checkmark" : mode.iconName)
            }
        }
    }

    var onCallHUDBottomPadding: CGFloat {
        liveTransportVisible ? liveBottomHUDMaxHeight + 96 : 78
    }
}
