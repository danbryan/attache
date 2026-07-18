import SwiftUI

// The ⌘/ shortcut help overlay (v0.1.2), listing the app's keyboard map.

struct KeyboardShortcutItem: Identifiable {
    var id: String { "\(title)-\(keys.joined())" }
    var keys: [String]
    var title: String
}


struct KeyboardShortcutsOverlay: View {
    @Binding var isVisible: Bool
    var accent: Color

    private let globalShortcuts: [KeyboardShortcutItem] = [
        KeyboardShortcutItem(keys: ["⌘", "K"], title: "Find session"),
        KeyboardShortcutItem(keys: ["⌘", "I"], title: "Inbox"),
        KeyboardShortcutItem(keys: ["⌘", "Y"], title: "History"),
        KeyboardShortcutItem(keys: ["⇧", "⌘", "P"], title: "Switch Attaché"),
        KeyboardShortcutItem(keys: ["⌘", "/"], title: "Keyboard shortcuts"),
        KeyboardShortcutItem(keys: ["⌘", ","], title: "Settings"),
        KeyboardShortcutItem(keys: ["⌘", "["], title: "Previous personality"),
        KeyboardShortcutItem(keys: ["⌘", "]"], title: "Next personality"),
        KeyboardShortcutItem(keys: ["⌘", "L"], title: "Call or hang up"),
        KeyboardShortcutItem(keys: ["S", "D", "R"], title: "Playback slower, faster, reset"),
        KeyboardShortcutItem(keys: ["⌘", "+/-"], title: "Zoom interface")
    ]

    private let playbackShortcuts: [KeyboardShortcutItem] = [
        KeyboardShortcutItem(keys: ["Space"], title: "Play or pause"),
        KeyboardShortcutItem(keys: ["←"], title: "Back by skip interval"),
        KeyboardShortcutItem(keys: ["→"], title: "Forward by skip interval"),
        KeyboardShortcutItem(keys: ["+"], title: "Larger captions"),
        KeyboardShortcutItem(keys: ["-"], title: "Smaller captions")
    ]

    private let navigationShortcuts: [KeyboardShortcutItem] = [
        KeyboardShortcutItem(keys: ["Esc"], title: "Dismiss playback or overlay"),
        KeyboardShortcutItem(keys: ["Delete"], title: "Archive selected voicemail"),
        KeyboardShortcutItem(keys: ["⌘", "⌫"], title: "Archive in inbox palette"),
        KeyboardShortcutItem(keys: ["⌘", "⏎"], title: "Follow up from inbox palette")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keyboard Shortcuts")
                        .font(.system(size: 18, weight: .bold))
                    Text("Available from Help > Keyboard Shortcuts")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isVisible = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .background(Color.primary.opacity(0.08), in: Circle())
                .help("Close (Esc)")
            }

            VStack(spacing: 14) {
                shortcutSection("Navigation", items: globalShortcuts)
                shortcutSection("Playback", items: playbackShortcuts)
                shortcutSection("Overlays", items: navigationShortcuts)
            }
        }
        .padding(18)
        .frame(width: 430)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(accent.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.30), radius: 20, y: 10)
    }

    private func shortcutSection(_ title: String, items: [KeyboardShortcutItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent)
            VStack(spacing: 7) {
                ForEach(items) { item in
                    KeyboardShortcutRow(item: item, accent: accent)
                }
            }
        }
    }
}


struct KeyboardShortcutRow: View {
    var item: KeyboardShortcutItem
    var accent: Color

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(item.keys, id: \.self) { key in
                    KeyboardKeyCap(label: key, accent: accent)
                }
            }
            .frame(width: 128, alignment: .leading)

            Text(item.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }
}


struct KeyboardKeyCap: View {
    var label: String
    var accent: Color

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.primary.opacity(0.88))
            .frame(minWidth: label.count > 1 ? 42 : 24, minHeight: 24)
            .padding(.horizontal, label.count > 1 ? 2 : 0)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(accent.opacity(0.22), lineWidth: 1)
            )
    }
}
