import Foundation

/// Pure set math backing the History overlay's multi-select. Kept out of the
/// SwiftUI view so the toggle, select-all-visible, and clear-on-scope-change
/// rules can be unit-tested without a running app. Mirrors the inbox's inline
/// checked-set behavior, factored so History (permanent delete) can lean on the
/// same, tested rules.
public enum HistorySelection {
    /// Add `id` if absent, remove it if present.
    public static func toggle(_ id: String, in selection: Set<String>) -> Set<String> {
        var next = selection
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        return next
    }

    /// Check every currently visible id, keeping any prior selection.
    public static func selectAll(visible ids: [String], in selection: Set<String>) -> Set<String> {
        selection.union(ids)
    }

    /// Drop any checked id that is no longer visible (scope, kind-filter, or
    /// search change, or a card that was just deleted), so a stale check can
    /// never target something off screen.
    public static func retaining(_ selection: Set<String>, visible ids: [String]) -> Set<String> {
        selection.intersection(ids)
    }

    /// The delete target for a bulk action: the checked-and-visible ids, or, if
    /// nothing is checked, the focused row on its own (Command-delete
    /// ergonomics). Empty when neither applies.
    public static func deletionTargets(
        checked selection: Set<String>,
        visible ids: [String],
        focused focusedID: String?
    ) -> [String] {
        let checkedVisible = ids.filter { selection.contains($0) }
        if !checkedVisible.isEmpty { return checkedVisible }
        if let focusedID, ids.contains(focusedID) { return [focusedID] }
        return []
    }
}
