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
    @State private var scope: AttacheHistoryScope = .focused
    @State private var kindFilter: HistoryKindFilter = .all
    @State private var selectedID: String?
    @State private var hoveredID: String?
    @State private var collapsedGroups: Set<String> = []
    @State private var pendingDeletion: HistoryDeletionRequest?
    @State private var pendingForgetSession: SessionForgetRequest?
    @FocusState private var fieldFocused: Bool

    /// All / Recaps / Sent filter over history. All and Recaps are heard
    /// history (`VoicemailCard`, keyed on the recap metadata marker written by
    /// the inbox recap); Sent switches the list to what the user sent to an
    /// agent (`Instruction`, from `TwoWayCoordinator.log`) instead.
    private enum HistoryKindFilter: String, CaseIterable, Identifiable {
        case all
        case recaps
        case sent

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return NSLocalizedString("All", comment: "")
            case .recaps: return NSLocalizedString("Recaps", comment: "")
            case .sent: return NSLocalizedString("Sent", comment: "")
            }
        }
    }

    private struct HistoryDeletionRequest: Identifiable {
        let card: VoicemailCard
        let count: Int
        var id: String { card.id }
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
        model.metadataDictionary(for: card)["companion_recap"] == "1"
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

    /// Sent tab: what the user sent to an agent, from `TwoWayCoordinator.log`
    /// (INF-264), searched and scoped the same way heard history is.
    private var visibleInstructions: [Instruction] {
        let raw = model.sentInstructions(for: scope)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return raw }
        return raw.filter { searchableText(for: $0).localizedCaseInsensitiveContains(needle) }
    }

    private struct InstructionGroup: Identifiable {
        let id: String
        let title: String
        let instructions: [Instruction]
    }

    private var instructionGroups: [InstructionGroup] {
        let bySession = Dictionary(grouping: visibleInstructions, by: \.sessionID)
        return bySession
            .map { sessionID, instructions in
                InstructionGroup(
                    id: sessionID,
                    title: instructionGroupTitle(sessionID: sessionID, instructions: instructions),
                    instructions: instructions.sorted { $0.createdAt > $1.createdAt }
                )
            }
            .sorted { lhs, rhs in
                let lhsFocused = lhs.id == model.attachedCodexSessionID
                let rhsFocused = rhs.id == model.attachedCodexSessionID
                if lhsFocused != rhsFocused { return lhsFocused }
                return mostRecentInstruction(lhs.instructions) > mostRecentInstruction(rhs.instructions)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(model.theme.signatureColor)
                Text("History").typoSection()
                Text(kindFilter == .sent ? "sent to agents" : "recaps & replies")
                    .typoCaption(.medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $scope) {
                    ForEach(AttacheHistoryScope.allCases) { scope in
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
                .help("Show all history, recaps only, or what you sent to agents")
                .accessibilityLabel("Filter history by kind")
                Text("\(kindFilter == .sent ? visibleInstructions.count : visibleCards.count)")
                    .typoCaption(.medium, monoDigit: true)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if kindFilter == .sent {
                        if visibleInstructions.isEmpty {
                            Text(emptyStateText)
                                .typoBody().foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        }
                        ForEach(instructionGroups) { group in
                            instructionGroupHeader(group)
                            if !collapsedGroups.contains(group.id) {
                                ForEach(group.instructions) { instruction in instructionRow(instruction) }
                            }
                        }
                    } else {
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
                }
                .padding(6)
            }
            .frame(maxHeight: 380)

            Divider()
            Text(kindFilter == .sent ? "↑↓ move · ⏎ open reply · esc close" : "↑↓ move · ⏎ play · esc close")
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
        .onChange(of: kindFilter) { _ in
            // Selection/hover IDs belong to whichever list was on screen;
            // switching tabs would otherwise leave a stale highlight (or none)
            // pointing at an id from the other list.
            selectedID = nil
            hoveredID = nil
        }
        .confirmationDialog(
            pendingDeletion.map { $0.count > 1 ? "Delete conversation?" : "Delete history item?" } ?? "Delete history?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { request in
            Button(request.count > 1 ? "Delete Conversation" : "Delete History Item", role: .destructive) {
                model.deleteConversationHistory(containing: request.card)
                selectedID = nil
                hoveredID = nil
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { request in
            Text(request.count > 1
                 ? "This permanently deletes all \(request.count) saved replies and alternate takes in this Attaché conversation."
                 : "This permanently deletes the selected saved reply. Legacy replies cannot always be grouped into a whole conversation.")
        }
        .sessionForgetConfirmation(model: model, request: $pendingForgetSession)
    }

    private var emptyStateText: String {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if kindFilter == .sent {
            if !needle.isEmpty { return "No sent messages match." }
            switch scope {
            case .focused:
                return model.attachedCodexSessionID == nil
                    ? "No focused session. Press ⌘K to focus a session."
                    : "Nothing sent to the focused session yet."
            case .watched:
                return model.attachedTargets.isEmpty
                    ? "No watched sessions. Press ⌘K and pin a session to watch it."
                    : "Nothing sent to watched sessions yet."
            case .all:
                return "Nothing sent to an agent yet."
            }
        }
        if !needle.isEmpty {
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
                    if let externalSessionID = card.externalSessionID,
                       model.isSessionRecordingDisabled(sessionID: externalSessionID) {
                        SessionNotRecordedGlyph()
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
            ContextReceiptDisclosure(responseID: card.id, style: .compact)
            anotherTakeMenu(for: card)
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
        .contextMenu {
            Button { play(card) } label: {
                Label("Play", systemImage: "play.fill")
            }
            anotherTakeButtons(for: card)
            Divider()
            Button(role: .destructive) {
                pendingDeletion = HistoryDeletionRequest(
                    card: card,
                    count: model.conversationHistoryCount(containing: card)
                )
            } label: {
                Label(
                    model.conversationID(for: card) == nil ? "Delete History Item" : "Delete Conversation",
                    systemImage: "trash"
                )
            }
            if let externalSessionID = card.externalSessionID {
                Divider()
                SessionPrivacyMenuItems(
                    model: model,
                    sessionID: externalSessionID,
                    title: card.sessionTitle ?? rowTitle(for: card),
                    pendingForget: $pendingForgetSession
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Replay \(rowTitle(for: card))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { play(card) }
    }

    private func anotherTakeMenu(for card: VoicemailCard) -> some View {
        Menu {
            anotherTakeButtons(for: card)
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .typoIcon(size: 16)
                .foregroundStyle(Color.secondary.opacity(0.7))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Hear another personality's take")
        .accessibilityLabel("Another take on \(rowTitle(for: card))")
    }

    @ViewBuilder
    private func anotherTakeButtons(for card: VoicemailCard) -> some View {
        let choices = model.personalities.filter { $0.name != card.producedByPersonalityName }
        if choices.isEmpty {
            Text("No other personalities")
        } else {
            ForEach(choices) { personality in
                Button {
                    model.anotherTake(card: card, targetPersonalityID: personality.id)
                    isVisible = false
                } label: {
                    Text("\(personality.characterAvatarEmoji)  \(personality.name)")
                }
            }
        }
    }

    private func instructionGroupHeader(_ group: InstructionGroup) -> some View {
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
                    Text("\(group.title.uppercased())  (\(group.instructions.count))")
                        .typoCaption(.bold)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Expand this group" : "Collapse this group")
            .accessibilityLabel("\(group.title), \(group.instructions.count) sent, \(collapsed ? "collapsed" : "expanded")")
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 1)
    }

    private func instructionRowTitle(_ instruction: Instruction) -> some View {
        HStack(spacing: 7) {
            Text(instruction.text)
                .typoBody(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
            SourceBadge(sourceKind: instruction.sourceKind, displayName: instruction.targetDisplayName ?? instruction.sourceKind)
        }
    }

    private func instructionRowSubtitle(_ instruction: Instruction) -> some View {
        let subtitleStyle = instruction.state == .failed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary)
        return HStack(spacing: 5) {
            Text(Self.relativeFormatter.localizedString(for: instruction.createdAt, relativeTo: Date()))
            Text("·")
            Text(statusLabel(for: instruction))
        }
        .typoCaption()
        .foregroundStyle(subtitleStyle)
    }

    private func instructionRow(_ instruction: Instruction) -> some View {
        let active = hoveredID == instruction.id || selectedID == instruction.id
        let hasReply = instruction.resultingCardID != nil
        let leadingIcon = Image(systemName: statusIcon(for: instruction))
            .typoIcon(size: 12, .semibold)
            .foregroundStyle(statusColor(for: instruction, active: active))
            .frame(width: 18)
        let trailingIcon: AnyView = hasReply
            ? AnyView(
                Image(systemName: "play.circle.fill").typoIcon(size: 16)
                    .foregroundStyle(active ? model.theme.signatureColor : Color.secondary.opacity(0.6))
              )
            : AnyView(EmptyView())
        let rowContent = HStack(spacing: 10) {
            leadingIcon
            VStack(alignment: .leading, spacing: 3) {
                instructionRowTitle(instruction)
                instructionRowSubtitle(instruction)
            }
            Spacer(minLength: 0)
            trailingIcon
        }
        return rowContent
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(active ? model.theme.signatureColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { hoveredID = instruction.id } else if hoveredID == instruction.id { hoveredID = nil }
            }
            .onTapGesture { openReply(instruction) }
            .help(instruction.state == .failed ? (instruction.error ?? "") : "")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(instruction.text), \(statusLabel(for: instruction))")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openReply(instruction) }
    }

    private func statusIcon(for instruction: Instruction) -> String {
        switch instruction.state {
        case .pending, .confirmed: return "clock"
        case .delivering: return "arrow.triangle.2.circlepath"
        case .delivered: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .canceled: return "xmark.circle"
        }
    }

    private func statusLabel(for instruction: Instruction) -> String {
        switch instruction.state {
        case .pending: return "Pending"
        case .confirmed: return "Confirmed"
        case .delivering: return "Delivering…"
        case .delivered: return "Delivered"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        }
    }

    private func statusColor(for instruction: Instruction, active: Bool) -> Color {
        switch instruction.state {
        case .delivered: return .green
        case .failed: return .red
        default: return active ? model.theme.signatureColor : Color.secondary.opacity(0.7)
        }
    }

    private func searchableText(for instruction: Instruction) -> String {
        [
            instruction.text,
            instruction.sourceUtterance,
            instruction.targetDisplayName,
            instruction.deliveryReplyText
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private func instructionGroupTitle(sessionID: String, instructions: [Instruction]) -> String {
        if let session = model.sessionRecords.first(where: { $0.id == sessionID }) {
            return model.displaySessionTitle(session)
        }
        return instructions.first?.targetDisplayName ?? "General"
    }

    private func mostRecentInstruction(_ instructions: [Instruction]) -> Date {
        instructions.map(\.createdAt).max() ?? .distantPast
    }

    /// Cards in display order, skipping collapsed groups, so arrow keys never
    /// select something that is not on screen.
    private var navigableCards: [VoicemailCard] {
        groups.filter { !collapsedGroups.contains($0.id) }.flatMap(\.cards)
    }

    private var navigableInstructions: [Instruction] {
        instructionGroups.filter { !collapsedGroups.contains($0.id) }.flatMap(\.instructions)
    }

    private func moveSelection(_ delta: Int) {
        if kindFilter == .sent {
            let list = navigableInstructions
            guard !list.isEmpty else { return }
            guard let current = selectedID, let index = list.firstIndex(where: { $0.id == current }) else {
                selectedID = delta >= 0 ? list.first?.id : list.last?.id
                return
            }
            selectedID = list[min(max(index + delta, 0), list.count - 1)].id
            return
        }
        let list = navigableCards
        guard !list.isEmpty else { return }
        guard let current = selectedID, let index = list.firstIndex(where: { $0.id == current }) else {
            selectedID = delta >= 0 ? list.first?.id : list.last?.id
            return
        }
        selectedID = list[min(max(index + delta, 0), list.count - 1)].id
    }

    private func playSelection() {
        if kindFilter == .sent {
            let list = navigableInstructions
            guard let instruction = list.first(where: { $0.id == selectedID }) ?? list.first else { return }
            openReply(instruction)
            return
        }
        let list = navigableCards
        guard let card = list.first(where: { $0.id == selectedID }) ?? list.first else { return }
        play(card)
    }

    private func play(_ card: VoicemailCard) {
        model.playHistoryCard(card)
        isVisible = false
    }

    /// Sent rows have nothing to "play" directly; Enter/click only does
    /// something once the agent has actually replied and correlation
    /// (`TwoWayCoordinator.linkResponseCard`) has attached that reply's card.
    private func openReply(_ instruction: Instruction) {
        guard let cardID = instruction.resultingCardID,
              let card = model.cards.first(where: { $0.id == cardID }) else { return }
        play(card)
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
