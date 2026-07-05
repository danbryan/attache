import SwiftUI

/// Manage companion personalities. Clicking a personality makes it active and
/// drops straight into editing it; one prompt defines each one.
struct PersonalitiesPane: View {
    @ObservedObject var model: AppModel
    @State private var draftName = ""
    @State private var draftPrompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Personalities").typoTitle()
                Spacer()
                Button {
                    model.addPersonality()
                } label: {
                    Label("New", systemImage: "plus")
                }
            }

            Text("One prompt defines each personality's tone, attitude, detail, and language. Click one to make it active and edit it.")
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
            VStack(alignment: .leading, spacing: 1) {
                Text(personality.name).typoBody(.medium)
                if personality.isBuiltIn {
                    Text("Built-in").typoCaption(.semibold).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                model.duplicatePersonality(id: personality.id)
            } label: {
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
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
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
}
