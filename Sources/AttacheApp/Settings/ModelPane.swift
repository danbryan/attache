import SwiftUI

/// The presentation LLM: Attaché's text brain. Selection-only; provider
/// credentials live in Integrations.
struct ModelPane: View {
    @ObservedObject var model: AppModel
    @State private var pendingCloudProvider: CompanionPresentationProvider?

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
        }
        .sheet(item: $pendingCloudProvider) { provider in
            CloudConsentSheet(
                providerName: provider.title,
                produces: "summaries",
                sends: "your agent's output, session transcripts, and files it reads from your project",
                onEnable: {
                    model.cloudConsentPresentationAcknowledged = true
                    model.selectPresentationProvider(provider)
                    pendingCloudProvider = nil
                },
                onCancel: { pendingCloudProvider = nil }
            )
        }
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
                   !model.cloudConsentPresentationAcknowledged {
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
