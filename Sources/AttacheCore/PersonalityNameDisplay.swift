import Foundation

/// Pure display helper for showing an authoring personality's name as a small
/// row label (History overlay's generic-source case). Kept out of the SwiftUI
/// view so the trim/empty/truncate rules can be unit-tested without a running
/// app. The full name always remains available to VoiceOver; only the visible
/// chip is shortened.
public enum PersonalityNameDisplay {
    /// The visible label for a personality name, or nil when there is nothing
    /// worth showing (missing or whitespace-only). A name longer than `limit`
    /// is clipped and suffixed with a single-character ellipsis so the chip
    /// stays compact next to the row's other small labels.
    public static func label(for rawName: String?, limit: Int = 12) -> String? {
        guard let trimmed = rawName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        guard limit > 0, trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}
