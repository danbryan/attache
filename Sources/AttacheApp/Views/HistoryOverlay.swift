import AttacheCore
import SwiftUI

/// The ⌘Y palette: history. Heard recaps and direct replies,
/// scoped to Focused / Watched / All, grouped by session with the focused
/// session first, searchable the moment it opens. Union of the original
/// echoform-ui-history overlay and the palette contract (shared key monitor,
/// type tokens, reading plate, accessibility).
struct HistoryOverlay: View {
    @ObservedObject var model: AppModel
    @Binding var isVisible: Bool
    @Environment(\.attacheTextScale) private var textScale
    @State private var query = ""
    @State private var scope: CompanionHistoryScope = .focused
    @State private var kindFilter: HistoryKindFilter = .all
    @State private var selectedID: String?
    @State private var hoveredID: String?
    @State private var collapsedGroups: Set<String> = []
    @FocusState private var fieldFocused: Bool

    /// Minimal All / Recaps filter over history, keyed on the recap metadata
    /// marker written by the inbox recap.
    private enum HistoryKindFilter: String, CaseIterable, Identifiable {
        case all
        case recaps

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return NSLocalizedString("All", comment: "")
            case .recaps: return NSLocalizedString("Recaps", comment: "")
            }
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var visibleCards: [VoicemailCard] {
        var raw = model.historyCards(for: scope)
        if kindFilter == .recaps {
            raw = raw.filter(isRecap)
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return raw }
        return raw.filter { searchableText(for: $0).localizedCaseInsensitiveContains(needle) }
    }

    private func isRecap(_ card: VoicemailCard) -> Bool {
        model.metadataDictionary(for: card)["attache_recap"] == "1"
    }

    private struct Group: Identifiable {
        let id: String
        let title: String
        let cards: [VoicemailCard]
    }

