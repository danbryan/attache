import AttacheCore
import SwiftUI

private enum ContextStrategyChoice: String, CaseIterable, Identifiable {
    case inherit
    case automatic
    case maximumCoverage
    case efficient
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inherit: return "Use app default"
        case .automatic: return "Automatic"
        case .maximumCoverage: return "Maximum coverage"
        case .efficient: return "Efficient"
        case .custom: return "Custom"
        }
    }

    var kind: AttacheContextStrategyKind? {
        switch self {
        case .inherit: return nil
        case .automatic: return .automatic
        case .maximumCoverage: return .maximumCoverage
        case .efficient: return .efficient
        case .custom: return .custom
        }
    }
}

/// Compact strategy editor shared by the global Context pane and each
/// character. Numeric controls stay behind Advanced and appear only for Custom.
struct ContextStrategyEditor: View {
    @Binding var strategyOverride: AttacheContextStrategy?
    var globalStrategy: AttacheContextStrategy
    var allowsInheritance: Bool
    var capabilitySummary: AttacheCapabilitySummary
    var modelLabel: String
    /// A concrete discovery problem, such as a saved Ollama tag that is no
    /// longer installed. This is deliberately distinct from unknown provider
    /// capability metadata.
    var capabilityNotice: String? = nil
    var migrationNotice: String?
    var onDismissMigrationNotice: (() -> Void)?
    var onRefreshCapabilities: (() -> Void)?

    @State private var advancedExpanded = false

