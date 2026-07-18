import SwiftUI

/// A compact list of providers. Each row collapses to a name + health dot;
/// expand it to enter the API key / endpoint. The dot reflects a real health
/// check against the endpoint, not just whether a key was typed.
struct IntegrationsPane: View {
    @ObservedObject var model: AppModel
    @State private var expanded: String?

    private struct Provider {
        let id: String
        let name: String
        let powers: String
        let hasKey: Bool
        let hasEndpoint: Bool
        let guide: AttacheDocumentationLinks.ModelIntegrationGuide
    }

    private let providers: [Provider] = [
        Provider(id: "xai", name: "xAI / Grok", powers: "Model + Voice", hasKey: true, hasEndpoint: false, guide: .xai),
        Provider(id: "elevenlabs", name: "ElevenLabs", powers: "Voice", hasKey: true, hasEndpoint: false, guide: .elevenLabs),
        Provider(id: "openai", name: "OpenAI", powers: "Voice", hasKey: true, hasEndpoint: false, guide: .openAIVoice),
        Provider(id: "ollama", name: "Ollama", powers: "Model · local", hasKey: false, hasEndpoint: true, guide: .ollama),
        Provider(id: "custom", name: "OpenAI-compatible", powers: "Model", hasKey: true, hasEndpoint: true, guide: .openAICompatible),
        Provider(id: "claude", name: "Claude Code", powers: "Model · subscription", hasKey: false, hasEndpoint: false, guide: .claudeCode),
        Provider(id: "ondevice", name: "On-device (Apple)", powers: "Voice", hasKey: false, hasEndpoint: false, guide: .onDeviceVoice)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Integrations").typoTitle()
            Text("Attaché files agent updates as voicemail in your Inbox. Go live on a session when you want it narrated in real time.")
                .typoLabel()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Connect a provider to use it in an Attaché's Model or Voice. Each row includes a short setup guide and a real readiness check.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            localSources
            agentInstructions

            VStack(spacing: 5) {
                ForEach(providers, id: \.id) { provider in
                    row(provider)
                }
            }
        }
        .onAppear { model.checkAllIntegrations() }
        .onAppear { expanded = model.integrationFocusProviderID }
        .onChange(of: model.integrationFocusProviderID) { providerID in
            if let providerID { expanded = providerID }
        }
    }

    private var localSources: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local agent sources")
                .typoBody(.semibold)
            Text("Enable a local source before Attaché indexes or shows its session transcripts. Data stays on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Codex sessions", isOn: Binding(
                get: { model.codexSourceEnabled },
                set: { model.setCodexSourceEnabled($0) }
            ))
            Toggle("Claude Code sessions", isOn: Binding(
                get: { model.claudeCodeSourceEnabled },
                set: { model.setClaudeCodeSourceEnabled($0) }
            ))
            Toggle("Grok Build sessions", isOn: Binding(
                get: { model.grokBuildSourceEnabled },
                set: { model.setGrokBuildSourceEnabled($0) }
            ))
            Toggle("opencode sessions", isOn: Binding(
                get: { model.opencodeSourceEnabled },
                set: { model.setOpencodeSourceEnabled($0) }
            ))
            Toggle("Precise Claude Code status", isOn: $model.installClaudeHooks)
            Text("Adds Attaché's Notification and Stop hooks so Attaché reactions update immediately. Turning it off removes only Attaché's hooks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Claude Code exposes hooks that report tool-by-tool status; other agents are followed through their session files, which is close but less immediate.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    private var agentInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent instructions")
                .typoBody(.semibold)
            Text("Reverse-send writes into the focused agent session with your own agent permissions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Skip final send confirmation", isOn: Binding(
                get: { model.directAgentSendEnabled },
                set: { model.directAgentSendEnabled = $0 }
            ))
            .accessibilityLabel("Skip final send confirmation")
            Text("After you enable send-to-agent for a session, explicit Tell Agent turns can send directly. Ask Attaché handoffs always show the exact message and frozen target for confirmation because model tool calls can be influenced by session evidence.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    private func row(_ provider: Provider) -> some View {
        let isExpanded = expanded == provider.id
        let expandable = true
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                healthDot(model.healthStatus(provider.id))
                Text(provider.name).typoBody(.medium)
                Text(provider.powers)
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                Spacer()
                if expandable {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 11)
            .contentShape(Rectangle())
            .onTapGesture {
                guard expandable else { return }
                withAnimation(.easeInOut(duration: 0.15)) { expanded = isExpanded ? nil : provider.id }
            }

            if isExpanded {
                config(provider).padding(.horizontal, 11).padding(.bottom, 11)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private func config(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if provider.hasEndpoint {
                HStack(spacing: 8) {
                    Text("Endpoint").font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    TextField("Base URL", text: endpointBinding(provider.id)).textFieldStyle(.roundedBorder)
                }
            }
            if provider.hasKey {
                RevealableAPIKeyField(
                    placeholder: "API key",
                    accessibilityName: "\(provider.name) API key",
                    text: keyBinding(provider.id)
                )
            }
            HStack {
                statusText(model.healthStatus(provider.id))
                Link("Setup guide", destination: AttacheDocumentationLinks.modelIntegration(provider.guide))
                    .font(.caption)
                Spacer()
                Button(provider.hasKey ? "Save & Test" : "Test") { saveAndTest(provider) }
            }
        }
    }

    @ViewBuilder private func healthDot(_ health: IntegrationHealth) -> some View {
        switch health {
        case .unconfigured:
            Image(systemName: "circle").typoIcon(size: 11).foregroundStyle(.secondary)
        case .checking:
            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
        case .healthy:
            Image(systemName: "checkmark.circle.fill").typoIcon(size: 13).foregroundStyle(.green)
        case .unhealthy:
            Image(systemName: "xmark.circle.fill").typoIcon(size: 13).foregroundStyle(.red)
        }
    }

    @ViewBuilder private func statusText(_ health: IntegrationHealth) -> some View {
        switch health {
        case .unconfigured:
            Text("Not configured").font(.caption).foregroundStyle(.secondary)
        case .checking:
            Text("Testing…").font(.caption).foregroundStyle(.secondary)
        case .healthy:
            Text("Connected").font(.caption).foregroundStyle(.green)
        case .unhealthy(let message):
            Text("Failed: \(message)").font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private func saveAndTest(_ provider: Provider) {
        switch provider.id {
        case "xai": model.saveXAIIntegration()
        case "elevenlabs": model.saveElevenLabsKeyAndLoadVoices()
        case "openai": model.saveOpenAIVoiceIntegration()
        case "custom": model.saveCustomIntegration()
        default: break
        }
        model.checkIntegration(provider.id)
    }

    private func keyBinding(_ id: String) -> Binding<String> {
        switch id {
        case "xai": return $model.xaiAPIKey
        case "elevenlabs": return $model.elevenLabsAPIKey
        case "openai": return $model.openaiVoiceAPIKey
        case "custom": return $model.customAPIKey
        default: return .constant("")
        }
    }

    private func endpointBinding(_ id: String) -> Binding<String> {
        switch id {
        case "ollama": return $model.ollamaBaseURL
        case "custom": return $model.customBaseURL
        default: return .constant("")
        }
    }
}

/// The standard credential field used everywhere an integration can be
/// configured. It is masked by default and reveals only after an explicit eye
/// button press. The reveal state is intentionally ephemeral and never saved.
struct RevealableAPIKeyField: View {
    var placeholder: String
    var accessibilityName: String
    @Binding var text: String
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(accessibilityName)

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isRevealed ? "Hide \(accessibilityName)" : "Reveal \(accessibilityName)")
            .help(isRevealed ? "Hide API key" : "Reveal API key")
        }
    }
}
