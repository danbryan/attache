import AttacheCore
import SwiftUI

@MainActor
struct ContextOverflowRecoveryBanner: View {
    @ObservedObject var state: AttacheContextUIState

    init() {
        self.state = .shared
    }

    init(state: AttacheContextUIState) {
        self.state = state
    }

    @ViewBuilder var body: some View {
        if let recovery = state.overflowRecovery {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("This model ran out of context space").typoCaption(.semibold)
                        Text("Your message is preserved. Choose how Attaché should rebuild the context, then retry explicitly.")
                            .typoCaption()
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button {
                        state.dismissOverflowRecovery()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss context overflow recovery")
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { retryButtons(recovery) }
                    VStack(alignment: .leading, spacing: 7) { retryButtons(recovery) }
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.25)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Context limit reached. Your message is preserved and has not been retried.")
        }
    }

    @ViewBuilder private func retryButtons(_ recovery: AttacheOverflowRecovery) -> some View {
        if recovery.suggestedStrategies.contains(.automatic) {
            Button("Retry with Automatic") { state.retryOverflow(using: .automatic) }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Retry preserved message with Automatic context")
        }
        if recovery.suggestedStrategies.contains(.efficient) {
            Button("Retry with Efficient") { state.retryOverflow(using: .efficient) }
                .accessibilityLabel("Retry preserved message with Efficient context")
        }
    }
}

@MainActor
struct ExhaustiveReviewSurface: View {
    @ObservedObject var state: AttacheContextUIState

    init() {
        self.state = .shared
    }

    init(state: AttacheContextUIState) {
        self.state = state
    }

    @ViewBuilder var body: some View {
        if let review = state.exhaustiveReview {
            VStack(alignment: .leading, spacing: 9) {
                header(review)

                switch review.phase {
                case .preview:
                    preview(review)
                case .running:
                    progress(review)
                case .complete:
                    result(review, message: "Exhaustive review complete", symbol: "checkmark.circle.fill", color: .green)
                case .incomplete:
                    result(review, message: "Review stopped before full coverage", symbol: "exclamationmark.triangle.fill", color: .orange)
                case .canceled:
                    result(review, message: "Review canceled", symbol: "pause.circle.fill", color: .secondary)
                case .stale:
                    result(review, message: "The source session changed", symbol: "clock.badge.exclamationmark.fill", color: .orange)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.10)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Exhaustive review for \(review.sessionTitle), \(phaseLabel(review.phase))")
        }
    }

    private func header(_ review: AttacheExhaustiveReviewUIState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "rectangle.stack.badge.play")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Exhaustive review").typoCaption(.semibold)
                Text(review.sessionTitle).typoCaption().foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if review.phase != .running {
                Button {
                    state.dismissExhaustiveReview()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss exhaustive review")
            }
        }
    }

    private func preview(_ review: AttacheExhaustiveReviewUIState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attaché will inspect the session in bounded stages and report coverage honestly. This may make about \(review.estimatedCalls) model calls.")
                .typoCaption()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            metadata(review)
            HStack(spacing: 8) {
                Button("Start review") { state.startExhaustiveReview() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Start exhaustive review")
                Button("Not now") { state.dismissExhaustiveReview() }
            }
        }
    }

    private func progress(_ review: AttacheExhaustiveReviewUIState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: review.progress) {
                Text("Coverage").typoCaption(.semibold)
            } currentValueLabel: {
                Text("\(review.coveredRanges) of \(review.eligibleRanges) ranges")
                    .typoCaption(.medium, monoDigit: true)
            }
            .accessibilityLabel("Exhaustive review coverage")
            .accessibilityValue("\(review.coveredRanges) of \(review.eligibleRanges) ranges, \(review.completedCalls) model calls made")

            HStack {
                Text("\(review.completedCalls) model calls made")
                    .typoCaption()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { state.cancelExhaustiveReview() }
                    .accessibilityLabel("Cancel exhaustive review")
            }
        }
    }

    private func result(
        _ review: AttacheExhaustiveReviewUIState,
        message: String,
        symbol: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: symbol)
                .typoCaption(.semibold)
                .foregroundStyle(color)
            Text("Covered \(review.coveredRanges) of \(review.eligibleRanges) eligible ranges. \(review.omittedRanges) ranges were omitted.")
                .typoCaption()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if review.phase != .complete {
                Button(review.phase == .stale ? "Restart with current session" : "Resume review") {
                    state.resumeExhaustiveReview()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(review.phase == .stale ? "Restart exhaustive review with current session" : "Resume exhaustive review")
            }
        }
    }

    private func metadata(_ review: AttacheExhaustiveReviewUIState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            compactRow("Model", review.modelLabel)
            compactRow("Strategy", review.strategyLabel)
            compactRow("Data route", review.egressLabel)
            compactRow("Session size", reviewSize(review))
            compactRow("Eligible ranges", "\(review.eligibleRanges)")
        }
        .padding(8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func reviewSize(_ review: AttacheExhaustiveReviewUIState) -> String {
        let bytes = ByteCountFormatter.string(
            fromByteCount: Int64(review.estimatedSourceBytes),
            countStyle: .file
        )
        let tokens = review.estimatedInputTokens.formatted()
        return "\(bytes) · ~\(tokens) tokens"
    }

    private func compactRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).typoCaption().foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).typoCaption(.medium).multilineTextAlignment(.trailing)
        }
    }

    private func phaseLabel(_ phase: AttacheExhaustiveReviewUIState.Phase) -> String {
        switch phase {
        case .preview: return "ready to start"
        case .running: return "running"
        case .complete: return "complete"
        case .incomplete: return "incomplete"
        case .canceled: return "canceled"
        case .stale: return "source changed"
        }
    }
}
