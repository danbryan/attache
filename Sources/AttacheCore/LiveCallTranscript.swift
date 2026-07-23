import Foundation

/// Who spoke a live-call turn. Distinct from `AttacheDirectChatTurn.Role` so the
/// running-transcript UI (INF combination "B + A") has a pure, App-independent
/// model to render and test without importing the app's `ConversationTurn`.
public enum LiveCallSpeaker: String, Equatable, Sendable {
    case user
    case attache

    /// A short speaker cue for the transcript row and the pinned last-turn card.
    public var cue: String {
        switch self {
        case .user: return "You"
        case .attache: return "Attaché"
        }
    }
}

/// One entry in the running live-call transcript. Derived from the app's
/// in-memory conversation turns; it is never a new persistence store. An
/// Attaché entry that was saved to History carries the replayable card id so
/// the panel's per-turn replay control can drive the standard playback path.
/// A private call still produces entries in memory (so the thread is visible
/// during the call) but its Attaché entries carry no `replayCardID`, because a
/// private call writes no cards.
public struct LiveCallTranscriptEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let speaker: LiveCallSpeaker
    public let text: String
    public let replayCardID: String?

    public init(id: String, speaker: LiveCallSpeaker, text: String, replayCardID: String? = nil) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.replayCardID = replayCardID
    }

    public var isReplayable: Bool { replayCardID != nil }
}

/// Pure projection over an ordered list of live-call entries (oldest first).
/// Everything the transcript panel and the pinned last-turn card need is a
/// derived, side-effect-free computation here, so it can be unit tested without
/// SwiftUI: order, the newest-entry auto-scroll target, the pinned latest
/// Attaché turn, the "N earlier" count, and which entry is currently spoken.
public struct LiveCallTranscript: Equatable, Sendable {
    public let entries: [LiveCallTranscriptEntry]

    public init(entries: [LiveCallTranscriptEntry] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Auto-scroll target: the newest turn as it arrives. The panel scrolls to
    /// this so a new turn is never below the fold (the fixed-viewport complaint
    /// this feature avoids).
    public var newestEntryID: String? { entries.last?.id }

    /// The most recent Attaché turn, shown on the persistent bottom "last turn"
    /// card so it never vanishes when narration finishes. It is Attaché's latest
    /// even if the user has since typed a newer turn.
    public var pinnedEntry: LiveCallTranscriptEntry? {
        entries.last { $0.speaker == .attache }
    }

    public var pinnedText: String? { pinnedEntry?.text }

    /// Count of turns that come before the pinned Attaché turn, for the chevron's
    /// "N earlier" affordance. Zero when the pinned turn is the first turn or
    /// there is no Attaché turn yet.
    public var earlierTurnCount: Int {
        guard let pinnedID = pinnedEntry?.id,
              let index = entries.firstIndex(where: { $0.id == pinnedID }) else { return 0 }
        return index
    }

    /// The entry that matches what is being spoken right now, so the panel can
    /// highlight it. Positional and text-based: the latest Attaché entry whose
    /// text equals the currently spoken text. Nil when nothing matches or
    /// playback is idle.
    public func speakingEntryID(spokenText: String, isPlaying: Bool) -> String? {
        guard isPlaying else { return nil }
        let needle = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        return entries.last {
            $0.speaker == .attache
                && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == needle
        }?.id
    }
}

/// Open/pin/peek state for the running-transcript side panel. Pinned is a
/// persisted preference that keeps the panel open across turns AND across calls;
/// peeking is a transient, this-call-only open that never persists. Opening from
/// the chevron, context menu, or shortcut is a peek by default; only the pin
/// toggle makes it durable.
public struct TranscriptPanelPresentation: Equatable, Sendable {
    /// Persisted preference (default off). Keeps the panel open across turns and
    /// across calls until the user unpins it.
    public var pinned: Bool
    /// Transient, this-call-only open. Never persisted; cleared at hang-up.
    public var peeking: Bool

    public init(pinned: Bool = false, peeking: Bool = false) {
        self.pinned = pinned
        self.peeking = peeking
    }

    public var isOpen: Bool { pinned || peeking }

    /// Chevron / context-menu / "Show conversation": a peek open. Never changes
    /// the persisted pin.
    public mutating func openPeek() {
        peeking = true
    }

    /// Keyboard shortcut: flip the panel's visibility outright. Closing a pinned
    /// panel this way also unpins it, so a deliberate close is not silently
    /// reopened on the next call.
    public mutating func toggleShortcut() {
        if isOpen {
            pinned = false
            peeking = false
        } else {
            peeking = true
        }
    }

    /// Thumbtack in the header. Pinning supersedes and clears the transient peek;
    /// unpinning drops the panel to closed unless a peek is separately requested.
    public mutating func setPinned(_ value: Bool) {
        pinned = value
        if value { peeking = false }
    }

    /// Hang-up is a context boundary: the transient peek never survives it. The
    /// persisted pin does, matching "pinned stays open across calls".
    public mutating func callEnded() {
        peeking = false
    }
}
