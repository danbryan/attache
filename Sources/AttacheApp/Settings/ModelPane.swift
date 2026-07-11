import SwiftUI

/// The presentation LLM: Attaché's text brain. Selection-only; provider
/// credentials live in Integrations.
struct ModelPane: View {
    @ObservedObject var model: AppModel
    @State private var pendingCloudProvider: CompanionPresentationProvider?
    /// Set alongside `pendingCloudProvider` when the pending consent sheet was
    /// opened from a per-role row rather than the main Provider picker, so the
    /// sheet's `onEnable` applies the choice to the right target (INF-253/D3).
    @State private var pendingCloudProviderRole: ModelRole?
    @State private var advancedModelSectionExpanded = false

    private var isConnected: Bool {
        model.presentationLLMEnabled && model.presentationStatus.hasPrefix("Presentation LLM:")
    }

    private var providerOptions: [CompanionPresentationProvider] {
        var list = model.connectedTextProviders
        if !list.contains(model.presentationProvider) {
            list.insert(model.presentationProvider, at: 0)
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Model").typoTitle()
            Text("Choose the local or cloud model Attaché uses when personality summaries are enabled.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            statusHeader

            VStack(alignment: .leading, spacing: 12) {
                settingRow("Provider") {
                    Picker("", selection: providerBinding) {
                        ForEach(providerOptions) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .accessibilityLabel("Main model provider")
                }
                dataResidencyCaption
                settingRow("Model") {
                    modelControl
                    Button { model.loadPresentationModels() } label: {
                        Label("Load", systemImage: "arrow.clockwise")
                    }
                }
                if !model.presentationModelDiscoveryStatus.isEmpty {
                    Text(model.presentationModelDiscoveryStatus)
                        .font(.caption).foregroundStyle(.secondary).padding(.leading, 146)
                }
                if !reasoningOptions.isEmpty {
                    settingRow(model.presentationProvider == .claudeCLI ? "Effort" : "Reasoning") {
                        Picker("", selection: $model.presentationReasoningEffort) {
                            ForEach(reasoningOptions, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 380)
                    }
                }
                if !serviceTierOptions.isEmpty {
                    settingRow("Speed") {
                        Picker("", selection: $model.presentationServiceTier) {
                            ForEach(serviceTierOptions) { option in
                                Text(speedLabel(option)).tag(option.id)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 380)
                    }
                }
            }
            .disabled(!model.presentationLLMEnabled)

            Label("Personality summaries can be turned on or off in Personalities. Add or change provider keys and endpoints in Integrations.", systemImage: "link")
                .font(.caption).foregroundStyle(.secondary)

            fallbackChainSection
                .disabled(!model.presentationLLMEnabled)

            advancedPerRoleSection
                .disabled(!model.presentationLLMEnabled)
        }
        .sheet(item: $pendingCloudProvider) { provider in
            CloudConsentSheet(
                providerName: provider.title,
                produces: "summaries",
                sends: "your agent's output, session transcripts, and files it reads from your project",
                onEnable: {
                    model.acknowledgeCloudConsent(for: provider)
                    if let role = pendingCloudProviderRole {
                        model.selectRoleProvider(provider, for: role)
                    } else {
                        model.selectPresentationProvider(provider)
                    }
                    pendingCloudProvider = nil
                    pendingCloudProviderRole = nil
                },
                onCancel: {
                    pendingCloudProvider = nil
                    pendingCloudProviderRole = nil
                }
            )
        }
    }

    // MARK: Opt-in auto-fallback chain (INF-258/D5), conversation role only
    //
    // Lives next to the main Provider/Model row above, since that row is what
    // the conversation role actually uses when it has no per-role override
    // (see the Advanced section's "Use main model" default). Adding a
    // provider here does not itself need consent or credentials up front:
    // each candidate is only checked for configuration and consent at the
    // moment a fallback would actually trigger, and an unconfigured or
    // unconsented entry is simply skipped in favor of the next one.

    private var fallbackChainSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Automatically fall back when the model is unavailable", isOn: $model.conversationFallbackChainEnabled)
                .toggleStyle(.switch)
            Text("When the live call's model hits a usage limit, an outage, or becomes unavailable, Attaché tries the next provider below, in order, skipping any that aren't configured or consented. It announces the switch once and keeps using it for the rest of the call; the next call starts back on the main model above.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if model.conversationFallbackChainEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.conversationFallbackChain.enumerated()), id: \.element) { index, provider in
                        HStack(spacing: 8) {
                            Text("\(index + 1). \(provider.title)")
                                .typoBody()
                            Spacer(minLength: 8)
                            Button {
                                model.moveConversationFallbackChainProvider(at: index, up: true)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.plain)
                            .disabled(index == 0)
                            .accessibilityLabel("Move \(provider.title) earlier in the fallback order")

                            Button {
                                model.moveConversationFallbackChainProvider(at: index, up: false)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.plain)
                            .disabled(index == model.conversationFallbackChain.count - 1)
                            .accessibilityLabel("Move \(provider.title) later in the fallback order")

                            Button {
                                model.removeConversationFallbackChainProvider(provider)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Remove \(provider.title) from the fallback order")
                        }
                    }
                    if model.conversationFallbackChain.isEmpty {
                        Text("No fallback providers yet. Add one below.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !fallbackChainAddableProviders.isEmpty {
                        Menu {
                            ForEach(fallbackChainAddableProviders) { provider in
                                Button(provider.title) { model.addConversationFallbackChainProvider(provider) }
                            }
                        } label: {
                            Label("Add fallback provider", systemImage: "plus.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Add fallback provider")
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var fallbackChainAddableProviders: [CompanionPresentationProvider] {
        CompanionPresentationProvider.allCases.filter { !model.conversationFallbackChain.contains($0) }
    }

    // MARK: Advanced: per-task models (INF-253/D3)

    private var advancedPerRoleSection: some View {
        DisclosureGroup("Advanced: per-task models", isExpanded: $advancedModelSectionExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Give conversation, presentation, recap, or tagging its own provider and model instead of the main model above. Each starts on \"Use main model\" until you change it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(ModelRole.allCases, id: \.self) { role in
                    roleRow(role)
                    if role != ModelRole.allCases.last {
                        Divider()
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private func roleRow(_ role: ModelRole) -> some View {
        let provider = model.roleModelProvider[role]
        return VStack(alignment: .leading, spacing: 10) {
            Text(role.displayName).typoBody(.medium)
            Text(role.paneCaption)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            settingRow("Provider") {
                Picker("", selection: roleProviderBinding(role)) {
                    Text("Use main model").tag(CompanionPresentationProvider?.none)
                    ForEach(CompanionPresentationProvider.allCases) { option in
                        Text(option.title).tag(CompanionPresentationProvider?.some(option))
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                .accessibilityLabel("\(role.displayName) provider")
            }
            if let provider {
                settingRow("Model") {
                    roleModelControl(role, provider: provider)
                    Button { model.loadRoleModels(for: role) } label: {
                        Label("Load", systemImage: "arrow.clockwise")
                    }
                    .accessibilityLabel("Load \(role.displayName) models")
                }
                if let status = model.roleModelDiscoveryStatus[role], !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary).padding(.leading, 146)
                }
                if provider.requiresAPIKey, !model.connectedTextProviders.contains(provider) {
                    roleKeyRequiredNotice(for: provider)
                }
                let roleReasoningOptions = model.roleReasoningOptions(for: role)
                if !roleReasoningOptions.isEmpty {
                    settingRow(provider == .claudeCLI ? "Effort" : "Reasoning") {
                        Picker("", selection: roleReasoningBinding(role)) {
                            ForEach(roleReasoningOptions, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 380)
                        .accessibilityLabel("\(role.displayName) reasoning effort")
                    }
                }
                let roleServiceOptions = model.roleServiceTierOptions(for: role)
                if !roleServiceOptions.isEmpty {
                    settingRow("Speed") {
                        Picker("", selection: roleServiceTierBinding(role)) {
                            ForEach(roleServiceOptions) { option in
                                Text(speedLabel(option)).tag(option.id)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 380)
                        .accessibilityLabel("\(role.displayName) speed")
                    }
                }
            }
        }
    }

    @ViewBuilder private func roleModelControl(_ role: ModelRole, provider: CompanionPresentationProvider) -> some View {
        let options = model.roleModelOptions[role] ?? []
        if options.isEmpty {
            TextField("Model id", text: roleModelIDBinding(role))
                .textFieldStyle(.roundedBorder).frame(width: 240)
                .accessibilityLabel("\(role.displayName) model id")
        } else {
            Picker("", selection: roleModelIDBinding(role)) {
                ForEach(options) { Text($0.title).tag($0.id) }
            }
            .labelsHidden().frame(width: 280)
            .accessibilityLabel("\(role.displayName) model")
        }
    }

    /// Same wording and layout as the "needs a key" notice in VoicePane's
    /// `engineNeedsKey` block, reused here instead of inventing a second key
    /// required state (INF-253/D3 spec item 5).
    private func roleKeyRequiredNotice(for provider: CompanionPresentationProvider) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("\(provider.title) needs an")
            Button("API key") { model.focusIntegration(for: provider) }
                .buttonStyle(.link)
            Text("under Integrations, then Save & Test.")
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func roleProviderBinding(_ role: ModelRole) -> Binding<CompanionPresentationProvider?> {
        Binding(
            get: { model.roleModelProvider[role] },
            set: { newValue in
                guard let newValue else {
                    model.selectRoleProvider(nil, for: role)
                    return
                }
                if newValue != model.roleModelProvider[role],
                   model.presentationProviderSendsToCloud(newValue),
                   !model.cloudConsentAcknowledged(for: newValue) {
                    pendingCloudProviderRole = role
                    pendingCloudProvider = newValue
                } else {
                    model.selectRoleProvider(newValue, for: role)
                }
            }
        )
    }

    private func roleModelIDBinding(_ role: ModelRole) -> Binding<String> {
        Binding(
            get: { model.roleModelID[role] ?? "" },
            set: { id in
                if let option = (model.roleModelOptions[role] ?? []).first(where: { $0.id == id }) {
                    model.selectRoleModel(option, for: role)
                } else {
                    model.selectRoleModelID(id, for: role)
                }
            }
        )
    }

    private func roleReasoningBinding(_ role: ModelRole) -> Binding<String> {
        Binding(
            get: { model.roleReasoningEffort[role] ?? "default" },
            set: { model.setRoleReasoningEffort($0, for: role) }
        )
    }

    private func roleServiceTierBinding(_ role: ModelRole) -> Binding<String> {
        Binding(
            get: { model.roleServiceTier[role] ?? "default" },
            set: { model.setRoleServiceTier($0, for: role) }
        )
    }

    @ViewBuilder private var dataResidencyCaption: some View {
        if model.presentationProvider.isCLI {
            Label("Runs your \(model.presentationProvider.title) login locally; that tool talks to its own service.", systemImage: "person.crop.circle")
                .font(.caption).foregroundStyle(.secondary)
        } else if model.presentationSendsToCloud {
            Label("Cloud provider: agent output leaves this Mac.", systemImage: "cloud")
                .font(.caption).foregroundStyle(.orange)
        } else {
            Label("Local provider: nothing leaves this Mac.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusHeader: some View {
        let symbol: String
        let color: Color
        if !model.presentationLLMEnabled {
            symbol = "moon.zzz.fill"; color = .secondary
        } else if isConnected {
            symbol = "checkmark.circle.fill"; color = .green
        } else {
            symbol = "exclamationmark.triangle.fill"; color = .orange
        }
        return HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(isConnected ? "Connected · \(model.presentationProviderSummary)" : model.presentationStatus)
                .typoLabel(.medium)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var providerBinding: Binding<CompanionPresentationProvider> {
        Binding(
            get: { model.presentationProvider },
            set: { provider in
                // First selection of a cloud provider in this category asks first;
                // the picker reverts because we don't apply until Enable.
                if provider != model.presentationProvider,
                   model.presentationProviderSendsToCloud(provider),
                   !model.cloudConsentAcknowledged(for: provider) {
                    pendingCloudProvider = provider
                } else {
                    model.selectPresentationProvider(provider)
                }
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { model.presentationModel },
            set: { id in
                if let option = model.presentationModelOptions.first(where: { $0.id == id }) {
                    model.selectPresentationModel(option)
                } else {
                    model.selectPresentationModelID(id)
                }
            }
        )
    }

    private var reasoningOptions: [String] {
        let options = model.selectedPresentationReasoningOptions
        if options.isEmpty {
            // Stable levels even before a model is loaded.
            switch model.presentationProvider {
            case .codexCLI: return ["default", "low", "medium", "high", "xhigh"]
            case .claudeCLI: return ["default", "low", "medium", "high", "xhigh", "max"]
            default: return ["default", "none", "low", "medium", "high"]
            }
        }
        return options.contains("default") ? options : ["default"] + options
    }

    private var serviceTierOptions: [CompanionPresentationServiceTierOption] {
        model.selectedPresentationServiceTierOptions
    }

    private func speedLabel(_ option: CompanionPresentationServiceTierOption) -> String {
        if option.id == "priority", option.title.localizedCaseInsensitiveContains("fast") {
            return "Fast"
        }
        return option.title
    }

    @ViewBuilder private var modelControl: some View {
        if model.presentationModelOptions.isEmpty {
            TextField("Model id", text: modelBinding)
                .textFieldStyle(.roundedBorder).frame(width: 240)
        } else {
            Picker("", selection: modelBinding) {
                ForEach(model.presentationModelOptions) { Text($0.title).tag($0.id) }
            }
            .labelsHidden().frame(width: 280)
        }
    }

}

/// UI copy for the "Advanced: per-task models" rows (INF-253/D3). Kept here
/// rather than on `ModelRole` itself since it's presentation copy, not shared
/// plumbing.
private extension ModelRole {
    var displayName: String {
        switch self {
        case .conversation: return "Conversation"
        case .presentation: return "Presentation"
        case .recap: return "Recap"
        case .tagging: return "Tagging"
        }
    }

    var paneCaption: String {
        switch self {
        case .conversation: return "Answers you during live calls, both Ask Attaché and Tell Agent replies."
        case .presentation: return "Turns each agent update into the spoken narration you hear as it arrives."
        case .recap: return "Writes the spoken recap you hear when you open the inbox."
        case .tagging: return "Labels sessions with a background topic tag; never spoken aloud."
        }
    }
}
