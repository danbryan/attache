import AttacheCore
import SwiftUI

struct CardRow: View {
    var card: VoicemailCard
    var selected: Bool
    var playing: Bool
    @Environment(\.themeAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                Text(card.sessionTitle ?? "Update")
                    .typoLabel(.semibold)
                    .lineLimit(1)
                Spacer()
                Text(card.createdAt.formatted(date: .omitted, time: .shortened))
                    .typoCaption(.medium)
                    .foregroundStyle(.secondary)
            }

            Text(card.summary)
                .typoBody(.medium)
                .lineLimit(3)

            if let projectPath = card.projectPath {
                Text(URL(fileURLWithPath: projectPath).lastPathComponent)
                    .typoCaption(design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(selected ? Color.primary.opacity(0.16) : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.primary.opacity(0.26) : Color.primary.opacity(0.08))
        )
    }

    private var indicatorColor: Color {
        if playing { return .yellow }
        switch card.status {
        case .unread: return accent
        case .heard: return .primary.opacity(0.38)
        case .archived: return .gray
        case .failed: return .red
        }
    }
}

struct StatusPill: View {
    var status: CardStatus
    @Environment(\.themeAccent) private var accent

    var body: some View {
        Label(status.rawValue.capitalized, systemImage: icon)
            .typoLabel(.semibold)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.22), in: Capsule())
            .foregroundStyle(color)
    }

    private var icon: String {
        switch status {
        case .unread: return "circle.fill"
        case .heard: return "checkmark.circle.fill"
        case .archived: return "archivebox.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .unread: return accent
        case .heard: return .primary.opacity(0.72)
        case .archived: return .gray
        case .failed: return .red
        }
    }
}

/// The plain-readback fallback badge (INF-254): a short category-derived
/// notice ("Spoken plainly · rate limited"), tappable to reveal the full
/// underlying error text, with the same text also reachable on hover and via
/// an accessibility label. `.id(card.id)` at the call site resets
/// `isExpanded` when the selected card changes, so a stale expansion never
/// bleeds from one card's error onto another's.
struct PresentationFallbackBadge: View {
    var notice: String
    var fullText: String?
    @State private var isExpanded = false

    var body: some View {
        let trimmedFullText = fullText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFullText = !(trimmedFullText ?? "").isEmpty
        Button {
            isExpanded.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .typoCaption(.medium)
                    .foregroundStyle(.yellow.opacity(0.92))
                    .lineLimit(3)
                if isExpanded, hasFullText {
                    Text(trimmedFullText ?? "")
                        .typoCaption(design: .monospaced)
                        .foregroundStyle(.yellow.opacity(0.72))
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(!hasFullText)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.yellow.opacity(0.18))
        )
        .help(hasFullText ? trimmedFullText ?? "" : notice)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasFullText ? "\(notice). Full error: \(trimmedFullText ?? "")" : notice)
        .accessibilityAddTraits(.isButton)
    }
}
