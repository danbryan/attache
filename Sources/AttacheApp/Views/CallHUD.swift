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

    // A standard chat composer for the live call: destination toggle, one input
    // bar, and a bounded status region. The dock still owns the microphone and
    // call controls.
    var onCallHUD: some View {
        VStack(alignment: .leading, spacing: 8) {
            callDestinationPicker

            if model.conversationDestination == .agent || !model.canSendToAgent {
                Label(
                    agentDestinationLabel,
                    systemImage: model.canSendToAgent ? "terminal.fill" : "exclamationmark.triangle.fill"
                )
                .typoCaption(.semibold)
                .foregroundStyle(model.canSendToAgent ? accent : Color.red)
                .lineLimit(1)
                .accessibilityLabel(agentDestinationLabel)
            }

            HStack(spacing: 8) {
                TextField(callMessagePlaceholder, text: $model.conversationDraft)
                    .textFieldStyle(.plain)
                    .typoBody()
                    .accessibilityLabel("Call message")
                    .onSubmit(sendCallMessage)
                    .help(callMicStatusText)

                Button(action: sendCallMessage) {
                    Image(systemName: "arrow.up")
                        .typoIcon(size: 13, .bold)
                        .foregroundStyle(canSendCallMessage ? model.theme.signatureForegroundColor : Color.primary.opacity(0.32))
                        .frame(width: 30, height: 30)
                        .background(canSendCallMessage ? accent : Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSendCallMessage)
                .help("Send")
                .accessibilityLabel("Send call message")
            }
            .padding(.leading, 13)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))

            if callProgressVisible {
                HStack(alignment: .top, spacing: 7) {
                    if model.isConversing {
                        ProgressView().controlSize(.small)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: callStatusIsError ? "exclamationmark.triangle.fill" : "info.circle")
                            .typoIcon(size: 10, .semibold)
                            .foregroundStyle(callStatusIsError ? Color.red : accent)
                    }
                    Text(callStatusDisplayText)
                        .typoCaption(.medium, design: .monospaced)
                        .foregroundStyle(callStatusIsError ? Color.red.opacity(0.88) : Color.primary.opacity(0.68))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(model.conversationProgressText)
                .accessibilityLabel("Conversation status: \(callStatusDisplayText)")
            }
        }
        .padding(10)
        .frame(width: 480)
        .background(.ultraThinMaterial.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
        .readingPlate(theme: model.theme, cornerRadius: 18, minimumOpacity: 0.66)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.22)))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live call composer")
    }

    var callDestinationPicker: some View {
        Picker("", selection: $model.conversationDestination) {
            ForEach(ConversationDestination.allCases) { destination in
                Label(
                    destination.title,
                    systemImage: destination == .attache ? "sparkles" : "terminal"
                )
                    .tag(destination)
                    .disabled(destination == .agent && !model.canSendToAgent)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .tint(accent)
        .accessibilityLabel("Conversation destination, \(callDestinationSummary)")
        .help(model.canSendToAgent
              ? "Choose where this live turn goes"
              : "Focus a Codex or Claude Code session to enable Tell Agent")
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
        case .agent: return model.canSendToAgent ? "Tell \(model.twoWayTargetTitle ?? "the agent")…" : "Focus an agent first…"
        }
    }

    var callDestinationSummary: String {
        switch model.conversationDestination {
        case .attache:
            return model.presentationProviderSummary
        case .agent:
            return model.canSendToAgent
                ? "\(model.twoWayTargetSourceName ?? "Agent") / \(model.twoWayTargetTitle ?? "focused session")"
                : "no focused agent"
        }
    }

    var agentDestinationLabel: String {
        guard model.canSendToAgent else { return "Focus a session to enable Tell Agent" }
        return "Tell \(model.twoWayTargetSourceName ?? "Agent") · \(model.twoWayTargetTitle ?? "Focused session")"
    }

    var canSendCallMessage: Bool {
        !model.conversationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isAwaitingReply
            && (model.conversationDestination != .agent || model.canSendToAgent)
    }

    var callProgressVisible: Bool {
        let status = model.conversationProgressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !status.isEmpty else { return false }
        if model.isAwaitingReply { return true }
        return status != idleCallStatusText
    }

    var callStatusIsError: Bool {
        let status = model.conversationProgressText.lowercased()
        return status.contains("exited with code")
            || status.contains("failed")
            || status.contains("error")
            || status.contains("problem")
    }

    var callStatusDisplayText: String {
        let status = model.conversationProgressText
        let lower = status.lowercased()
        guard callStatusIsError,
              let colon = status.firstIndex(of: ":") else { return status }
        let detail = status[status.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.hasPrefix("codex exited") {
            return detail.isEmpty ? "Codex couldn't respond." : "Codex couldn't respond: \(detail)"
        }
        if lower.hasPrefix("claude exited") {
            return detail.isEmpty ? "Claude Code couldn't respond." : "Claude Code couldn't respond: \(detail)"
        }
        return status
    }

    var idleCallStatusText: String {
        model.conversationContextSession == nil
            ? "No session attached — I can still chat."
            : "Talking about \(model.conversationContextSession?.displayTitle ?? "this session")."
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
}
