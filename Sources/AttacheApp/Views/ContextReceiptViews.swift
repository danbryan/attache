import AppKit
import AttacheCore
import SwiftUI

enum ContextReceiptDisclosureStyle {
    case full
    case compact
}

/// A content-free disclosure tied to the exact response id. Rendering nothing
/// when no receipt has been published avoids falsely claiming that no model was
/// involved while an older pipeline is still being upgraded.
@MainActor
struct ContextReceiptDisclosure: View {
    let responseID: String
    var style: ContextReceiptDisclosureStyle = .full

    @ObservedObject private var state: AttacheContextUIState
    @State private var expanded = false
    @State private var popoverPresented = false
    @State private var copied = false

    init(
        responseID: String,
        style: ContextReceiptDisclosureStyle = .full
    ) {
        self.responseID = responseID
        self.style = style
        self.state = .shared
    }

    init(
        responseID: String,
        style: ContextReceiptDisclosureStyle = .full,
        state: AttacheContextUIState
    ) {
        self.responseID = responseID
        self.style = style
        self.state = state
    }

    @ViewBuilder var body: some View {
        if let receipt = state.receipt(for: responseID) {
            switch style {
            case .full:
                DisclosureGroup(isExpanded: $expanded) {
                    receiptBody(receipt)
                        .padding(.top, 8)
                } label: {
                    Label(receiptLabel(receipt), systemImage: "doc.text.magnifyingglass")
                        .typoCaption(.semibold)
                }
                .accessibilityLabel("Context receipt for this response")
                .accessibilityValue(receiptLabel(receipt))
            case .compact:
                Button {
                    popoverPresented.toggle()
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .typoIcon(size: 11, .semibold)
                }
                .buttonStyle(.borderless)
                .help("Context receipt")
                .accessibilityLabel("Show context receipt")
                .popover(isPresented: $popoverPresented, arrowEdge: .trailing) {
                    ScrollView {
                        receiptBody(receipt)
                            .padding(14)
                            .frame(width: 380, alignment: .leading)
                    }
                    .frame(maxHeight: 480)
                }
            }
        }
    }

    private func receiptBody(_ receipt: AttacheContextReceiptView) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            if receipt.noModelContext {
                Label("No model context was sent for this response.", systemImage: "lock.shield")
                    .typoCaption()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if receipt.usedFallback {
                    Label(
                        "A fallback model answered. Attaché recompiled the context for that model instead of reusing the first request.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .typoCaption()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(Array(receipt.attempts.enumerated()), id: \.offset) { _, attempt in
                    attemptView(attempt)
                }
            }

            HStack {
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        AttacheContextReceiptSerializer.serialize(receipt),
                        forType: .string
                    )
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy redacted diagnostic", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? "Context diagnostic copied" : "Copy redacted context diagnostic")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Context receipt details")
    }

    private func attemptView(_ attempt: AttacheReceiptAttemptSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(attempt.isFallback ? "Fallback attempt \(attempt.attemptNumber)" : "Model attempt \(attempt.attemptNumber)")
                    .typoLabel(.semibold)
                Spacer()
                if attempt.recompiledForFallback {
                    Text("Recompiled")
                        .typoCaption(.semibold)
                        .foregroundStyle(.secondary)
                }
            }

            receiptRow("Model", "\(attempt.modelSummary.provider) · \(attempt.modelSummary.model)")
            receiptRow("Strategy", strategyDisplayName(attempt.modelSummary.strategyKind))
            if let reasoning = attempt.modelSummary.reasoningLevel, !reasoning.isEmpty {
                receiptRow("Reasoning", reasoning.capitalized)
            }

            let budget = attempt.modelSummary.effectiveBudget.map { "\($0) token budget" } ?? "budget unknown"
            receiptRow("Input", "About \(attempt.totalEstimatedTokens) tokens · \(budget)")

            if let output = attempt.modelSummary.outputReserve {
                receiptRow("Output reserve", "\(output) tokens")
            }
            if let tools = attempt.modelSummary.toolReserve {
                receiptRow("Tool reserve", "\(tools) tokens")
            }
            receiptRow("Capability source", capabilitySourceName(attempt.modelSummary.capabilityProvenance))
            if let freshness = attempt.modelSummary.capabilityFreshness, !freshness.isEmpty {
                receiptRow("Capability checked", freshness)
            }

            if let focused = attempt.focusedSessionDisplay {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Authorized work session").typoCaption(.semibold)
                    Text("\(focused.displayTitle) · \(focused.sourceKind)")
                        .typoCaption()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if attempt.stagedProcessingRequired {
                Label(
                    "Some material needs staged review. This response is not marked as fully covered.",
                    systemImage: "square.stack.3d.up"
                )
                .typoCaption()
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !attempt.sourceSummaries.isEmpty {
                Divider()
                Text("Evidence categories").typoCaption(.semibold)
                ForEach(Array(attempt.sourceSummaries.enumerated()), id: \.offset) { _, source in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: sourceSymbol(source.disposition))
                            .foregroundStyle(sourceColor(source.disposition))
                            .frame(width: 13)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(sourceName(source.source)) · \(source.count) \(dispositionName(source.disposition))")
                                .typoCaption(.medium)
                            if let reason = source.omissionReason, !reason.isEmpty {
                                Text("Why: \(reason)")
                                    .typoCaption()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }

    private func receiptRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).typoCaption().foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).typoCaption(.medium).multilineTextAlignment(.trailing)
        }
    }

    private func receiptLabel(_ receipt: AttacheContextReceiptView) -> String {
        if receipt.noModelContext { return "Context · no model context sent" }
        if receipt.usedFallback { return "Context · fallback recompiled" }
        guard let primary = receipt.primaryAttempt else { return "Context receipt" }
        return "Context · \(strategyDisplayName(primary.modelSummary.strategyKind)) · about \(primary.totalEstimatedTokens) tokens"
    }

    private func strategyDisplayName(_ raw: String) -> String {
        guard let kind = AttacheContextStrategyKind(rawValue: raw) else { return raw }
        return AttacheContextStrategyDescription.title(kind)
    }

    private func capabilitySourceName(_ raw: String) -> String {
        switch AttacheCapabilityProvenance(rawValue: raw) {
        case .runtimeObservation: return "Runtime observation"
        case .providerMetadata: return "Provider metadata"
        case .localCache: return "Local cache"
        case .explicitUserOverride: return "Your override"
        case .curatedFallback: return "Built-in fallback"
        case .unknown, .none: return "Unknown"
        }
    }

    private func sourceName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "focusedSession", with: "focused session")
            .capitalized
    }

    private func dispositionName(_ disposition: AttacheReceiptSourceDisposition) -> String {
        switch disposition {
        case .included: return "included"
        case .omitted: return "omitted"
        case .truncated: return "trimmed"
        case .staged: return "staged"
        }
    }

    private func sourceSymbol(_ disposition: AttacheReceiptSourceDisposition) -> String {
        switch disposition {
        case .included: return "checkmark.circle.fill"
        case .omitted: return "minus.circle"
        case .truncated: return "scissors"
        case .staged: return "square.stack.3d.up"
        }
    }

    private func sourceColor(_ disposition: AttacheReceiptSourceDisposition) -> Color {
        switch disposition {
        case .included: return .green
        case .omitted: return .secondary
        case .truncated, .staged: return .orange
        }
    }
}
