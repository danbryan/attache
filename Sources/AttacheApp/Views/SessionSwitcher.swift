import AppKit
import AttacheCore
import SwiftUI

private struct SessionGroup: Identifiable {
    let id: String
    let header: String?
    let hits: [SessionSearchHit]
}

/// ⌘K command palette: fuzzy name + full-text content + plain-language search
/// across enabled local-agent sessions, grouped by recency / project /
/// continuation chain. Watched sessions are pinned to the top because they have
/// active side effects: Attaché monitors them for updates.
struct SessionCommandPalette: View {
    @ObservedObject var model: AppModel
    @Binding var isVisible: Bool
    @Environment(\.attacheTextScale) private var textScale
    @State private var query = ""
    @State private var grouping: SessionSort = .recent
    @State private var includeArchived = false
    @State private var hoveredID: String?
    @State private var selectedID: String?
    @State private var hits: [SessionSearchHit] = []
    @State private var groups: [SessionGroup] = []
    @State private var renamingID: String?
    @State private var renameText = ""
    @State private var collapsedGroups: Set<String> = []
    @State private var watchedIDsAtOpen: Set<String> = []
    @State private var suppressNextRowAttach = false
    @State private var hoveredPinID: String?
    @State private var sourceFilter: SourceKind?   // nil = all tools
    @FocusState private var fieldFocused: Bool

    /// Tools that actually have sessions in the index, in a stable order, so the
    /// source filter and per-row badge only appear once more than one tool is present.
    private var availableSources: [SourceKind] {
        let present = Set(model.sessionRecords.map(\.sourceKind))
        return SourceKind.allCases.filter { present.contains($0) }
    }

