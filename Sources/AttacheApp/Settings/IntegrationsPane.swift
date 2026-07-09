import SwiftUI

/// A compact list of providers. Each row collapses to a name + health dot;
/// expand it to enter the API key / endpoint. The dot reflects a real health
/// check against the endpoint, not just whether a key was typed.
struct IntegrationsPane: View {
    @ObservedObject var model: AppModel
    @State private var expanded: String?
    @State private var showKey: [String: Bool] = [:]

    private struct Provider {
        let id: String
        let name: String
        let powers: String
        let hasKey: Bool
        let hasEndpoint: Bool
    }

    private let providers: [Provider] = [
        Provider(id: "xai", name: "xAI / Grok", powers: "Model + Voice", hasKey: true, hasEndpoint: false),
        Provider(id: "elevenlabs", name: "ElevenLabs", powers: "Voice", hasKey: true, hasEndpoint: false),
        Provider(id: "openai", name: "OpenAI", powers: "Voice", hasKey: true, hasEndpoint: false),
        Provider(id: "groq", name: "Groq", powers: "Model", hasKey: true, hasEndpoint: false),
        Provider(id: "ollama", name: "Ollama", powers: "Model · local", hasKey: false, hasEndpoint: true),
        Provider(id: "lmstudio", name: "LM Studio", powers: "Model · local", hasKey: false, hasEndpoint: true),
        Provider(id: "custom", name: "OpenAI-compatible", powers: "Model", hasKey: true, hasEndpoint: true),
        Provider(id: "ondevice", name: "On-device (Apple)", powers: "Voice", hasKey: false, hasEndpoint: false)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Integrations").typoTitle()
            Text("Attaché files agent updates as voicemail in your Inbox. Go live on a session when you want it narrated in real time.")
                .typoLabel()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Connect a provider to unlock it in Model and Voice. Click a row to add its key or endpoint, then Save & Test.")
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
            Text("After you enable send-to-agent for a session, explicit Tell Agent turns and personality handoffs from Ask Attaché send directly. The first-use enable prompt, frozen target, and safety filter still apply.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    private func row(_ provider: Provider) -> some View {
        let isExpanded = expanded == provider.id
        let expandable = provider.hasKey || provider.hasEndpoint
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
                HStack(spacing: 8) {
                    let shown = showKey[provider.id] ?? false
                    Group {
                        if shown {
                            TextField("API key", text: keyBinding(provider.id))
                        } else {
                            SecureField("API key", text: keyBinding(provider.id))
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    Button { showKey[provider.id] = !shown } label: {
                        Image(systemName: shown ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                statusText(model.healthStatus(provider.id))
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
        case "groq": model.saveGroqIntegration()
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
        case "groq": return $model.groqAPIKey
        case "custom": return $model.customAPIKey
        default: return .constant("")
        }
    }

    private func endpointBinding(_ id: String) -> Binding<String> {
        switch id {
        case "ollama": return $model.ollamaBaseURL
        case "lmstudio": return $model.lmStudioBaseURL
        case "custom": return $model.customBaseURL
        default: return .constant("")
        }
    }
}
