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
