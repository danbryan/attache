import Foundation

/// Occasional one-line feature tips (INF-193). Deliberately unintrusive: at
/// most one tip per launch, each tip shown once ever, delivered through the
/// existing home-notice chip, with a single off switch. No popovers, no
/// tours, nothing modal.
struct AttacheTip: Identifiable {
    let id: String
    let text: String

    static let all: [AttacheTip] = [
        AttacheTip(
            id: "history-replay",
            text: "Tip: ⌘Y replays anything you've already heard, even after clearing the inbox."
        ),
        AttacheTip(
            id: "speed-keys",
            text: "Tip: while a recap plays, S slows it down, D speeds it up, R resets."
        ),
        AttacheTip(
            id: "idle-right-click",
            text: "Tip: right-click the center logo to change what the idle screen shows."
        ),
        AttacheTip(
            id: "inbox-collapse",
            text: "Tip: click a session header in the inbox to collapse its cards."
        ),
        AttacheTip(
            id: "source-filter",
            text: "Tip: the filter beside the inbox search narrows to Codex or Claude Code."
        ),
        AttacheTip(
            id: "focus-button",
            text: "Tip: the link button in the dock shows what's watched; it turns into an alert when an agent needs you."
        )
    ]
}

/// Tracks which tips were shown and picks at most one unseen tip per launch.
final class AttacheTipEngine {
    private let defaults: UserDefaults
    private static let seenKey = "attache.seenTips"
    private var offeredThisLaunch = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var seen: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.seenKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Self.seenKey) }
    }

    /// The next tip to show, or nil when one was already offered this launch
    /// or everything has been seen. Marks the returned tip as seen.
    func nextTip() -> AttacheTip? {
        guard !offeredThisLaunch else { return nil }
        guard let tip = AttacheTip.all.first(where: { !seen.contains($0.id) }) else { return nil }
        offeredThisLaunch = true
        seen.insert(tip.id)
        return tip
    }

    /// For tests and the settings reset affordance.
    func resetSeen() {
        defaults.removeObject(forKey: Self.seenKey)
        offeredThisLaunch = false
    }
}
