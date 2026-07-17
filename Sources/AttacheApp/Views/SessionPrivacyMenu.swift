import SwiftUI

/// Pending "Forget This Session…" confirmation (INF-357). Carries the real
/// counts the confirmation dialog states, computed at the moment the menu
/// item was chosen so the copy never lies about what will be removed.
struct SessionForgetRequest: Identifiable, Equatable {
    let id = UUID()
    let sessionID: String
    let title: String
    let cardCount: Int
    let indexCount: Int

    static func == (lhs: SessionForgetRequest, rhs: SessionForgetRequest) -> Bool {
        lhs.id == rhs.id
    }
}

/// The two per-session privacy actions (INF-357), shared by every session row
/// context menu: the inbox row, the Command-K result row, and the Voicemail
/// control's Option alternate. Drop this inside any `.contextMenu { }`.
struct SessionPrivacyMenuItems: View {
    @ObservedObject var model: AppModel
    let sessionID: String
    let title: String
    @Binding var pendingForget: SessionForgetRequest?

    var body: some View {
        Toggle(
            "Don't Record This Session",
            isOn: Binding(
                get: { model.isSessionRecordingDisabled(sessionID: sessionID) },
                set: { model.setSessionDoNotRecord($0, sessionID: sessionID) }
            )
        )
        Button("Forget This Session…", role: .destructive) {
            let counts = model.forgetSessionImpactCounts(externalSessionID: sessionID)
            pendingForget = SessionForgetRequest(
                sessionID: sessionID,
                title: title,
                cardCount: counts.cards,
                indexCount: counts.indexEntries
            )
        }
    }
}

/// A small glyph shown on a "do not record" session's row, with the AX label
/// the ticket requires. Purely presentational; callers gate visibility on
/// `model.isSessionRecordingDisabled(sessionID:)`.
struct SessionNotRecordedGlyph: View {
    var body: some View {
        Image(systemName: "eye.slash.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .help("Not recorded")
            .accessibilityLabel("Not recorded")
    }
}

extension View {
    /// Attach once per screen that offers "Forget This Session…"; presents the
    /// real-count confirmation dialog and performs the scrub on confirm.
    func sessionForgetConfirmation(model: AppModel, request: Binding<SessionForgetRequest?>) -> some View {
        confirmationDialog(
            request.wrappedValue.map { "Forget “\($0.title)”?" } ?? "Forget this session?",
            isPresented: Binding(
                get: { request.wrappedValue != nil },
                set: { isPresented in if !isPresented { request.wrappedValue = nil } }
            ),
            presenting: request.wrappedValue
        ) { pending in
            Button("Forget Session", role: .destructive) {
                model.forgetSession(externalSessionID: pending.sessionID)
                request.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) {
                request.wrappedValue = nil
            }
        } message: { pending in
            Text("Removes \(pending.cardCount) card\(pending.cardCount == 1 ? "" : "s") and all search index entries for this session.")
        }
    }
}
