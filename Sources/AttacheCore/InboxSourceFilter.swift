import Foundation

/// Pure chip-model for the Inbox source filter. The filter only offers sources
/// that actually have waiting cards, so a fleet running only Codex never shows a
/// Claude Code chip, and a future source appears the moment its first card
/// lands. Kept out of SwiftUI so the present/order logic is unit-testable and
/// stays in lockstep with `SessionCommandPalette.availableSources`.
public enum InboxSourceFilter {
    /// The sources to offer as filter chips, derived from the raw `sourceKind`
    /// values of the cards currently in scope. Returned in stable
    /// `SourceKind.allCases` order; an unrecognized raw value contributes no
    /// chip, and a source with no waiting card is omitted.
    public static func availableSources<S: Sequence>(fromCardSourceKinds rawValues: S) -> [SourceKind]
    where S.Element == String {
        let present = Set(rawValues.compactMap(SourceKind.init(rawValue:)))
        return SourceKind.allCases.filter { present.contains($0) }
    }
}
