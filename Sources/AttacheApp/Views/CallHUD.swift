import AttacheCore
import SwiftUI

extension AttacheRootView {
    // Call / Hang up: start or end a live conversation. An explicitly focused
    // session adds work context; without one this is a context-free character chat.
    var callButton: some View {
        HStack(spacing: 4) {
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
            .help(model.onCall
                  ? "Hang up. Agent updates go to your inbox."
                  : model.conversationContextSession == nil
                      ? "Call \(model.activePersonality?.name ?? "Attaché") without work-session context"
                      : "Call about the focused session")
            .accessibilityLabel(model.onCall ? "Hang up" : "Start saved call")

            if !model.onCall {
                Menu {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) { model.startPrivateCall() }
                    } label: {
                        Label("Start Private Call", systemImage: "eye.slash.fill")
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .typoIcon(size: 9, .bold)
                        .foregroundStyle(Color.primary.opacity(0.62))
                        .frame(width: 28, height: 32)
                        .background(Color.primary.opacity(0.06), in: Circle())
                        .overlay(Circle().stroke(Color.primary.opacity(0.12)))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More call options, including Private Call")
                .accessibilityLabel("More call options")
            }
        }
        .onHover { hoveredDockItem = $0 ? .talk : nil }
    }

    // A standard chat composer for the live call: destination toggle, one input
    // bar, and a bounded status region. The dock still owns the microphone and
    // call controls.
    var onCallHUD: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isPrivateConversation {
                privateCallBanner
            } else {
                callDestinationPicker
            }

            ContextOverflowRecoveryBanner()
            ExhaustiveReviewSurface()