    private var effectiveStrategy: AttacheContextStrategy {
        strategyOverride ?? globalStrategy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let migrationNotice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(migrationNotice)
                        .typoCaption()
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let onDismissMigrationNotice {
                        Button("Dismiss", action: onDismissMigrationNotice)
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Dismiss context profile migration notice")
                    }
                }
                .padding(9)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            Picker("Strategy", selection: choiceBinding) {
                if allowsInheritance {
                    Text("Use app default · \(AttacheContextStrategyDescription.title(globalStrategy.kind))")
                        .tag(ContextStrategyChoice.inherit)
                    Divider()
                }
                ForEach(ContextStrategyChoice.allCases.filter { $0 != .inherit }) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .accessibilityLabel(allowsInheritance ? "Character context strategy" : "Default context strategy")

            Text(AttacheContextStrategyDescription.explanation(effectiveStrategy.kind))
                .typoCaption()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup(isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    strategyBehaviorPanel
                    if effectiveStrategy.kind == .custom {
                        customControls
                    }
                    capabilityPanel
                }
                .padding(.top, 9)
            } label: {
                Text("Advanced")
                    .typoLabel(.medium)
            }
            .accessibilityLabel("Advanced context settings")
            .onChange(of: effectiveStrategy.kind) { kind in
                if kind == .custom { advancedExpanded = true }
            }
        }
    }

    private var strategyBehaviorPanel: some View {
        let behavior = AttacheContextStrategyDescription.behavior(effectiveStrategy)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(Color.accentColor)
                Text("\(AttacheContextStrategyDescription.title(effectiveStrategy.kind)) plan")
                    .typoLabel(.semibold)
                    .accessibilityLabel("\(AttacheContextStrategyDescription.title(effectiveStrategy.kind)) context strategy plan")
            }
            strategyBehaviorRow("Evidence", behavior.evidenceAllowance)
            strategyBehaviorRow("Conversation", behavior.conversationContinuity)
            strategyBehaviorRow("Memory", behavior.durableMemory)
            strategyBehaviorRow("Tool retrieval", behavior.toolRetrieval)
            strategyBehaviorRow("Session review", behavior.wholeSessionReview)
            Text("These allowances matter only when relevant, authorized context exists.")
                .typoCaption()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(AttacheContextStrategyDescription.title(effectiveStrategy.kind)) context strategy plan")
    }

    private func strategyBehaviorRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .typoCaption(.medium)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .typoCaption()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var choiceBinding: Binding<ContextStrategyChoice> {
        Binding(
            get: {
                guard let strategyOverride else { return .inherit }
                switch strategyOverride.kind {
                case .automatic: return .automatic
                case .maximumCoverage: return .maximumCoverage
                case .efficient: return .efficient
                case .custom: return .custom
                }
            },
            set: { choice in
                guard let kind = choice.kind else {
                    strategyOverride = nil
                    return
                }
                if kind == .custom {
                    let existing = strategyOverride?.custom ?? AttacheContextCustomPolicy()
                    strategyOverride = AttacheContextStrategy(.custom, custom: existing)
                } else {
                    strategyOverride = AttacheContextStrategy(kind)
                }
            }
        )
    }

    private var capabilityPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model evidence")
                        .typoLabel(.semibold)
                        .accessibilityLabel("Context capability summary for \(modelLabel)")
                    Text("Independent of strategy")
                        .typoCaption()
                        .foregroundStyle(.secondary)
                    Text(modelLabel).typoCaption().foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let onRefreshCapabilities {
                    Button(action: onRefreshCapabilities) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Refresh model context capabilities")
                }
            }
            capabilityRow("Input capacity", capabilitySummary.effectiveCapacityLabel)
            capabilityRow("Reasoning", capabilitySummary.reasoningSupportLabel)
            capabilityRow("Source", capabilitySummary.sourceLabel)
            capabilityRow("Last confirmed", capabilitySummary.freshnessLabel)
            if capabilitySummary.isUnknown {
                VStack(alignment: .leading, spacing: 5) {
                    Text(unknownCapacityExplanation)
                        .typoCaption()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if effectiveStrategy.kind != .custom {
                        Button("Set a Custom cap", action: openCustomLimits)
                            .buttonStyle(.link)
                            .accessibilityLabel("Set Custom context limits")
                            .accessibilityHint("Changes the strategy to Custom and opens the input-limit controls")
                    }
                }
            } else if capabilitySummary.isStale {
                Label("This capability evidence is stale. Refresh before relying on its ceiling.", systemImage: "clock.badge.exclamationmark")
                    .typoCaption()
                    .foregroundStyle(.orange)
            }
            if capabilitySummary.isOverridden {
                Label("Your Custom limits are active. Detected model facts remain unchanged.", systemImage: "slider.horizontal.3")
                    .typoCaption()
                    .foregroundStyle(.secondary)
            }
            if let capabilityNotice {
                Label(capabilityNotice, systemImage: "exclamationmark.triangle")
                    .typoCaption()
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Context capability summary for \(modelLabel)")
    }

    private var unknownCapacityExplanation: String {
        if effectiveStrategy.kind == .custom {
            let limits = [
                effectiveStrategy.custom?.hardInputLimit,
                effectiveStrategy.custom?.effectiveInputLimit
            ].compactMap { $0 }
            if let cap = limits.min() {
                return "Capacity is not reported. Custom plans within your \(cap.formatted())-token input cap, staged retrieval, and tool budgets. The detected model fact remains Unknown."
            }
            return "Capacity is not reported. Custom has no input cap, so Attaché uses a bounded 16,384-token working envelope with your reserves. The detected model fact remains Unknown."
        }
        return "Capacity is not reported. \(AttacheContextStrategyDescription.title(effectiveStrategy.kind)) plans within a bounded 16,384-token working envelope using the allowances above. Attaché never treats that envelope as a provider fact."
    }

    private func capabilityRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).typoCaption().foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).typoCaption(.medium).multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder private var customControls: some View {
        if let custom = effectiveStrategy.custom {
            VStack(alignment: .leading, spacing: 9) {
                Text("Custom limits").typoLabel(.semibold)
                optionalTokenField(
                    title: "Hard input limit",
                    value: custom.hardInputLimit,
                    accessibilityLabel: "Custom hard input token limit"
                ) { value in
                    updateCustom { $0.hardInputLimit = value }
                }
                optionalTokenField(
                    title: "Working input limit",
                    value: custom.effectiveInputLimit,
                    accessibilityLabel: "Custom effective input token limit"
                ) { value in
                    updateCustom { $0.effectiveInputLimit = value }
                }
                tokenStepper("Output reserve", value: custom.outputReserve, range: 256...262_144) { value in
                    updateCustom { $0.outputReserve = value }
                }
                tokenStepper("Tool reserve", value: custom.toolReserve, range: 256...262_144) { value in
                    updateCustom { $0.toolReserve = value }
                }
                tokenStepper("Safety margin", value: custom.safetyMargin, range: 64...65_536) { value in
                    updateCustom { $0.safetyMargin = value }
                }

                if let error = customValidationError(custom) {
                    Label(friendlyValidationMessage(error), systemImage: "exclamationmark.triangle.fill")
                        .typoCaption()
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Invalid Custom context limits: \(friendlyValidationMessage(error))")
                } else {
                    Label("These limits are valid.", systemImage: "checkmark.circle.fill")
                        .typoCaption()
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private func optionalTokenField(
        title: String,
        value: Int?,
        accessibilityLabel: String,
        update: @escaping (Int?) -> Void
    ) -> some View {
        HStack {
            Text(title).typoCaption()
            Spacer()
            TextField("Detected", text: Binding(
                get: { value.map(String.init) ?? "" },
                set: { raw in
                    let cleaned = raw.filter(\.isNumber)
                    update(cleaned.isEmpty ? nil : Int(cleaned))
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 112)
            .multilineTextAlignment(.trailing)
            .accessibilityLabel(accessibilityLabel)
            Text("tokens").typoCaption().foregroundStyle(.secondary)
        }
    }

    private func tokenStepper(
        _ title: String,
        value: Int,
        range: ClosedRange<Int>,
        update: @escaping (Int) -> Void
    ) -> some View {
        Stepper(value: Binding(get: { value }, set: update), in: range, step: 256) {
            HStack {
                Text(title).typoCaption()
                Spacer()
                Text("\(value) tokens").typoCaption(.medium, monoDigit: true)
            }
        }
        .accessibilityLabel("Custom \(title.lowercased())")
        .accessibilityValue("\(value) tokens")
    }

    private func updateCustom(_ update: (inout AttacheContextCustomPolicy) -> Void) {
        var policy = effectiveStrategy.custom ?? AttacheContextCustomPolicy()
        update(&policy)
        strategyOverride = AttacheContextStrategy(.custom, custom: policy)
    }

    private func openCustomLimits() {
        let existing = effectiveStrategy.custom ?? AttacheContextCustomPolicy()
        strategyOverride = AttacheContextStrategy(.custom, custom: existing)
        advancedExpanded = true
    }

    private func customValidationError(_ policy: AttacheContextCustomPolicy) -> Error? {
        do {
            try policy.validate()
            return nil
        } catch {
            return error
        }
    }

    private func friendlyValidationMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription?
            .replacingOccurrences(of: "hardInputLimit", with: "hard input limit")
            .replacingOccurrences(of: "effectiveInputLimit", with: "working input limit")
            .replacingOccurrences(of: "outputReserve", with: "output reserve")
            .replacingOccurrences(of: "toolReserve", with: "tool reserve")
            .replacingOccurrences(of: "safetyMargin", with: "safety margin")
            ?? error.localizedDescription
    }
}

struct ContextSettingsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: AttacheContextUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Context").typoTitle()
            Text("Choose how Attaché balances evidence, speed, and the limits of your active character's model.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ContextStrategyEditor(
                strategyOverride: globalBinding,
                globalStrategy: state.globalStrategy,
                allowsInheritance: false,
                capabilitySummary: activeCapabilitySummary,
                modelLabel: model.presentationProviderSummary,
                capabilityNotice: activeCapabilityNotice,
                migrationNotice: state.strategyMigrationNotice,
                onDismissMigrationNotice: state.dismissStrategyMigrationNotice
            )
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

            Label("A character can inherit this default or choose its own strategy in the character editor.", systemImage: "person.crop.circle.badge.checkmark")
                .typoCaption()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    private var globalBinding: Binding<AttacheContextStrategy?> {
        Binding(
            get: { state.globalStrategy },
            set: { if let strategy = $0 { state.setGlobalStrategy(strategy) } }
        )
    }

    private var activeCapabilitySummary: AttacheCapabilitySummary {
        let profile = model.presentationModelOptions
            .first(where: { $0.id == model.presentationModel })?
            .capabilityProfile
            ?? AttachePresentationModelService.capabilityProfile(
                provider: model.presentationProvider,
                baseURLText: model.presentationBaseURL,
                modelID: model.presentationModel
            )
        return .from(detected: profile, override: state.globalStrategy.custom)
    }

    private var activeCapabilityNotice: String? {
        guard model.presentationProvider == .ollama,
              !model.presentationModelOptions.isEmpty,
              !model.presentationModelOptions.contains(where: { $0.id == model.presentationModel }) else {
            return nil
        }
        return "\(model.presentationModel) is not installed on this Ollama server. Choose a listed model or install it, then refresh to inspect its capacity and reasoning support."
    }
}

extension AttacheContextStrategy {
    var isValidForSaving: Bool {
        guard kind == .custom else { return true }
        guard let custom else { return false }
        return (try? custom.validate()) != nil
    }
}