    // Keyboard nav and "pick top" only walk visible rows, so collapsed groups are skipped.
    private var flatHits: [SessionSearchHit] {
        groups.flatMap { group in
            (group.header != nil && collapsedGroups.contains(group.id)) ? [] : group.hits
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search name, content, or describe it…", text: $query)
                    .textFieldStyle(.plain)
                    .typoSection(.regular)
                    .focused($fieldFocused)
                    .onSubmit(selectTop)
                if model.isIndexingSessions { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)

            Divider()

            HStack(spacing: 10) {
                Picker("", selection: $grouping) {
                    Text("Recent").tag(SessionSort.recent)
                    Text("Project").tag(SessionSort.project)
                    Text("Threads").tag(SessionSort.continuation)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240 * textScale)
                Spacer()
                if availableSources.count > 1 {
                    Menu {
                        Button { sourceFilter = nil } label: {
                            Label("All tools", systemImage: sourceFilter == nil ? "checkmark" : "")
                        }
                        ForEach(availableSources, id: \.self) { source in
                            Button { sourceFilter = source } label: {
                                Label(source.displayName, systemImage: sourceFilter == source ? "checkmark" : "")
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text(sourceFilter?.displayName ?? "All tools")
                        }
                        .typoCaption(.medium)
                    }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(sourceFilter == nil ? Color.secondary : model.theme.signatureColor)
                }
                archivedToggle
                Text("\(hits.count)")
                    .typoCaption(.medium, design: .monospaced)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if hits.isEmpty {
                            Text(emptyStateText)
                                .typoBody()
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                        }
                        ForEach(groups) { group in
                            if let header = group.header {
                                groupHeader(group, title: header)
                            }
                            if group.header == nil || !collapsedGroups.contains(group.id) {
                                ForEach(group.hits, id: \.record.id) { hit in
                                    row(hit).id(hit.record.id)
                                }
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 400)
                .onChange(of: selectedID) { id in
                    if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
        // Width tracks the text scale so labels keep their room at every zoom.
        .frame(width: 620 * textScale)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .readingPlate(theme: model.theme)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 28, y: 12)
        .background(PaletteKeyMonitor(onMove: moveSelection, onSelect: selectCurrent))
        .onAppear {
            // Deferred so it lands after PaletteKeyMonitor makes the window
            // key; assigning in the same pass silently loses focus.
            DispatchQueue.main.async { fieldFocused = true }
            watchedIDsAtOpen = Set(model.attachedTargets.keys)
            model.refreshSessionIndex()
            recompute()
        }
        .onExitCommand { isVisible = false }
        .onChange(of: query) { _ in recompute() }
        .onChange(of: grouping) { _ in recompute() }
        .onChange(of: includeArchived) { _ in recompute() }
        .onChange(of: model.sessionRecords.count) { _ in recompute() }
        .onChange(of: model.sessionIndexRevision) { _ in recompute() }
        .onChange(of: sourceFilter) { _ in recompute() }
        .onChange(of: model.attachedTargets.count) { _ in recompute() }
        .onChange(of: model.unreadCount) { _ in recompute() }
        .alert("Rename for Attaché", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let id = renamingID { model.renameSession(id, to: renameText) }
                renamingID = nil
                recompute()
            }
            Button("Cancel", role: .cancel) { renamingID = nil }
        } message: {
            Text("Sets how Attaché labels this session. Codex is unchanged.")
        }
    }

    private var emptyStateText: String {
        if !model.localAgentSourcesEnabled {
            return "No local agent sources connected. Enable Codex or Claude Code in Settings → Integrations."
        }
        return model.sessionRecords.isEmpty ? "Indexing your sessions…" : "No sessions match."
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })
    }

    private var archivedToggle: some View {
        Button {
            includeArchived.toggle()
            fieldFocused = true
        } label: {
            HStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(includeArchived ? model.theme.signatureColor.opacity(0.18) : Color.primary.opacity(0.08))
                        .frame(width: 13, height: 13)
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(includeArchived ? model.theme.signatureColor.opacity(0.70) : Color.secondary.opacity(0.34), lineWidth: 1)
                        .frame(width: 13, height: 13)
                    if includeArchived {
                        Image(systemName: "checkmark")
                            .typoIcon(size: 8, .bold)
                            .foregroundStyle(model.theme.signatureColor)
                    }
                }
                Text("Archived")
                    .typoCaption()
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(includeArchived ? "Hide archived sessions" : "Show archived sessions")
    }

    private func recompute() {
        hits = model.searchSessions(query, includeArchived: includeArchived)
            .filter { sourceFilter == nil || $0.record.sourceKind == sourceFilter }
        groups = buildGroups(from: hits)
        if selectedID == nil || !flatHits.contains(where: { $0.record.id == selectedID }) {
            selectedID = flatHits.first?.record.id
        }
    }

    private func groupHeader(_ group: SessionGroup, title: String) -> some View {
        let collapsed = collapsedGroups.contains(group.id)
        return Button {
            withAnimation(.easeOut(duration: 0.14)) {
                if collapsed { collapsedGroups.remove(group.id) } else { collapsedGroups.insert(group.id) }
            }
            if collapsed { selectedID = flatHits.first?.record.id }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .typoIcon(size: 8, .bold)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(title)
                    .typoCaption(.bold)
                if collapsed {
                    Text("\(group.hits.count)")
                        .typoCaption(.semibold, design: .monospaced)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 2)
        }
        .buttonStyle(.plain)
    }

    private func moveSelection(_ delta: Int) {
        let ids = flatHits.map(\.record.id)
        guard !ids.isEmpty else { return }
        let current = selectedID.flatMap { ids.firstIndex(of: $0) } ?? -1
        selectedID = ids[max(0, min(ids.count - 1, current + delta))]
    }

    private func selectCurrent() {
        if let id = selectedID, let hit = flatHits.first(where: { $0.record.id == id }) {
            attach(hit)
        } else {
            selectTop()
        }
    }

    private func buildGroups(from hits: [SessionSearchHit]) -> [SessionGroup] {
        let watched = hits.filter { watchedIDsAtOpen.contains($0.record.id) }
        let rest = hits.filter { !watchedIDsAtOpen.contains($0.record.id) }
        let unheard = rest.filter { model.unreadCount(forSessionID: $0.record.id) > 0 }
        let remaining = rest.filter { model.unreadCount(forSessionID: $0.record.id) == 0 }
        var result: [SessionGroup] = []
        if !watched.isEmpty {
            result.append(SessionGroup(id: "watching", header: "WATCHING", hits: watched))
        }
        if !unheard.isEmpty {
            result.append(SessionGroup(id: "unheard", header: "UNHEARD VOICEMAIL", hits: unheard))
        }

        switch grouping {
        case .recent:
            if !remaining.isEmpty {
                result.append(SessionGroup(id: "recent", header: watched.isEmpty && unheard.isEmpty ? nil : "RECENT", hits: remaining))
            }
        case .project:
            // Group by Codex's curated projects; everything else falls into "Other".
            let byProject = Dictionary(grouping: remaining) { model.curatedProjectName(forCWD: $0.record.project) ?? "Other" }
            let sortedGroups = byProject.sorted { lhs, rhs in
                if (lhs.key == "Other") != (rhs.key == "Other") { return rhs.key == "Other" }
                return mostRecent(lhs.value) > mostRecent(rhs.value)
            }
            for (proj, items) in sortedGroups {
                result.append(SessionGroup(id: "proj:\(proj)", header: proj.uppercased(), hits: items.sorted { $0.record.updatedAt > $1.record.updatedAt }))
            }
        case .continuation:
            // A thread = a real continuation chain (same Codex thread name, sessions
            // clustered in one sitting). Recurring automations (a daily brief) reuse a
            // name but run a day apart, so they never cluster and stay standalone.
            let byID = Dictionary(uniqueKeysWithValues: remaining.map { ($0.record.id, $0) })
            let chains = SessionThreadGrouper.chains(from: remaining.map(\.record))
            var chained = Set<String>()
            for chain in chains {
                let items = chain.ids.compactMap { byID[$0] }
                guard items.count > 1 else { continue }
                chain.ids.forEach { chained.insert($0) }
                result.append(SessionGroup(id: "chain:\(chain.name)", header: "\(chain.name.uppercased())  (\(items.count))", hits: items))
            }
            let singles = remaining.filter { !chained.contains($0.record.id) }.sorted { $0.record.updatedAt > $1.record.updatedAt }
            if !singles.isEmpty {
                result.append(SessionGroup(id: "singles", header: chains.isEmpty ? nil : "STANDALONE", hits: singles))
            }
        }
        return result
    }

    private func row(_ hit: SessionSearchHit) -> some View {
        let record = hit.record
        let attached = record.id == model.attachedCodexSessionID   // focused
        let watching = model.attachedTargets[record.id] != nil      // in the watch list
        let active = selectedID == record.id || hoveredID == record.id
        let renamed = model.sessionRenames[record.id] != nil
        let voicemailCount = model.unreadCount(forSessionID: record.id)
        let projectDisplay = model.curatedProjectName(forCWD: record.project) ?? projectName(record.project)
        // Only show the topic chip when it actually adds information, not when it just
        // repeats the project or the title ("Operations / Operations", "Maryland Lien").
        let tagToShow: String? = {
            guard let tag = record.topicTag, !tag.isEmpty else { return nil }
            let lower = tag.lowercased()
            if lower == "general" || lower == "untagged" { return nil }
            if projectDisplay.lowercased().contains(lower) { return nil }
            if record.title.lowercased().contains(lower) { return nil }
            return tag
        }()
        return HStack(spacing: 10) {
            Circle()
                .fill(attached ? model.theme.signatureColor : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displaySessionTitle(record))
                        .typoBody(attached ? .semibold : .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if renamed {
                        Image(systemName: "pencil")
                            .typoIcon(size: 8, .bold)
                            .foregroundStyle(.secondary)
                    }
                    if hit.matchedContent {
                        Text("in transcript")
                            .typoCaption(.semibold)
                            .foregroundStyle(model.theme.signatureColor)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(model.theme.signatureColor.opacity(0.14), in: Capsule())
                    }
                }
                HStack(spacing: 5) {
                    if availableSources.count > 1 {
                        SourceBadge(sourceKind: record.sourceKind.rawValue,
                                    displayName: record.sourceKind.displayName)
                    }
                    if let tag = tagToShow {
                        Text(tag)
                            .typoCaption(.semibold)
                            .foregroundStyle(model.theme.signatureColor)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(model.theme.signatureColor.opacity(0.14), in: Capsule())
                    }
                    Text(projectDisplay).lineLimit(1)
                    Text("·")
                    Text(Self.relativeFormatter.localizedString(for: record.updatedAt, relativeTo: Date()))
                    if record.archived { Text("· archived") }
                }
                .typoCaption()
                .foregroundStyle(.secondary)
                if let snippet = hit.snippet {
                    Text(snippet)
                        .typoCaption()
                        .foregroundStyle(.secondary.opacity(0.85))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                voicemailBadgeSlot(count: voicemailCount)
                if watching || active {
                    watchToggleButton(hit, watching: watching)
                } else {
                    Color.clear.frame(width: 28, height: 24)
                }
                statusSlot(attached: attached, watching: watching)
            }
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(active ? model.theme.signatureColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredID = record.id }
            else if hoveredID == record.id { hoveredID = nil }
        }
        .onTapGesture {
            if suppressNextRowAttach {
                suppressNextRowAttach = false
                return
            }
            attach(hit)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session \(model.displaySessionTitle(record)) \(record.id)")
        .accessibilityValue(hit.snippet ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { attach(hit) }
        .contextMenu {
            Button("Rename for Attaché") {
                renameText = model.displaySessionTitle(record)
                renamingID = record.id
            }
            if renamed {
                Button("Reset to Codex name") { model.renameSession(record.id, to: ""); recompute() }
            }
            Divider()
            if watching {
                if !attached { Button(model.voicemailMode ? "Focus this session" : "Go live on this session") { model.focusCodexSession(record.id) } }
                Button("Stop watching") { model.detachCodexSession(record.id) }
            } else {
                Button("Pin to Watching") { model.watchSearchHit(hit, focus: false); recompute() }
            }
        }
    }

    @ViewBuilder
    private func voicemailBadgeSlot(count: Int) -> some View {
        if count > 0 {
            HStack(spacing: 4) {
                Image(systemName: "envelope.fill")
                    .typoIcon(size: 9, .bold)
                Text(voicemailCountLabel(count))
                    .typoCaption(.bold, design: .rounded)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .minimumScaleFactor(0.86)
            }
            .foregroundStyle(model.theme.signatureColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(width: 58, alignment: .center)
            .background(model.theme.signatureColor.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(model.theme.signatureColor.opacity(0.28)))
            .help("\(count) unheard voicemail\(count == 1 ? "" : "s")")
        } else {
            Color.clear.frame(width: 58, height: 22)
        }
    }

    private func voicemailCountLabel(_ count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }

    private func watchToggleButton(_ hit: SessionSearchHit, watching: Bool) -> some View {
        let pinHovered = hoveredPinID == hit.record.id
        return Button {
            suppressNextRowAttach = true
            model.toggleWatchSearchHit(hit)
            recompute()
            DispatchQueue.main.async {
                suppressNextRowAttach = false
                fieldFocused = true
            }
        } label: {
            Image(systemName: watching ? "pin.fill" : "pin")
                .typoIcon(size: 11, .semibold)
                .foregroundStyle(watching ? model.theme.signatureColor : Color.secondary.opacity(0.82))
                .frame(width: 28, height: 24)
                .background(pinHovered ? model.theme.signatureColor.opacity(watching ? 0.20 : 0.12) : Color.clear, in: Circle())
                .overlay(
                    Circle()
                        .stroke(pinHovered ? model.theme.signatureColor.opacity(watching ? 0.62 : 0.42) : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .help(watching ? "Remove from Watching" : "Pin to Watching")
        .onHover { hovering in
            if hovering { hoveredPinID = hit.record.id }
            else if hoveredPinID == hit.record.id { hoveredPinID = nil }
        }
    }

    @ViewBuilder
    private func statusSlot(attached: Bool, watching: Bool) -> some View {
        if attached {
            Text("focused")
                .typoCaption(.semibold)
                .foregroundStyle(model.theme.signatureColor)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 48, alignment: .leading)
        } else if watching {
            Text("watching")
                .typoCaption(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 48, alignment: .leading)
        } else {
            Color.clear.frame(width: 48, height: 12)
        }
    }

    private func mostRecent(_ hits: [SessionSearchHit]) -> Date {
        hits.map(\.record.updatedAt).max() ?? .distantPast
    }

    private func projectName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "no project" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func selectTop() {
        if let first = hits.first { attach(first) }
    }

    private func attach(_ hit: SessionSearchHit) {
        model.attachToSearchHit(hit)
        isVisible = false
    }
}

enum EdgeHoverScrubberExclusion {
    private static let topOffsetFromBottom: CGFloat = 188
    private static let bottomOffsetFromBottom: CGFloat = 72

    static func contains(_ location: CGPoint, height: CGFloat, enabled: Bool) -> Bool {
        guard enabled, height > 0 else { return false }
        let minY = max(0, height - topOffsetFromBottom)
        let maxY = min(height, height - bottomOffsetFromBottom)
        return minY <= location.y && location.y <= maxY
    }
}

/// Left-edge rail that slides the session list out on hover and slides back when
/// the pointer leaves. `expanded` is bound out so the root view can hide content it
/// would otherwise overlap (the live hint pill).
struct SessionHoverRail: View {
    @ObservedObject var model: AppModel
    @Binding var expanded: Bool
    var scrubberHoverExclusionEnabled = false
    @State private var hoveredID: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                content
                    .frame(width: expanded ? 250 : 56, alignment: .leading)
                    .frame(maxHeight: .infinity)
                    .background {
                        if expanded {
                            // Match the command palette's dark material read without
                            // washing the base with the theme accent.
                            Rectangle().fill(railBaseColor)
                            if colorScheme == .light {
                                Rectangle().fill(.regularMaterial.opacity(0.92))
                            }
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if expanded {
                            Rectangle()
                                .fill(model.theme.signatureColor.opacity(0.28))
                                .frame(width: 1)
                        }
                    }
                    .clipped()
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        updateHoverExpansion(phase, height: proxy.size.height)
                    }
                Spacer(minLength: 0)
            }
        }
    }

    private func updateHoverExpansion(_ phase: HoverPhase, height: CGFloat) {
        switch phase {
        case .active(let location):
            let blocked = EdgeHoverScrubberExclusion.contains(
                location,
                height: height,
                enabled: !expanded && scrubberHoverExclusionEnabled
            )
            withAnimation(.easeInOut(duration: 0.18)) { expanded = !blocked }
            if blocked { hoveredID = nil }
        case .ended:
            withAnimation(.easeInOut(duration: 0.18)) { expanded = false }
            hoveredID = nil
        }
    }

    @ViewBuilder private var content: some View {
        if expanded {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("Watching")
                        .typoCaption(.semibold)
                    if model.watchedUnreadCount > 0 {
                        Text("\(model.watchedUnreadCount)")
                            .typoCaption(.bold, design: .rounded)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(model.theme.signatureColor.opacity(0.16), in: Capsule())
                    }
                    if let summary = model.fleetStateSummary {
                        Text("· \(summary)")
                            .typoCaption(.medium)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(model.theme.signatureColor.opacity(0.85))
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
                ScrollView {
                    VStack(spacing: 3) {
                        if model.attachedSessionList.isEmpty {
                            Text("No watched sessions. Press ⌘K and pin a session to watch it.")
                                .typoLabel()
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        ForEach(model.attachedSessionList) { session in
                            Button { model.focusCodexSession(session.id) } label: { row(session, hovered: hoveredID == session.id) }
                                .buttonStyle(.plain)
                                .onHover { hovering in
                                    if hovering { hoveredID = session.id }
                                    else if hoveredID == session.id { hoveredID = nil }
                                }
                        }
                    }
                    .padding(8)
                }
            }
        } else {
            // Collapsed: a wide (56pt) invisible hover zone with a thin handle
            // pinned to the very left edge, so the rail is easy to summon without
            // pixel-precision at the window edge.
            ZStack(alignment: .topTrailing) {
                Capsule()
                    .fill(model.theme.signatureColor.opacity(0.58))
                    .frame(width: 3, height: 40)
                    .shadow(color: model.theme.signatureColor.opacity(0.35), radius: 6)
                if model.watchedUnreadCount > 0 {
                    Text("\(model.watchedUnreadCount)")
                        .typoCaption(.bold, design: .rounded)
                        .monospacedDigit()
                        .foregroundStyle(model.theme.signatureColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(railBaseColor.opacity(0.95), in: Capsule())
                        .overlay(Capsule().stroke(model.theme.signatureColor.opacity(0.45)))
                        .offset(x: 21, y: -6)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 4)
        }
    }

    private func row(_ session: CodexSessionTarget, hovered: Bool) -> some View {
        let active = session.id == model.attachedCodexSessionID
        let voicemailCount = model.unreadCount(forSessionID: session.id)
        let attention = model.sessionAttention[session.id]
        return HStack(spacing: 8) {
            Circle()
                .fill(active ? model.theme.signatureColor : Color.secondary.opacity(0.45))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displaySessionTitle(forID: session.id, fallback: session.displayTitle))
                    .typoLabel(active ? .semibold : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let attention, let label = attention.shortLabel {
                    Text(label)
                        .typoCaption(attention.needsUser ? .semibold : .medium)
                        .foregroundStyle(statusColor(for: attention))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
            if voicemailCount > 0 {
                Text("\(voicemailCount)")
                    .typoCaption(.bold, design: .rounded)
                    .monospacedDigit()
                    .foregroundStyle(model.theme.signatureColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(model.theme.signatureColor.opacity(0.15), in: Capsule())
                    .help("\(voicemailCount) unheard voicemail\(voicemailCount == 1 ? "" : "s")")
            }
            SourceBadge(sourceKind: session.sourceKind.rawValue,
                        displayName: session.sourceKind.displayName)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(hovered ? model.theme.signatureColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .contextMenu {
            if !active {
                Button(model.voicemailMode ? "Focus this session" : "Go live on this session") { model.focusCodexSession(session.id) }
            }
            Button("Stop watching") { model.detachCodexSession(session.id) }
        }
    }

    private func statusColor(for state: SessionAttentionState) -> Color {
        if state.needsUser { return model.theme.signatureColor }
        switch state {
        case .erroredRecently: return .orange
        case .active: return .secondary
        default: return Color.secondary.opacity(0.7)
        }
    }

    private var railBaseColor: Color {
        if colorScheme == .dark {
            return Color(.sRGB, red: 17.0 / 255.0, green: 14.0 / 255.0, blue: 25.0 / 255.0, opacity: 1)
        }
        return Color(nsColor: .windowBackgroundColor)
    }
}
