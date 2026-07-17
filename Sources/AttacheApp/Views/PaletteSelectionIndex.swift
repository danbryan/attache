import Foundation

/// Pure selection-index arithmetic shared by every palette/overlay that
/// mirrors arrow-key movement over an ordered, possibly-filtered id list
/// (⇧⌘P character switcher, ⌘I inbox, ⌘Y history; INF-365 j/k navigation).
/// Kept free of SwiftUI state so the "does j/k move like the arrows"
/// contract is unit-testable without a live view.
enum PaletteSelectionIndex {
    /// Moves the current selection by `delta` (typically -1 or +1) within
    /// `ids`, clamping at both ends. With no current selection, a downward
    /// move (`delta >= 0`) lands on the first id and an upward move lands
    /// on the last, matching how arrow keys behave from an empty selection.
    static func move(current: String?, ids: [String], delta: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return delta >= 0 ? ids.first : ids.last
        }
        let next = min(max(index + delta, 0), ids.count - 1)
        return ids[next]
    }
}
