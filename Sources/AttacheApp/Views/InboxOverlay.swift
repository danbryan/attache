import AttacheCore
import SwiftUI

/// A ⌘K-style overlay for waiting voicemails. Pick one and it plays on the normal
/// talking screen (no voicemail window); reopen the overlay for the next. Grouped by
/// session, sorted by who has the most waiting, with the focused session first.
struct InboxOverlay: View {
    @ObservedObject var model: AppModel
    @Binding var isVisible: Bool
    @Environment(\.attacheTextScale) private var textScale
    @State private var hoveredID: String?
    @State private var selectedID: String?
    @State private var query = ""
    @FocusState private var fieldFocused: Bool
    @State private var hoveredClearID: String?
    @State private var collapsedGroups: Set<String> = []
    @State private var sourceFilter: SourceKind?
    // Cards checked for a scoped recap / play. Empty means "act on all visible".
    @State private var checkedIDs: Set<String> = []

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Everything waiting in the current scope; the digest and play-all
    /// describe this full set.
    private var allWaiting: [VoicemailCard] {
        guard let sourceFilter else { return model.scopedUnreadCards }
        return model.scopedUnreadCards.filter { $0.sourceKind == sourceFilter.rawValue }
    }

    /// The visible, searchable list.
    private var waiting: [VoicemailCard] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allWaiting }
        return allWaiting.filter { card in
            (card.sessionTitle ?? "").localizedCaseInsensitiveContains(trimmed)
                || card.summary.localizedCaseInsensitiveContains(trimmed)
                || card.spokenText.localizedCaseInsensitiveContains(trimmed)
                || card.sourceDisplayName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private struct Group: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let cards: [VoicemailCard]
    }

    private var groups: [Group] {
        let bySession = Dictionary(grouping: waiting, by: groupID)
        return bySession
            .map { id, cards in
                Group(
                    id: id,
                    title: groupTitle(for: cards),
                    subtitle: groupSubtitle(for: cards),
                    cards: cards.sorted { lhs, rhs in
                        if lhs.needsDecision != rhs.needsDecision { return lhs.needsDecision }
                        return lhs.createdAt > rhs.createdAt
                    }
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
                Image(systemName: "tray.full").foregroundStyle(model.theme.signatureColor)
                Text("Inbox").typoSection()
                Text("\(waiting.count) of \(model.unreadCount)")
                    .typoCaption(.medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                Button {
                    model.archiveCards(waiting)
                } label: {
                    // Degrade to a shorter label instead of ever wrapping when
                    // large text sizes squeeze the header.
                    ViewThatFits(in: .horizontal) {
                        Label("Clear visible", systemImage: "archivebox")
                        Label("Clear", systemImage: "archivebox")
                        Image(systemName: "archivebox")
                    }
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                }
                .buttonStyle(.plain)
                .typoCaption(.semibold)
                .foregroundStyle(waiting.isEmpty ? Color.secondary.opacity(0.45) : model.theme.signatureColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(waiting.isEmpty ? Color.clear : model.theme.signatureColor.opacity(0.12))
                )
                .disabled(waiting.isEmpty)
                .help("Clear all voicemail visible in the current filter")
                // Scope only: source (Codex / Claude Code) is a separate filter
                // by the search field, so tabs never repeat the same counts.
                Picker("", selection: $model.inboxScope) {
                    ForEach([VoicemailInboxScope.all, .focused, .watched]) { scope in
                        Text(scope.titleWithCount(model.unreadCount(for: scope))).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280 * textScale)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search inbox…", text: $query)
                    .textFieldStyle(.plain)
                    .typoSection(.regular)
                    .focused($fieldFocused)
                    .onSubmit(playSelection)
                    .accessibilityLabel("Search inbox")
                Menu {
                    Button { sourceFilter = nil } label: {
                        Label("All sources", systemImage: sourceFilter == nil ? "checkmark" : "tray.2")
                    }
                    ForEach([SourceKind.codex, .claudeCode], id: \.rawValue) { kind in
                        Button { sourceFilter = kind } label: {
                            Label(kind.displayName, systemImage: sourceFilter == kind ? "checkmark" : "terminal")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle\(sourceFilter == nil ? "" : ".fill")")
                            .typoIcon(size: 13, .semibold)
                        if let sourceFilter {
                            Text(sourceFilter.displayName)
                                .typoCaption(.semibold)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(sourceFilter == nil ? Color.secondary : model.theme.signatureColor)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter by source")
                .accessibilityLabel("Filter by source")
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            Divider()

            if allWaiting.count >= 2 {
                let checked = checkedCards
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if checked.isEmpty {
                        Text(model.inboxDigestText(for: allWaiting))
                            .typoLabel()
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("\(checked.count) selected")
                            .typoCaption(.bold)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .fixedSize()
                        Button("Deselect") { checkedIDs.removeAll() }
                            .buttonStyle(.plain)
                            .typoCaption(.semibold)
                            .foregroundStyle(model.theme.signatureColor)
                            .accessibilityLabel("Deselect all")
                    }
                    Spacer(minLength: 8)
                    Button {
                        let targets = checked.isEmpty ? allWaiting : checked
                        checkedIDs.removeAll()
                        isVisible = false
                        model.playInboxRecap(for: targets)
                    } label: {
                        Label(checked.isEmpty ? "Play recap" : "Recap \(checked.count)", systemImage: "text.bubble")
                            .typoCaption(.semibold)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .accessibilityLabel(checked.isEmpty ? "Play recap of everything waiting" : "Play recap of \(checked.count) selected")
                    Button {
                        let targets = checked.isEmpty ? allWaiting : checked
                        model.playAllUnread(targets)
                        isVisible = false
                    } label: {
                        Label(checked.isEmpty ? "Play all" : "Play \(checked.count)", systemImage: "play.square.stack")
                            .typoCaption(.semibold)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .accessibilityLabel(checked.isEmpty ? "Play all" : "Play \(checked.count) selected")
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Color.primary.opacity(0.04))
                Divider()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if waiting.isEmpty {
                        Text("No voicemail waiting. You're all caught up.")
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
            Text("↑↓ move · ⏎ play · ⌘⏎ follow up · ⌘⌫ archive · ⇧⌘⌫ archive group · esc close")
                .typoCaption(.medium)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 7)
        }
        // Width tracks the text scale so labels keep their room at every zoom.
        .frame(width: 640 * textScale)
        .background(PaletteKeyMonitor(
            onMove: moveSelection,
            onSelect: playSelection,
            onCommandReturn: followUpSelection,
            onCommandDelete: archiveSelection,
            onShiftCommandDelete: archiveSelectionGroup
        ))
        // Deferred so it lands after PaletteKeyMonitor makes the window key;
        // assigning in the same pass silently loses focus.
        .onAppear {
            // Source scopes moved out of the tab row into the filter menu.
            if model.inboxScope == .codex { model.inboxScope = .all; sourceFilter = .codex }
            if model.inboxScope == .claudeCode { model.inboxScope = .all; sourceFilter = .claudeCode }
            DispatchQueue.main.async { fieldFocused = true }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .readingPlate(theme: model.theme)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 28, y: 12)
        .onExitCommand { isVisible = false }
    }

    // The header owns everything the cards in a group share: the session
    // title, the source, the project, and the clear action. Rows below it
    // carry only what differs card to card.
    private func groupHeader(_ group: Group) -> some View {
        let collapsed = collapsedGroups.contains(group.id)
        return HStack(spacing: 6) {
            Button {
                toggleGroup(group)
            } label: {
                Image(systemName: groupCheckIcon(group))
                    .typoIcon(size: 14, .semibold)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(groupAnyChecked(group) ? model.theme.signatureColor : Color.secondary.opacity(0.4))
            .help("Select all in this group for recap")
            .accessibilityLabel("Select all in \(group.title)")
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
            .accessibilityLabel("\(group.title), \(group.cards.count) waiting, \(collapsed ? "collapsed" : "expanded")")
            if let card = group.cards.first {
                SourceBadge(sourceKind: card.sourceKind,
                            displayName: card.sourceDisplayName,
                            localModelHint: model.localModelHint(forExternalSessionID: card.externalSessionID))
            }
            if let subtitle = group.subtitle {
                Text(subtitle)
                    .typoCaption(.medium)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                model.archiveCards(group.cards)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.theme.signatureColor.opacity(0.85))
            .help("Clear this group")
            .accessibilityLabel("Clear group \(group.title)")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 1)
    }

    private func groupID(_ card: VoicemailCard) -> String {
        if model.isGeneralVoicemailCard(card) {
            return "general:\(card.sourceKind)"
        }
        return card.externalSessionID ?? "general:\(card.sourceKind)"
    }

    private func groupTitle(for cards: [VoicemailCard]) -> String {
        guard let card = cards.first else { return "General" }
        if model.isGeneralVoicemailCard(card) { return "General" }
        if let sessionID = card.externalSessionID,
           let session = model.sessionRecords.first(where: { $0.id == sessionID }) {
            return model.displaySessionTitle(session)
        }
        if let title = card.sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return "Session"
    }

    private func groupSubtitle(for cards: [VoicemailCard]) -> String? {
        guard let card = cards.first else { return nil }
        // The source has its own chip in the header, so the subtitle only
        // carries the project.
        if model.isGeneralVoicemailCard(card) { return nil }
        if let project = card.projectPath, !project.isEmpty {
            return model.curatedProjectName(forCWD: project) ?? URL(fileURLWithPath: project).lastPathComponent
        }
        return nil
    }

    private func mostRecent(_ cards: [VoicemailCard]) -> Date {
        cards.map(\.createdAt).max() ?? .distantPast
    }

    // The session title lives in the group header, so the row leads with what
    // is unique to this card: its summary.
    private func row(_ card: VoicemailCard) -> some View {
        let active = hoveredID == card.id || selectedID == card.id
        let checked = checkedIDs.contains(card.id)
        return HStack(spacing: 10) {
            Button {
                toggleCheck(card)
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .typoIcon(size: 15, checked ? .semibold : .regular)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(checked ? model.theme.signatureColor : Color.secondary.opacity(active ? 0.6 : 0.3))
            .help(checked ? "Unselect" : "Select for recap")
            .accessibilityLabel(checked ? "Selected" : "Select for recap")
            Image(systemName: card.kind == .error ? "exclamationmark.triangle.fill" : "envelope.fill")
                .typoIcon(size: 11)
                .foregroundStyle(card.kind == .error ? .orange : model.theme.signatureColor)
            Text(rowTitle(for: card))
                .typoBody(.medium).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 0)
            if card.needsDecision {
                Text("needs decision")
                    .typoCaption(.bold)
                    .foregroundStyle(model.theme.signatureColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(model.theme.signatureColor.opacity(0.55), lineWidth: 1))
            }
            if let marker = model.personalityMarker(for: card) {
                PersonalityMarkerBadge(marker: marker, accent: model.theme.signatureColor, compact: true)
            }
            Text(Self.relativeFormatter.localizedString(for: card.createdAt, relativeTo: Date()))
                .typoCaption().foregroundStyle(.tertiary)
            Button {
                model.archiveCards([card])
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .typoIcon(size: 15, .semibold)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(hoveredClearID == card.id ? model.theme.signatureColor : Color.secondary.opacity(active ? 0.72 : 0.32))
            .onHover { hovering in
                if hovering { hoveredClearID = card.id } else if hoveredClearID == card.id { hoveredClearID = nil }
            }
            .help("Clear this voicemail")
            .accessibilityLabel("Clear this voicemail")
            Image(systemName: "play.circle.fill").typoIcon(size: 16)
                .foregroundStyle(active ? model.theme.signatureColor : Color.secondary.opacity(0.6))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(active ? model.theme.signatureColor.opacity(0.14) : (checked ? model.theme.signatureColor.opacity(0.07) : Color.clear), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredID = card.id } else if hoveredID == card.id { hoveredID = nil }
        }
        .onTapGesture {
            model.playInboxCard(card)   // plays on the normal screen
            isVisible = false
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Play \(model.displaySessionTitle(forCard: card) ?? "Update"): \(rowTitle(for: card))\(card.needsDecision ? ", needs decision" : "")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            model.playInboxCard(card)
            isVisible = false
        }
    }

    private func rowTitle(for card: VoicemailCard) -> String {
        let candidates = [
            card.summary,
            card.spokenText,
            model.displaySessionTitle(forCard: card) ?? "",
            "Update"
        ]
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Update"
    }

    // MARK: Multi-select for recap / play

    /// Cards currently checked, within the active scope. Empty means the recap
    /// and play buttons act on everything visible instead.
    private var checkedCards: [VoicemailCard] {
        allWaiting.filter { checkedIDs.contains($0.id) }
    }

    private func toggleCheck(_ card: VoicemailCard) {
        if checkedIDs.contains(card.id) { checkedIDs.remove(card.id) } else { checkedIDs.insert(card.id) }
    }

    private func toggleGroup(_ group: Group) {
        let ids = group.cards.map(\.id)
        if ids.allSatisfy({ checkedIDs.contains($0) }) {
            ids.forEach { checkedIDs.remove($0) }
        } else {
            checkedIDs.formUnion(ids)
        }
    }

    private func groupCheckIcon(_ group: Group) -> String {
        let ids = group.cards.map(\.id)
        let checkedCount = ids.filter { checkedIDs.contains($0) }.count
        if checkedCount == 0 { return "circle" }
        return checkedCount == ids.count ? "checkmark.circle.fill" : "minus.circle.fill"
    }

    private func groupAnyChecked(_ group: Group) -> Bool {
        group.cards.contains { checkedIDs.contains($0.id) }
    }
}

// MARK: - One-handed triage (INF-169)

extension InboxOverlay {
    private var flatCards: [VoicemailCard] {
        // Arrow keys skip cards hidden inside collapsed groups.
        groups.filter { !collapsedGroups.contains($0.id) }.flatMap(\.cards)
    }

    func moveSelection(_ delta: Int) {
        let cards = flatCards
        guard !cards.isEmpty else { return }
        guard let current = selectedID, let index = cards.firstIndex(where: { $0.id == current }) else {
            selectedID = delta >= 0 ? cards.first?.id : cards.last?.id
            return
        }
        let next = min(max(index + delta, 0), cards.count - 1)
        selectedID = cards[next].id
    }

    func playSelection() {
        guard let card = selectedCard() else { return }
        if model.playbackCurrentCardID == card.id {
            model.togglePlaybackPause()
        } else {
            model.playInboxCard(card)
            isVisible = false
        }
    }

    func archiveSelection() {
        guard let card = selectedCard() else { return }
        moveSelection(1)
        if selectedID == card.id { selectedID = nil }
        model.archiveCards([card])
    }

    func archiveSelectionGroup() {
        guard let card = selectedCard(),
              let group = groups.first(where: { $0.cards.contains(where: { $0.id == card.id }) }) else { return }
        selectedID = nil
        model.archiveCards(group.cards)
    }

    func followUpSelection() {
        guard let card = selectedCard() else { return }
        model.selectedCardID = card.id
        isVisible = false
        NotificationCenter.default.post(name: .attacheOpenVoicemailSurface, object: card.id)
    }

    private func selectedCard() -> VoicemailCard? {
        let cards = flatCards
        if let selectedID, let card = cards.first(where: { $0.id == selectedID }) {
            return card
        }
        return cards.first
    }
}
