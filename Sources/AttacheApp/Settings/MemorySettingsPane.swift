import AttacheCore
import SwiftUI

struct MemorySettingsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: AttacheContextUIState

    @State private var confirmDeleteAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Memory").typoTitle()
                Text("Attaché saves a memory only when you ask it to remember something. Nothing is noticed or suggested automatically. Saved memories stay on this Mac unless you say otherwise.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            modeSection

            storedSection

            HStack(spacing: 10) {
                Button("Import…") { model.importStructuredMemory() }
                    .accessibilityLabel("Import structured memory")
                Button("Export…") { model.exportStructuredMemory() }
                    .disabled(state.memoryRecords.isEmpty)
                    .accessibilityLabel("Export structured memory")
                Button("Open legacy memory file") { model.openAttacheMemoryFile() }
                    .help("Open the older free-form memory file. Structured memories above are stored separately.")
                Spacer()
                Button("Delete all structured memory", role: .destructive) {
                    confirmDeleteAll = true
                }
                .disabled(state.memoryRecords.isEmpty)
                .accessibilityLabel("Delete all structured memory")
            }

            if let message = state.memoryStatusMessage {
                Label(message, systemImage: "checkmark.circle")
                    .typoCaption()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Memory status: \(message)")
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .confirmationDialog(
            "Delete all structured memory?",
            isPresented: $confirmDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete all memory", role: .destructive) { state.deleteAllMemory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes saved memories from this Mac. It does not delete agent session transcripts.")
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Remembering").typoSection()
            Picker("Remembering", selection: modeBinding) {
                Text("Off").tag(AttacheMemoryProposalMode.off)
                Text("On").tag(AttacheMemoryProposalMode.on)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Memory mode")
            .accessibilityValue(memoryModeTitle(state.memoryMode))

            Text(memoryModeExplanation(state.memoryMode))
                .typoCaption()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                "Memory stays local by default. A saved item marked Local only is never sent to a cloud model.",
                systemImage: "lock.shield.fill"
            )
            .typoCaption()
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Memory capture settings")
    }

    private var storedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Saved on this Mac").typoSection()
                Spacer()
                if state.recentlyForgottenMemory != nil {
                    Button("Undo forget") { state.undoLastForget() }
                        .buttonStyle(.borderless)
                        .keyboardShortcut("z", modifiers: [.command])
                        .accessibilityLabel("Undo last forgotten memory")
                }
                Text("\(state.memoryRecords.count) saved")
                    .typoCaption(.medium, monoDigit: true)
                    .foregroundStyle(.secondary)
            }

            if state.memoryRecords.isEmpty {
                emptyCard(
                    icon: "tray",
                    title: "No structured memories yet",
                    detail: state.memoryMode == .off
                        ? "Remembering is Off. Attaché will not save new memories."
                        : "Memories you ask Attaché to remember will be listed here with their scope and privacy policy."
                )
            } else {
                ForEach(state.memoryRecords, id: \.id) { record in
                    MemoryRecordRow(record: record, state: state)
                }
            }
        }
    }

    private func emptyCard(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).typoBody(.semibold)
                Text(detail).typoCaption().foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private var modeBinding: Binding<AttacheMemoryProposalMode> {
        Binding(get: { state.memoryMode }, set: { state.setMemoryMode($0) })
    }
}

private struct MemoryRecordRow: View {
    let record: AttacheMemoryRecord
    @ObservedObject var state: AttacheContextUIState

    @State private var editing = false
    @State private var statement: String
    @State private var confirmRemoteEgress = false

    init(record: AttacheMemoryRecord, state: AttacheContextUIState) {
        self.record = record
        self.state = state
        _statement = State(initialValue: record.statement)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(memoryTypeTitle(record.type)).typoLabel(.semibold)
                Spacer()
                Text(memoryScopeTitle(record.scope)).typoCaption(.medium).foregroundStyle(.secondary)
            }

            if editing {
                TextField("Memory", text: $statement, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
                    .accessibilityLabel("Edit saved memory")
            } else {
                Text(record.statement)
                    .typoBody()
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Label(memorySourceTitle(record.sourceKind), systemImage: "link")
                Label(memoryEgressTitle(record.egress), systemImage: record.egress == .localOnly ? "lock.fill" : "cloud")
                if record.sensitivity != .low {
                    Label(record.sensitivity.rawValue.capitalized, systemImage: "hand.raised.fill")
                }
            }
            .typoCaption()
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if editing {
                    Button("Save edit") {
                        state.editMemory(id: record.id, statement: statement)
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Cancel") {
                        statement = record.statement
                        editing = false
                    }
                } else {
                    Button("Edit") { editing = true }
                }
                if record.egress == .localOnly {
                    Button("Allow active model") { confirmRemoteEgress = true }
                        .accessibilityLabel("Allow this memory to be sent to the active model")
                } else {
                    Button("Make local only") {
                        state.setMemoryEgress(id: record.id, egress: .localOnly)
                    }
                    .accessibilityLabel("Keep this memory local only")
                }
                Spacer(minLength: 0)
                Button("Forget", role: .destructive) { state.forgetMemory(id: record.id) }
                    .accessibilityLabel("Forget saved memory")
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved \(memoryTypeTitle(record.type)) memory")
        .confirmationDialog(
            "Allow the active model to use this memory?",
            isPresented: $confirmRemoteEgress,
            titleVisibility: .visible
        ) {
            Button("Allow active model") {
                state.setMemoryEgress(id: record.id, egress: .allowedRemote)
            }
            Button("Keep local only", role: .cancel) {}
        } message: {
            Text("When relevant, the memory text may be included in a request to the model configured for this personality, including a remote provider.")
        }
    }
}

private func memoryModeTitle(_ mode: AttacheMemoryProposalMode) -> String {
    switch mode {
    case .off: return "Off"
    case .on: return "On"
    }
}

private func memoryModeExplanation(_ mode: AttacheMemoryProposalMode) -> String {
    switch mode {
    case .off:
        return "Attaché does not save new memories. Existing saved items remain available until you forget them."
    case .on:
        return "Say \"remember\" in a call or chat and Attaché saves it after a local safety check. Nothing is saved without an explicit ask."
    }
}

private func memoryTypeTitle(_ type: AttacheMemoryType) -> String {
    switch type {
    case .userFact: return "Personal fact"
    case .preference: return "Preference"
    case .standingInstruction: return "Standing instruction"
    case .relationship: return "Relationship"
    case .projectTopic: return "Project topic"
    case .reminder: return "Reminder"
    }
}

private func memoryScopeTitle(_ scope: AttacheMemoryScope) -> String {
    switch scope {
    case .global: return "All personalities"
    case .personality: return "This personality"
    case .topic: return "This topic"
    }
}

private func memorySourceTitle(_ source: AttacheMemorySourceKind) -> String {
    switch source {
    case .userConfirmed: return "You confirmed"
    case .userAuthored: return "You added"
    case .imported: return "Imported"
    case .modelProposed: return "Attaché suggested"
    }
}

private func memoryEgressTitle(_ egress: AttacheMemoryEgress) -> String {
    switch egress {
    case .localOnly: return "Local only"
    case .allowedRemote: return "May be sent to active model"
    }
}
