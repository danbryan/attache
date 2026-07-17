import AppKit
import AttacheCore
import Foundation

/// Actions backing the bottom dock's right-click context menus (INF-354):
/// Settings pane deep-links, Voicemail quick actions, and Call-as-personality.
/// Kept separate from the (very large) `AppModel.swift` so the new surface is
/// easy to find and test in isolation.
extension AppModel {
    /// Plays a spoken recap of everything currently waiting, backing the
    /// dock's Voicemail "Play Recap" item (the same set `InboxOverlay`'s
    /// "Play recap" button summarizes).
    func playInboxRecapForAllUnread() {
        playInboxRecap(for: scopedUnreadCards)
    }

    /// Plays the single most recent card in the inbox (newest-first order,
    /// the same ordering `reloadCards()` uses to default-select a card).
    /// A no-op with nothing to play, exactly like every other dock action
    /// that requires an unread card.
    func playLatestCard() {
        guard let card = cards.first else { return }
        playInboxCard(card)
    }

    /// Reveals the app's Application Support directory in Finder, the
    /// destination for the dock's Option-held "Open Support Folder" item.
    func openSupportFolder() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let base else { return }
        let url = base.appendingPathComponent("Attache", isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Switches to `personalityID` then starts a normal (saved) call, backing
    /// the dock's "Call as…" submenu items.
    func startCall(as personalityID: String) {
        switchPersonalityFromUI(personalityID)
        startCall()
    }

    /// Switches to `personalityID` then starts a private call, backing the
    /// Option-held "Call as…" submenu items.
    func startPrivateCall(as personalityID: String) {
        switchPersonalityFromUI(personalityID)
        startPrivateCall()
    }
}
