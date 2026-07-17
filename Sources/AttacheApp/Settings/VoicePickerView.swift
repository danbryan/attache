import SwiftUI

/// The personality studio's voice picker (INF-352): a search-and-filter list
/// modeled on the macOS System Settings voice picker, embedded in the studio
/// sheet as its own sheet (not a global Cmd-K style palette; voice choice
/// belongs to the personality editor). Covers System, Grok (xAI), and OpenAI
/// voices; ElevenLabs keeps the pre-existing per-engine picker in
/// `PersonalitiesPane`.
struct VoicePickerView: View {
    @ObservedObject var model: AppModel
    var currentEngine: AttacheSpeechProvider
    var currentSystemVoiceID: String?
    var currentXAIVoiceID: String?
    var currentOpenAIVoiceID: String?
    var onSelect: (VoicePickerEntry) -> Void
    var onClose: () -> Void

    @Environment(\.attacheTextScale) private var textScale
    @State private var filterState = VoicePickerFilterState()
    @State private var previewingID: String?

    private var userLanguageCode: String {
        Locale.preferredLanguages.first?.components(separatedBy: "-").first?.lowercased() ?? "en"
    }

    private var result: VoicePickerResult {
        VoicePickerFilter.result(
            systemOptions: model.speechVoiceOptions,
            xaiOptions: model.xaiVoiceOptions,
            openaiOptions: model.openaiVoiceOptions,
            state: filterState,
            userLanguageCode: userLanguageCode
        )
    }

    private var availableLanguages: [(code: String, name: String)] {
        VoicePickerFilter.availableLanguages(
            systemOptions: model.speechVoiceOptions,
            xaiOptions: model.xaiVoiceOptions,
            openaiOptions: model.openaiVoiceOptions,
            userLanguageCode: userLanguageCode
        )
    }

