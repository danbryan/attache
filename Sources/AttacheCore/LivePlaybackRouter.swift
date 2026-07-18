import Foundation

/// The routing decision for an incoming agent update: where it goes the instant
/// it arrives. Pure and deterministic so the branch that decides "speak now vs
/// wait in line vs land unread" is unit-testable and cannot drift between the
/// intake path and the drain path (INF-374).
public enum LivePlaybackRouting: String, Equatable {
    /// Speak it immediately (with the normal audio cue). The player is free.
    case playNow
    /// It belongs to the live call, but audio is busy, so it queues to auto-play
    /// next in arrival order. It is NOT unread voicemail.
    case queueNext
    /// File it as an unread inbox voicemail. Off-call, or from a session that is
    /// not the call's frozen target, or an explicit do-not-disturb surface.
    case voicemail
}

/// Decides how an incoming update is routed while (or while not) on a live call.
///
/// This is the single authority for the live-vs-voicemail choice. It exists as
/// a pure function so the three INF-374 regressions cannot recur:
///   1. a follow-up update arriving mid-speech must queue and play next, never
///      fall through to unread voicemail;
///   2. no stale UI classification of the focused session may divert a live
///      call's own updates to voicemail;
///   3. only genuine off-call / off-target / do-not-disturb states produce
///      voicemail.
///
/// Deliberately absent inputs and why:
///   - Inbox ("voicemail") mode is subsumed by `liveCallActive`: starting a call
///     is the explicit "speak the focused session to me" action, so a live
///     call's own updates play regardless of the inbox toggle, and off-call the
///     inbox toggle only ever yields voicemail here anyway.
///   - The focused session's UI category (active/archived/automation) is stale
///     display metadata frozen at call start; a session you explicitly focused
///     and dialed is authorized by that act, not by its catalog bucket.
public enum LivePlaybackRouter {
    /// - Parameters:
    ///   - liveCallActive: a live voice conversation is open.
    ///   - eventIsFromLiveAgent: the update came from a watched coding-agent
    ///     source (Codex, Claude Code, and peers), not a local/system notice.
    ///   - sessionIsCallTarget: the update's session is the call's frozen,
    ///     explicitly focused target session.
    ///   - audioPlaying: the player is currently busy (speaking an update or a
    ///     reply, or synthesizing one).
    ///   - settingsOverlayOpen: the in-window Settings overlay is up (INF-377), a
    ///     do-not-disturb surface that diverts even a live call's updates to
    ///     voicemail because the user cannot see captions. Defaulted false so
    ///     off-Settings callers keep normal live routing.
    public static func route(
        liveCallActive: Bool,
        eventIsFromLiveAgent: Bool,
        sessionIsCallTarget: Bool,
        audioPlaying: Bool,
        settingsOverlayOpen: Bool = false
    ) -> LivePlaybackRouting {
        guard liveCallActive,
              eventIsFromLiveAgent,
              sessionIsCallTarget,
              !settingsOverlayOpen else {
            return .voicemail
        }
        return audioPlaying ? .queueNext : .playNow
    }
}
