import SwiftUI

/// Pure digit-to-row resolution for the palette's number-key switch (INF-365):
/// while the search field is empty, pressing 1-9 switches to the Nth visible
/// personality in the current (possibly filtered) list. Kept free of SwiftUI
/// state so it is unit-testable without a live view.
enum PersonalityDigitSwitch {
    static func resolve(digit: Int, visible: [Personality], searchIsEmpty: Bool) -> Personality? {
        guard searchIsEmpty, digit >= 1, digit <= 9 else { return nil }
        let index = digit - 1
        guard visible.indices.contains(index) else { return nil }
        return visible[index]
    }
}

/// Persistent, keyboard-first character picker. This intentionally shares the
/// command-palette contract instead of using a transient system popover: search
/// is focused on open, arrows move, Return switches, and Escape closes.
struct CharacterSwitcherPalette: View {
    @ObservedObject var model: AppModel
    @Binding var isVisible: Bool
    @Environment(\.attacheTextScale) private var textScale
    @State private var query = ""
    @State private var selectedID: String?
    @FocusState private var fieldFocused: Bool

    private var filtered: [Personality] {
        let terms = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return model.personalities }
        return model.personalities.filter { personality in
            let searchable = [
                personality.name,
                personality.presenceSummary,
                model.personalityVoiceName(personality),
                personality.modelSummary,
                personality.prompt,
                personality.isBuiltIn ? "built in" : "custom"
            ].joined(separator: " ")
            return terms.allSatisfy { searchable.localizedCaseInsensitiveContains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            characterList
            Divider()
            footer
        }
        .frame(width: 620 * textScale)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .readingPlate(theme: model.theme)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 28, y: 12)
        .background(PaletteKeyMonitor(
            onMove: moveSelection,
            onSelect: selectCurrent,
            onDigit: switchToVisibleRow,
            isFieldFocused: fieldFocused
        ))
        .onAppear {
            selectedID = model.activePersonalityID
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: query) { _ in normalizeSelection() }
        .onChange(of: model.personalities) { _ in normalizeSelection() }
        .onExitCommand { isVisible = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attaché switcher")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Switch Attaché").typoSection()
                    Text("Choose the personality, voice, presence, and model together.")
                        .typoCaption(.medium)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("⇧⌘P")
                    .typoCaption(.semibold, design: .monospaced)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search personalities", text: $query)
                    .textFieldStyle(.plain)
                    .typoBody(.medium)
                    .focused($fieldFocused)
                    .onSubmit(selectCurrent)
                    .accessibilityLabel("Search personalities")
                if !query.isEmpty {
                    Button {
                        query = ""
                        fieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.10)))
        }
        .padding(16)
    }

    private var characterList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if filtered.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .typoIcon(size: 22, .medium)
                            Text("No matches")
                                .typoBody(.semibold)
                            Text("Try a name, voice, presence, provider, or model.")
                                .typoCaption()
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 34)
                    } else {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, personality in
                            row(personality, hintNumber: index < 9 ? index + 1 : nil).id(personality.id)
                        }
                    }
                }
                .padding(7)
            }
            .frame(maxHeight: 410 * textScale)
            .onChange(of: selectedID) { id in
                if let id {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private func row(_ personality: Personality, hintNumber: Int? = nil) -> some View {
        let selected = selectedID == personality.id
        let active = model.activePersonalityID == personality.id
        return Button {
            switchTo(personality)
        } label: {
            HStack(spacing: 12) {
                if let hintNumber {
                    Text("\(hintNumber)")
                        .typoCaption(.semibold, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                        .help("Press \(hintNumber) to switch here. Works only while the search field is empty; digits filter the search when it has text.")
                } else {
                    Color.clear.frame(width: 14)
                }
                Text(personality.characterAvatarEmoji)
                    .font(.system(size: 25))
                    .frame(width: 38, height: 38)
                    .background(model.theme.signatureColor.opacity(selected ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(personality.name)
                            .typoBody(.semibold)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(personality.isBuiltIn ? "BUILT-IN" : "CUSTOM")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(active ? model.theme.signatureColor : .secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.065), in: Capsule())
                    }
                    Text("\(personality.presenceSummary) · \(model.personalityVoiceName(personality))")
                        .typoCaption(.medium)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(model.displayModelSummary(for: personality))
                        .typoCaption()
                        .foregroundStyle(.secondary.opacity(0.82))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if active {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .typoCaption(.semibold)
                        .foregroundStyle(model.theme.signatureColor)
                        .labelStyle(.titleAndIcon)
                } else if selected {
                    Image(systemName: "return")
                        .typoIcon(size: 11, .semibold)
                        .foregroundStyle(model.theme.signatureColor)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(selected ? model.theme.signatureColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { selectedID = personality.id }
        }
        .accessibilityLabel("Attaché \(personality.name)\(active ? ", active" : "")")
        .accessibilityValue("\(personality.presenceSummary), \(model.personalityVoiceName(personality)), \(model.displayModelSummary(for: personality))")
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label("Navigate", systemImage: "arrow.up.arrow.down")
            Label("Switch", systemImage: "return")
            if query.isEmpty {
                Label("1-9 jumps", systemImage: "number")
            }
            Label("Close", systemImage: "escape")
            Spacer()
            Button {
                isVisible = false
                AttacheNavigation.openPersonalityManager()
            } label: {
                Label("Edit personalities…", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.theme.signatureColor)
            .accessibilityLabel("Edit personalities")
        }
        .typoCaption(.medium)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    private func normalizeSelection() {
        guard !filtered.isEmpty else {
            selectedID = nil
            return
        }
        if selectedID == nil || !filtered.contains(where: { $0.id == selectedID }) {
            selectedID = filtered.first?.id
        }
    }

    private func moveSelection(_ delta: Int) {
        selectedID = PaletteSelectionIndex.move(current: selectedID, ids: filtered.map(\.id), delta: delta)
    }

    private func selectCurrent() {
        guard let id = selectedID ?? filtered.first?.id,
              let personality = filtered.first(where: { $0.id == id }) else { return }
        switchTo(personality)
    }

    /// Bare 1-9 while the search field is empty switches straight to that
    /// visible row and closes the palette. Returns whether the digit was
    /// consumed; when false the caller lets it type into the search field.
    private func switchToVisibleRow(_ digit: Int) -> Bool {
        guard query.isEmpty else { return false }
        if let personality = PersonalityDigitSwitch.resolve(digit: digit, visible: filtered, searchIsEmpty: true) {
            switchTo(personality)
        }
        return true
    }

    private func switchTo(_ personality: Personality) {
        model.switchPersonalityFromUI(personality.id)
        isVisible = false
    }
}
