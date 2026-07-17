import AttacheCore
import SwiftUI

/// The summarize-session cost-preview sheet (INF-372). Driven entirely by
/// `AppModel.sessionSummaryState`: it shows the local cost preview (session,
/// source, update count, model calls, and where the context goes) before any
/// model call, runs the staged review only on explicit Continue, then shows the
/// spoken result. A don't-record session plays without saving a card.
struct SessionSummarySheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.sessionSummaryState {
            case .none:
                progressBody(status: "Preparing preview…")
            case .loadingPreview:
                progressBody(status: "Preparing preview…")
            case .running(let status):
                progressBody(status: status)
            case .previewing(let preview):
                previewBody(preview)
            case .finished(let spokenText, let persisted, let incomplete):
                finishedBody(spokenText: spokenText, persisted: persisted, incomplete: incomplete)
            case .failed(let reason):
                failedBody(reason: reason)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: - Preview

    @ViewBuilder
    private func previewBody(_ preview: SessionSummaryPreview) -> some View {
        switch preview {
        case .failedClosed(let reason):
            failedBody(reason: reason)
        case .ready(let sessionTitle, let sourceKindDisplay, let episodeCount,
                    let stageCount, _, let egressClass, let persistsCard):
            header(title: sessionTitle, source: sourceKindDisplay)

            Text(costLine(episodeCount: episodeCount, stageCount: stageCount))
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent {
                Text(egressPhrase(egressClass))
                    .font(.callout.weight(.medium))
            } label: {
                Text("Where the context goes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if !persistsCard {
                Text("This session is set to not record, so the summary plays once and is not saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelSessionSummary() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("Summarize Cancel")
                Button("Continue") { model.confirmSessionSummary() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("Summarize Continue")
            }
        }
    }

    // MARK: - Progress (loading preview or running)

    @ViewBuilder
    private func progressBody(status: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(status)
                .font(.callout)
                .foregroundStyle(.primary)
        }
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { model.cancelSessionSummary() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("Summarize Cancel")
        }
    }

    // MARK: - Finished

    @ViewBuilder
    private func finishedBody(spokenText: String, persisted: Bool, incomplete: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Session summary")
                .font(.headline)
        }

        if incomplete {
            Text("Covers part of the session.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        if !persisted {
            Text("Played once and not saved (this session does not record).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        ScrollView {
            Text(spokenText)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 220)

        HStack {
            Spacer()
            Button("Done") { model.cancelSessionSummary() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("Summarize Done")
        }
    }

    // MARK: - Failed

    @ViewBuilder
    private func failedBody(reason: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Cannot summarize this session")
                .font(.headline)
        }
        Text(reason)
            .font(.callout)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("Close") { model.cancelSessionSummary() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("Summarize Cancel")
        }
    }

    // MARK: - Header + copy helpers

    @ViewBuilder
    private func header(title: String, source: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Summarize session")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .lineLimit(2)
            Text(source)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func costLine(episodeCount: Int, stageCount: Int) -> String {
        let updates = "\(episodeCount) update\(episodeCount == 1 ? "" : "s")"
        let calls = "\(stageCount) model call\(stageCount == 1 ? "" : "s")"
        return "Summarizing \(updates) across this session will take \(calls)."
    }

    /// Short, user-facing phrase for where the request's context travels.
    private func egressPhrase(_ egressClass: String) -> String {
        switch AttacheDataEgress(rawValue: egressClass) {
        case .onDevice: return "On-device"
        case .loopback: return "Local (this Mac)"
        case .localNetwork: return "Local network"
        case .configuredRemote, .subscriptionRemoteCLI, .unknownCustom: return "Cloud"
        case .disabled: return "No model configured"
        case .none: return egressClass
        }
    }
}
