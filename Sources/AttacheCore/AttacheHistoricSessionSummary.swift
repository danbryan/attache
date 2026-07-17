import Foundation

/// Pure, content-free authorization check for INF-370 "Summarize Session…".
/// Invoking the action IS the explicit user selection (INF-315): the caller
/// must already hold an `AttacheFocusGrant` for the exact session before any
/// transcript byte is read. This function performs no I/O, so a test can
/// prove the fail-closed path never opens a file by exercising this function
/// alone and asserting the failure case.
public enum AttacheHistoricSessionSummaryAuthorizer {
    public enum AuthorizationError: Error, Equatable {
        /// No focus grant was presented at all (never picked, or invalidated).
        case noFocusGrant
        /// A grant exists but does not match the requested session/source, or
        /// its epoch does not match the grant's own epoch (a stale grant).
        case sessionMismatch
    }

    /// Authorize a summarize request against a focus grant. Returns the
    /// authorized `AttacheFocusedSession` on success, or a typed failure that
    /// callers must treat as fail-closed (no transcript read attempted).
    public static func authorize(
        requestedSessionID: String,
        requestedSourceKind: String,
        grant: AttacheFocusGrant?
    ) -> Result<AttacheFocusedSession, AuthorizationError> {
        guard let grant else { return .failure(.noFocusGrant) }
        guard grant.session.sessionID == requestedSessionID,
              grant.session.sourceKind == requestedSourceKind,
              grant.session.authorizationEpoch == grant.epoch else {
            return .failure(.sessionMismatch)
        }
        return .success(grant.session)
    }
}

/// Content-free spoken-language rules for exhaustive-review-backed summaries
/// (INF-370 step 6). Reuses `AttacheReviewOverallStatus`'s complete/incomplete
/// contract (INF-329): a summary may only claim full coverage when the ledger
/// is actually complete. Partial or canceled runs must say so out loud and in
/// the persisted card text, never silently.
public enum AttacheSessionSummaryLanguage {
    /// `nil` only when the review reached full, uninterrupted coverage.
    public static func incompletenessNotice(
        status: AttacheReviewOverallStatus,
        coveragePercentage: Double
    ) -> String? {
        let percent = Int((coveragePercentage * 100).rounded())
        switch status {
        case .complete:
            return nil
        case .canceled:
            return "This summary covers part of the session. The review was canceled at \(percent) percent coverage."
        case .stale:
            return "This summary covers part of the session. The source changed while reviewing, so coverage is stale."
        case .incomplete, .inProgress:
            return "This summary covers part of the session, at \(percent) percent coverage."
        }
    }

    /// Assemble the raw source text handed to the synthesis prompt: the
    /// staged summaries plus, when coverage is not complete, an explicit
    /// incompleteness notice appended (never dropped, never averaged away).
    public static func assembleSourceText(
        stageSummaries: [String],
        status: AttacheReviewOverallStatus,
        coveragePercentage: Double
    ) -> String {
        var text = stageSummaries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if let notice = incompletenessNotice(status: status, coveragePercentage: coveragePercentage) {
            text += text.isEmpty ? notice : "\n\n\(notice)"
        }
        return text
    }
}