            if model.conversationDestination == .agent {
                Label(
                    agentDestinationLabel,
                    systemImage: model.canSendToAgent ? "terminal.fill" : "exclamationmark.triangle.fill"
                )
                .typoCaption(.semibold)
                .foregroundStyle(model.canSendToAgent ? accent : Color.red)
                .lineLimit(1)
                .accessibilityLabel(agentDestinationLabel)
            } else if model.conversationContextSession == nil {
                Label("No work session context", systemImage: "shield.fill")
                    .typoCaption(.semibold)
                    .foregroundStyle(accent.opacity(0.86))
                    .lineLimit(1)
                    .accessibilityLabel("No work session context")
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
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let status = CallStatusPresentation.status(
                        for: model.callPhase,
                        now: context.date,
                        recoveryConfirmation: model.conversationRecoveryConfirmation
                    ) {
                        callStatusRow(status)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 480)
        .background(.ultraThinMaterial.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
        .readingPlate(theme: model.theme, cornerRadius: 18, minimumOpacity: 0.66)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.22)))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.isPrivateConversation ? "Private call composer" : "Live call composer")
    }

    var privateCallBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "eye.slash.fill")
                .typoIcon(size: 12, .semibold)
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Private Call")
                    .typoLabel(.bold)
                Text(model.privateConversationDisclosure)
                    .typoCaption()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Private Call. \(model.privateConversationDisclosure)")
    }

    // One status row for the whole call-phase surface (INF-244): icon (or
    // spinner) plus text, styled from the phase alone, never from scanning
    // status text for marker words.
    @ViewBuilder
    func callStatusRow(_ status: CallStatusPresentation.Status) -> some View {
        HStack(alignment: .top, spacing: 7) {
            switch status.icon {
            case .spinner:
                ProgressView().controlSize(.small)
                    .accessibilityHidden(true)
            case .symbol(let name):
                Image(systemName: name)
                    .typoIcon(size: 10, .semibold)
                    .foregroundStyle(
                        status.isError ? Color.red
                            : status.isFreshDelivery ? Color.green
                            : accent
                    )
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(status.text)
                    .typoCaption(.medium, design: .monospaced)
                    .foregroundStyle(status.isError ? Color.red.opacity(0.88) : Color.primary.opacity(0.68))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Conversation status: \(status.text)")

                if model.conversationRecovery?.offersModelSwitch == true {
                    conversationRecoveryActions
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(status.text)
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
        case .attache:
            return model.conversationContextSession == nil
                ? "Message \(model.activePersonality?.name ?? "Attaché")…"
                : "Ask about the focused session…"
        case .agent: return model.canSendToAgent ? "Tell \(model.twoWayTargetTitle ?? "the agent")…" : "Focus an agent first…"
        }
    }

    var callDestinationSummary: String {
        if model.isPrivateConversation { return "Private Attaché call" }
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

    // Whether the phase-driven status row (INF-244) should render at all.
    // `.idle` is the only phase with nothing to report; every other phase
    // renders a distinct row via `CallStatusPresentation`, except
    // `.sendDelivered` once its emphasis window passes with no reply yet
    // (INF-264): the row itself returns nil then, and the `if let` above
    // simply renders nothing, so the composer quietly loses that row's
    // height rather than showing a stale status.
    var callProgressVisible: Bool {
        model.callPhase != .idle
    }

    var idleCallStatusText: String {
        model.conversationContextSession == nil
            ? "No session attached. I can still chat."
            : "Talking about \(model.conversationContextSession?.displayTitle ?? "this session")."
    }

    var conversationRecoveryActions: some View {
        recoveryActionsView(
            providers: model.conversationRecoveryProviders,
            models: model.conversationRecoveryModels,
            currentProviderTitle: model.presentationProvider.title,
            switchAccessibilityLabel: "Switch conversation model",
            onSelectProvider: requestConversationRecoveryProvider,
            onSelectModel: { model.selectConversationRecoveryModel($0) },
            canRetry: model.canRetryConversationFailure,
            retryAccessibilityLabel: "Retry failed conversation",
            onRetry: { model.retryConversationAfterFailure() }
        )
    }

    /// The Switch model / Retry recovery affordance (INF-244), reused as-is
    /// for every surface that can classify a recoverable failure (INF-254:
    /// recap, follow-up, live follow-up) instead of each building its own.
    /// AX labels are parameters, not hardcoded, so each surface keeps its own
    /// distinct label (existing UI smoke assertions target the live call's
    /// exact strings; new surfaces get their own).
    func recoveryActionsView(
        providers: [AttachePresentationProvider],
        models: [AttachePresentationModelOption],
        currentProviderTitle: String,
        switchAccessibilityLabel: String,
        onSelectProvider: @escaping (AttachePresentationProvider) -> Void,
        onSelectModel: @escaping (AttachePresentationModelOption) -> Void,
        canRetry: Bool,
        retryAccessibilityLabel: String,
        onRetry: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Menu {
                if !providers.isEmpty {
                    Section("Use another provider") {
                        ForEach(providers) { provider in
                            Button(provider.menuTitle) {
                                onSelectProvider(provider)
                            }
                        }
                    }
                }
                if !models.isEmpty {
                    Section("Other \(currentProviderTitle) models") {
                        ForEach(models) { option in
                            Button(option.title) {
                                onSelectModel(option)
                            }
                        }
                    }
                }
                Divider()
                Button("Edit character model…") { openCharacterSettings() }
            } label: {
                Label("Switch model", systemImage: "arrow.triangle.2.circlepath")
                    .typoCaption(.semibold)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(accent.opacity(0.12), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(switchAccessibilityLabel)

            Button(action: onRetry) {
                Label("Retry", systemImage: "arrow.clockwise")
                    .typoCaption(.semibold)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canRetry)
            .accessibilityLabel(retryAccessibilityLabel)
        }
    }

    func requestConversationRecoveryProvider(_ provider: AttachePresentationProvider) {
        if model.presentationProviderSendsToCloud(provider),
           !model.cloudConsentAcknowledged(for: provider) {
            pendingCallPresentationProvider = provider
        } else {
            model.selectConversationRecoveryProvider(provider)
        }
    }

    func openCharacterSettings() {
        NotificationCenter.default.post(name: .attacheOpenSettings, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(
                name: .attacheOpenSettingsSection,
                object: SettingsSection.personalities.rawValue
            )
        }
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
        ForEach(AttacheVoiceInputMode.allCases) { mode in
            Button {
                model.voiceInputMode = mode
            } label: {
                Label(mode.title, systemImage: model.voiceInputMode == mode ? "checkmark" : mode.iconName)
            }
        }
    }
}
