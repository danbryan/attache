import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Manage companion personalities. Clicking a personality makes it active and
/// drops straight into editing it: prompt, voice, and pet together (INF-295).
struct PersonalitiesPane: View {
    @ObservedObject var model: AppModel
    @State private var draftName = ""
    @State private var draftPrompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Personalities").typoTitle()
                Spacer()
                Button { importPersonality() } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                Button { model.addPersonality() } label: {
                    Label("New", systemImage: "plus")
                }
            }

            Text("Each personality bundles a prompt, a voice, and a pet. Click one to make it active and edit it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $model.presentationLLMEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Use personality summary")
                    Text("On: rewrite updates with the selected personality. Off: read the session output verbatim from any source.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            VStack(spacing: 6) {
                ForEach(model.personalities) { personality in
                    row(personality)
                }
            }

            if let active = model.activePersonality {
                editor(for: active)
            }
        }
        .onAppear { reloadDraft() }
        .onChange(of: model.activePersonalityID) { _ in reloadDraft() }
    }

    private func row(_ personality: Personality) -> some View {
        let isActive = personality.id == model.activePersonalityID
        return HStack(spacing: 10) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            Text(personality.petAvatarEmoji)
            VStack(alignment: .leading, spacing: 1) {
                Text(personality.name).typoBody(.medium)
                HStack(spacing: 6) {
                    if personality.isBuiltIn {
                        Text("Built-in").typoCaption(.semibold).foregroundStyle(.secondary)
                    }
                    Text(personality.voiceSummary).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { exportPersonality(personality) } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("Export")
            Button { model.duplicatePersonality(id: personality.id) } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Duplicate")
            if !personality.isBuiltIn {
                Button(role: .destructive) {
                    model.deletePersonality(id: personality.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            isActive ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectPersonality(personality.id) }
    }

    private func editor(for personality: Personality) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.top, 4)
            HStack(spacing: 6) {
                Text("Editing \(personality.name)").typoBody(.semibold)
                if personality.isBuiltIn {
                    Text("Built-in").typoCaption(.semibold).foregroundStyle(.secondary)
                }
                Spacer()
                if hasChanges(personality) {
                    Text("Unsaved").font(.caption).foregroundStyle(.orange)
                }
            }
            TextField("Name", text: $draftName).textFieldStyle(.roundedBorder)
            TextEditor(text: $draftPrompt)
                .typoLabel(design: .monospaced)
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))

            // Pet and voice apply immediately to the active personality.
            HStack(spacing: 12) {
                Picker("Pet", selection: Binding(
                    get: { model.petCharacter },
                    set: { model.selectPetCharacter($0) }
                )) {
                    ForEach(BubblesPetCharacter.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                }
                .frame(maxWidth: 200)

                Picker("On-device voice", selection: Binding(
                    get: { model.speechProvider == .system ? (model.speechVoiceIdentifier ?? "") : "" },
                    set: { id in model.selectSpeechVoice(model.speechVoiceOptions.first { $0.id == id }) }
                )) {
                    Text("System default").tag("")
                    ForEach(model.speechVoiceOptions) { Text($0.title).tag($0.id) }
                }
            }
            Text("Voice: \(personality.voiceSummary). For ElevenLabs, xAI, or OpenAI voices, choose one in the Voice tab while this personality is active.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Revert") { reloadDraft() }
                    .disabled(!hasChanges(personality))
                Button("Save") {
                    model.updatePersonality(id: personality.id, name: draftName, prompt: draftPrompt)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges(personality))
            }
        }
    }

    private func hasChanges(_ personality: Personality) -> Bool {
        draftName != personality.name || draftPrompt != personality.prompt
    }

    private func reloadDraft() {
        guard let active = model.activePersonality else { return }
        draftName = active.name
        draftPrompt = active.prompt
    }

    private func exportPersonality(_ personality: Personality) {
        guard let data = model.exportPersonalityData(id: personality.id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(personality.name).json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private func importPersonality() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            model.importPersonality(from: data)
        }
    }
}