    private var groups: [Group] {
        let bySession = Dictionary(grouping: visibleCards, by: groupID)
        return bySession
            .map { id, cards in
                Group(
                    id: id,
                    title: groupTitle(for: cards),
                    cards: cards.sorted { $0.createdAt > $1.createdAt }
                )
            }
            .sorted { lhs, rhs in
                let lhsFocused = lhs.id == model.attachedCodexSessionID
                let rhsFocused = rhs.id == model.attachedCodexSessionID
                if lhsFocused != rhsFocused { return lhsFocused }
                return mostRecent(lhs.cards) > mostRecent(rhs.cards)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(model.theme.signatureColor)
                Text("History").typoSection()
                Text("recaps & replies")
                    .typoCaption(.medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $scope) {
                    ForEach(CompanionHistoryScope.allCases) { scope in
                        Text(scope.titleWithCount(model.historyCount(for: scope))).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280 * textScale)
                .accessibilityLabel("History scope")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history…", text: $query)
                    .textFieldStyle(.plain)
                    .typoSection(.regular)
                    .focused($fieldFocused)
                    .onSubmit(playSelection)
                    .accessibilityLabel("Search history")
                Picker("", selection: $kindFilter) {
                    ForEach(HistoryKindFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Show all history or recaps only")
                .accessibilityLabel("Filter history by kind")
                Text("\(visibleCards.count)")
                    .typoCaption(.medium, monoDigit: true)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if visibleCards.isEmpty {
                        Text(emptyStateText)
                            .typoBody().foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    ForEach(groups) { group in
                        groupHeader(group)
                        if !collapsedGroups.contains(group.id) {
                            ForEach(group.cards) { card in row(card) }
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 380)

            Divider()
            Text("↑↓ move · ⏎ play · esc close")
                .typoCaption(.medium)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 7)
        }
        // Width tracks the text scale so labels keep their room at every zoom.
        .frame(width: 640 * textScale)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .readingPlate(theme: model.theme)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 28, y: 12)
        .background(PaletteKeyMonitor(onMove: moveSelection, onSelect: playSelection))
        .onExitCommand { isVisible = false }
        .onAppear {
            scope = model.attachedCodexSessionID != nil ? .focused : .all
            // Deferred so it lands after PaletteKeyMonitor makes the window
            // key; assigning in the same pass silently loses focus.
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private var emptyStateText: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No history matches."
        }
        switch scope {
        case .focused:
            return model.attachedCodexSessionID == nil
                ? "No focused session. Press ⌘K to focus a session."
                : "No heard history for the focused session yet."
        case .watched:
            return model.attachedTargets.isEmpty
                ? "No watched sessions. Press ⌘K and pin a session to watch it."
                : "No heard history for watched sessions yet."
        case .all:
            return "No heard history yet."
        }
    }

    private func groupHeader(_ group: Group) -> some View {
        let collapsed = collapsedGroups.contains(group.id)
        return HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.14)) {
                    if collapsed { collapsedGroups.remove(group.id) } else { collapsedGroups.insert(group.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .typoIcon(size: 8, .bold)
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text("\(group.title.uppercased())  (\(group.cards.count))")
                        .typoCaption(.bold)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Expand this group" : "Collapse this group")
            .accessibilityLabel("\(group.title), \(group.cards.count) recaps, \(collapsed ? "collapsed" : "expanded")")
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 1)
    }

    private func row(_ card: VoicemailCard) -> some View {
        let active = hoveredID == card.id || selectedID == card.id
        let marker = model.personalityMarker(for: card)
        return HStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .typoIcon(size: 12, .semibold)
                .foregroundStyle(active ? model.theme.signatureColor : Color.secondary.opacity(0.7))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(rowTitle(for: card))
                        .typoBody(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    SourceBadge(sourceKind: card.sourceKind, displayName: card.sourceDisplayName)
                    if let marker {
                        PersonalityMarkerBadge(marker: marker, accent: model.theme.signatureColor, compact: true)
                    }
                }
                HStack(spacing: 5) {
                    Text(Self.relativeFormatter.localizedString(for: card.createdAt, relativeTo: Date()))
                    if card.durationMs > 0 {
                        Text("·")
                        Text(formatDuration(card.durationMs))
                    }
                    if isDirectReply(card) {
                        Text("· reply")
                    }
                }
                .typoCaption()
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle.fill").typoIcon(size: 16)
                .foregroundStyle(active ? model.theme.signatureColor : Color.secondary.opacity(0.6))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(active ? model.theme.signatureColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredID = card.id } else if hoveredID == card.id { hoveredID = nil }
        }
        .onTapGesture { play(card) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Replay \(rowTitle(for: card))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { play(card) }
    }

    /// Cards in display order, skipping collapsed groups, so arrow keys never
    /// select something that is not on screen.
    private var navigableCards: [VoicemailCard] {
        groups.filter { !collapsedGroups.contains($0.id) }.flatMap(\.cards)
    }

    private func moveSelection(_ delta: Int) {
        let list = navigableCards
        guard !list.isEmpty else { return }
        guard let current = selectedID, let index = list.firstIndex(where: { $0.id == current }) else {
            selectedID = delta >= 0 ? list.first?.id : list.last?.id
            return
        }
        selectedID = list[min(max(index + delta, 0), list.count - 1)].id
    }

    private func playSelection() {
        let list = navigableCards
        guard let card = list.first(where: { $0.id == selectedID }) ?? list.first else { return }
        play(card)
    }

    private func play(_ card: VoicemailCard) {
        model.playHistoryCard(card)
        isVisible = false
    }

    private func searchableText(for card: VoicemailCard) -> String {
        [
            card.sessionTitle,
            card.summary,
            card.spokenText,
            card.rawText,
            card.projectPath,
            card.sourceDisplayName,
            model.personalityMarker(for: card)?.displayName
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private func rowTitle(for card: VoicemailCard) -> String {
        let candidates = [card.summary, card.spokenText, card.rawText, "Attaché update"]
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Attaché update"
    }

    private func groupID(_ card: VoicemailCard) -> String {
        if let sessionID = card.externalSessionID, !sessionID.isEmpty {
            return sessionID
        }
        return "general:\(card.sourceKind)"
    }

    private func groupTitle(for cards: [VoicemailCard]) -> String {
        guard let card = cards.first else { return "General" }
        if let sessionID = card.externalSessionID,
           let session = model.sessionRecords.first(where: { $0.id == sessionID }) {
            return model.displaySessionTitle(session)
        }
        if let title = card.sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return "General"
    }

    private func mostRecent(_ cards: [VoicemailCard]) -> Date {
        cards.map(\.createdAt).max() ?? .distantPast
    }

    private func isDirectReply(_ card: VoicemailCard) -> Bool {
        let metadata = model.metadataDictionary(for: card)
        return metadata["companion_history_kind"] == "direct_reply"
            || metadata["companion_direct_reply"] == "true"
    }

    private func formatDuration(_ durationMs: Int) -> String {
        let totalSeconds = max(0, Int((Double(durationMs) / 1000.0).rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