    private var selectedVoiceID: String? {
        switch currentEngine {
        case .system: return currentSystemVoiceID
        case .xai: return currentXAIVoiceID
        case .openai: return currentOpenAIVoiceID
        case .elevenLabs: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filters
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 620 * textScale, height: 560 * textScale)
        .attacheTextScale(textScale)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice picker")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose a voice").typoSection()
                    Text("Search, filter by engine and quality, and preview before you pick.")
                        .typoCaption(.medium)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search voices or languages", text: $filterState.searchText)
                    .textFieldStyle(.plain)
                    .typoBody(.medium)
                    .accessibilityLabel("Search voices")
                if !filterState.searchText.isEmpty {
                    Button {
                        filterState.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear voice search")
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.10)))
        }
        .padding(16)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Engine").typoCaption(.medium).foregroundStyle(.secondary)
                ForEach([AttacheSpeechProvider.system, .xai, .openai], id: \.self) { engine in
                    engineChip(engine)
                }
                Spacer()
                languageMenu
            }
            HStack(spacing: 8) {
                Text("Quality").typoCaption(.medium).foregroundStyle(.secondary)
                ForEach(VoicePickerQuality.allCases) { quality in
                    qualityChip(quality)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func engineChip(_ engine: AttacheSpeechProvider) -> some View {
        let selected = filterState.engines.contains(engine)
        return Button {
            toggleEngine(engine)
        } label: {
            Text(engineChipTitle(engine))
                .typoCaption(.semibold)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selected ? model.theme.signatureColor.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(selected ? model.theme.signatureColor.opacity(0.5) : Color.primary.opacity(0.08)))
        .accessibilityLabel("Engine filter \(engineChipTitle(engine))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Grok (xAI) copy matches the label convention the settings pane uses
    /// elsewhere for this engine (`AttacheSpeechProvider.title` is "xAI";
    /// the ticket calls out "Grok(xai)" explicitly as the chip label).
    private func engineChipTitle(_ engine: AttacheSpeechProvider) -> String {
        switch engine {
        case .system: return "System"
        case .xai: return "Grok"
        case .openai: return "OpenAI"
        case .elevenLabs: return "ElevenLabs"
        }
    }

    private func toggleEngine(_ engine: AttacheSpeechProvider) {
        if filterState.engines.contains(engine) {
            guard filterState.engines.count > 1 else { return }
            filterState.engines.remove(engine)
        } else {
            filterState.engines.insert(engine)
        }
    }

    private func qualityChip(_ quality: VoicePickerQuality) -> some View {
        let enabled = filterState.engines.contains(.system)
        let selected = filterState.qualities.contains(quality)
        return Button {
            toggleQuality(quality)
        } label: {
            Text(quality.title).typoCaption(.semibold)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selected && enabled ? model.theme.signatureColor.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(selected && enabled ? model.theme.signatureColor.opacity(0.5) : Color.primary.opacity(0.08)))
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
        .accessibilityLabel("Quality filter \(quality.title)")
        .accessibilityAddTraits(selected && enabled ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(enabled ? "" : "Enable the System engine filter to use quality filters")
    }

    private func toggleQuality(_ quality: VoicePickerQuality) {
        if filterState.qualities.contains(quality) {
            guard filterState.qualities.count > 1 else { return }
            filterState.qualities.remove(quality)
        } else {
            filterState.qualities.insert(quality)
        }
    }

    private var languageMenu: some View {
        Menu {
            Button("All") { filterState.languageCode = nil }
            Divider()
            ForEach(availableLanguages, id: \.code) { language in
                Button(language.name) { filterState.languageCode = language.code }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedLanguageLabel)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
            .typoCaption(.medium)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Language filter")
        .accessibilityValue(selectedLanguageLabel)
    }

    private var selectedLanguageLabel: String {
        guard let code = filterState.languageCode, !code.isEmpty else { return "All" }
        return availableLanguages.first { $0.code == code }?.name ?? VoicePickerFilter.languageName(for: code)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if result.recommended.isEmpty, result.groups.allSatisfy({ $0.entries.isEmpty }) {
                    emptyState
                } else {
                    if !result.recommended.isEmpty {
                        sectionHeader("Recommended")
                        ForEach(result.recommended) { entry in
                            row(entry)
                        }
                    }
                    ForEach(result.groups) { group in
                        if !group.entries.isEmpty {
                            sectionHeader(group.languageName)
                            ForEach(group.entries) { entry in
                                row(entry)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .typoIcon(size: 22, .medium)
            Text("No matching voices")
                .typoBody(.semibold)
            Text("Try a different search, engine, quality, or language.")
                .typoCaption()
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .typoCaption(.bold)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    /// Two independent AX-addressable controls per row, deliberately not
    /// merged with `.accessibilityElement(children: .combine)`: selecting a
    /// voice and previewing it are different actions with different safety
    /// properties (selection can trigger cloud consent; preview speaks
    /// audio), and automation (and VoiceOver) must be able to reach both
    /// separately rather than have one swallow the other's identity.
    private func row(_ entry: VoicePickerEntry) -> some View {
        let selected = entry.engine == currentEngine && entry.voiceID == selectedVoiceID
        let previewDisabled = entry.engine.sendsToCloud
            && !model.cloudVoiceConsentAcknowledged(for: entry.engine, xaiBaseURL: model.xaiBaseURL)

        return HStack(spacing: 10) {
            Button {
                onSelect(entry)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(entry.name).typoBody(.semibold)
                            if let quality = entry.quality {
                                Text(quality.title)
                                    .typoCaption(.bold)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.07), in: Capsule())
                            }
                        }
                        Text(entry.languageName)
                            .typoCaption()
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(model.theme.signatureColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voice \(entry.name), \(entry.languageName)\(selected ? ", selected" : "")")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)

            Button {
                previewingID = entry.id
                model.previewVoiceSample(for: voiceRef(for: entry))
            } label: {
                Image(systemName: "play.circle")
                    .typoIcon(size: 18)
            }
            .buttonStyle(.plain)
            .disabled(previewDisabled)
            .help(previewDisabled ? "Enable \(entry.engine.title) in Integrations to preview this voice" : "Play a sample")
            .accessibilityLabel("Play sample of \(entry.name)")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(selected ? model.theme.signatureColor.opacity(0.12) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
    }

    private func voiceRef(for entry: VoicePickerEntry) -> PersonalityVoiceRef {
        switch entry.engine {
        case .system:
            return .systemVoice(entry.voiceID)
        case .xai:
            return PersonalityVoiceRef(provider: .xai, xaiVoiceID: entry.voiceID, xaiVoiceName: entry.name)
        case .openai:
            return PersonalityVoiceRef(provider: .openai, openaiVoiceID: entry.voiceID, openaiVoiceName: entry.name)
        case .elevenLabs:
            return PersonalityVoiceRef(provider: .elevenLabs)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(result.groups.reduce(0) { $0 + $1.entries.count }) voices")
                .typoCaption()
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
