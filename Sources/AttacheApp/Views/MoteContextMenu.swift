import AttacheCore
import SwiftUI

/// Pure description of the right-click context menu for a watched-session
/// agent mote orbiting the character (INF-375). Kept free of SwiftUI and
/// AppModel so the "which items appear for focused vs unfocused" decision is
/// unit-tested directly.
struct MoteContextMenuModel: Equatable {
    /// The watched session's display title, shown in the disabled header.
    var title: String
    /// The agent source's display name (e.g. "Codex", "Claude Code").
    var source: String
    /// True when this mote's session is the currently focused one.
    var isFocused: Bool
    /// Whether an "Unfocus" action is available. False when the app has no
    /// safe focus-none primitive to call; see the wiring in `AttacheRootView`.
    var canUnfocus: Bool

    /// The actionable items, in display order. "Stop Watching" is always
    /// present; "Unfocus" appears only for the focused mote when supported.
    /// Modeled as a list so future items (enter call, recap unread) slot in.
    enum Item: Hashable {
        case unfocus
        case stopWatching
    }

    var items: [Item] {
        var result: [Item] = []
        if isFocused && canUnfocus { result.append(.unfocus) }
        result.append(.stopWatching)
        return result
    }

    /// The header line combining title and source, matching the session-row
    /// convention ("Title · Source").
    var header: String {
        source.isEmpty ? title : "\(title) · \(source)"
    }
}

/// Renders `MoteContextMenuModel` as SwiftUI context-menu content. A small
/// dedicated builder so future items slot in beside the existing ones without
/// touching the renderer's hit-testing or gesture code.
struct MoteContextMenuContent: View {
    let model: MoteContextMenuModel
    var onStopWatching: () -> Void
    var onUnfocus: () -> Void

    var body: some View {
        Section {
            ForEach(model.items, id: \.self) { item in
                switch item {
                case .unfocus:
                    Button("Unfocus", action: onUnfocus)
                        .accessibilityIdentifier("Unfocus")
                case .stopWatching:
                    Button("Stop Watching", action: onStopWatching)
                        .accessibilityIdentifier("Stop Watching")
                }
            }
        } header: {
            Text(model.header)
        }
    }
}
