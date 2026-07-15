import AttacheCore
import SwiftUI

/// A back-and-forth chat with the configured personality: your turns vs. the
/// attache's, type or hold-to-talk, replies are spoken aloud. Themed.
struct ConversationView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var micTranscript: MicTranscriptController
    var accent: Color
    @FocusState private var inputFocused: Bool
    @State private var holding = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.primary.opacity(0.12))
            thread
            Divider().overlay(Color.primary.opacity(0.12))
            inputRow
        }
        .frame(width: 580)
        .frame(maxHeight: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.20)))
        .shadow(color: .black.opacity(0.32), radius: 30, y: 12)
        .onAppear { inputFocused = true }
        .onExitCommand { model.endConversation() }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .typoIcon(size: 13, .bold)
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Conversation")
                    .typoBody(.bold)
                Text(model.conversationStatus.isEmpty
                     ? conversationTargetText
                     : model.conversationStatus)
                    .typoCaption(.medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            destinationPicker(width: 214)
            if !model.conversationMessages.isEmpty {
                Button { model.clearConversation() } label: {
                    Image(systemName: "trash").typoIcon(size: 11, .semibold)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear conversation")
            }
            Button { model.endConversation() } label: {
                Image(systemName: "xmark").typoIcon(size: 11, .bold)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Close (Esc)")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 10) {
                    if model.conversationMessages.isEmpty {
                        emptyState
                    }
                    ForEach(model.conversationMessages) { turn in
                        bubble(turn).id(turn.id)
                    }
                    if model.isAwaitingReply {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(model.isConversing ? "Thinking…" : "Speaking…")
                                .typoLabel().foregroundStyle(.secondary)
                            Spacer()
                        }
                        .id("thinking")
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: model.conversationMessages.count) { _ in
                if let last = model.conversationMessages.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: model.isAwaitingReply) { awaiting in
                if awaiting { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Ask about what you're working on")
                .typoBody(.semibold)
                .foregroundStyle(.primary.opacity(0.8))
            Text(emptyStateHint)
                .typoCaption()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func bubble(_ turn: ConversationTurn) -> some View {
        HStack {
            if turn.role == .user { Spacer(minLength: 44) }
            Text(turn.text)
                .typoBody()
                .foregroundStyle(turn.role == .user ? Color.white : Color.primary.opacity(0.92))
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(
                    turn.role == .user ? AnyShapeStyle(accent) : AnyShapeStyle(Color.primary.opacity(0.08)),
                    in: RoundedRectangle(cornerRadius: 13)
                )
            if turn.role == .assistant { Spacer(minLength: 44) }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 9) {
            micButton
            Group {
                if micActive {
                    HStack(spacing: 7) {
                        Image(systemName: "waveform")
                            .typoIcon(size: 12, .bold)
                            .foregroundStyle(accent)
                        Text(micInputText)
                            .typoBody()
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                } else {
                    TextField(inputPlaceholder, text: $model.conversationDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .typoBody()
                        .lineLimit(1...4)
                        .focused($inputFocused)
                        .onSubmit(send)
                        .accessibilityLabel("Conversation message")
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.10)))

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .typoIcon(size: 24)
                    .foregroundStyle(canSend ? accent : Color.primary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send")
            .accessibilityLabel("Send conversation message")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func destinationPicker(width: CGFloat) -> some View {
        Picker("", selection: $model.conversationDestination) {
            ForEach(ConversationDestination.allCases) { destination in
                Text(destination.title).tag(destination)
                    .disabled(destination == .agent && !model.canSendToAgent)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(width: width)
        .accessibilityLabel("Conversation destination")
        .tint(model.conversationDestination == .agent ? .orange : accent)
        .help(model.canSendToAgent
              ? "Choose where this live turn goes"
              : "Focus a Codex or Claude Code session to enable Tell Agent")
    }

    // Active = recording right now. Push-to-talk tracks the local hold; toggle and
    // always-on track the controller's listening state.
    private var micActive: Bool {
        model.voiceInputMode == .pushToTalk
            ? (holding || micTranscript.isPreparing)
            : (micTranscript.isPreparing || micTranscript.isListening)
    }

    private var micInputText: String {
        let text = micTranscript.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return micTranscript.isPreparing ? "Starting microphone..." : "Listening..."
    }

    @ViewBuilder
    private var micButton: some View {
        let active = micActive
        let styled = VoiceInputMicButtonFace(
            mode: model.voiceInputMode,
            isListening: active,
            theme: model.theme,
            size: 40,
            symbolSize: 15
        )
        .contextMenu { voiceInputModeContextMenu }

        if model.voiceInputMode == .pushToTalk {
            styled
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !holding {
                                holding = true
                                model.beginConversationDictation()
                            }
                        }
                        .onEnded { _ in
                            holding = false
                            model.endConversationDictationAndSend()
                        }
                )
                .help("Hold to talk. Right-click for mic mode.")
        } else {
            styled
                .contentShape(Circle())
                .onTapGesture { model.toggleConversationDictation() }
                .help(model.voiceInputMode == .toggle
                      ? "Click to start, click again to send. Right-click for mic mode."
                      : "Hands-free. Right-click for mic mode.")
        }
    }

    @ViewBuilder private var voiceInputModeContextMenu: some View {
        ForEach(AttacheVoiceInputMode.allCases) { mode in
            Button {
                model.voiceInputMode = mode
            } label: {
                Label(mode.title, systemImage: model.voiceInputMode == mode ? "checkmark" : mode.iconName)
                    .foregroundStyle(model.voiceInputMode == mode ? accent : Color.primary)
            }
        }
    }

    private var emptyStateHint: String {
        if model.conversationDestination == .agent {
            return model.canSendToAgent
                ? "Messages go to \(model.twoWayTargetTitle ?? "the focused agent")."
                : "Focus a Codex or Claude Code session first."
        }
        switch model.voiceInputMode {
        case .pushToTalk: return "Type below, or hold the mic to talk. I can read more of the session if I need to."
        case .toggle: return "Type below, or click the mic to start and click again to send."
        case .alwaysOn: return "Just start talking — I'm listening and send when you pause. You can also type."
        }
    }

    private var conversationTargetText: String {
        switch model.conversationDestination {
        case .attache:
            return model.conversationContextSession?.displayTitle ?? "No session attached"
        case .agent:
            return model.canSendToAgent
                ? "To \(model.twoWayTargetTitle ?? "focused agent")"
                : "No agent focused"
        }
    }

    private var inputPlaceholder: String {
        switch model.conversationDestination {
        case .attache: return "Ask about this session…"
        case .agent: return model.canSendToAgent
            ? "Tell \(model.twoWayTargetSourceName ?? "agent") · \(model.twoWayTargetTitle ?? "focused session")…"
            : "Focus an agent first…"
        }
    }

    private var canSend: Bool {
        !model.conversationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isAwaitingReply
            && (model.conversationDestination != .agent || model.canSendToAgent)
    }

    private func send() {
        guard canSend else { return }
        model.sendConversationMessage(model.conversationDraft)
    }
}
