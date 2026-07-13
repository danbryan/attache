import Foundation

/// The one semantic activity phase every companion renderer draws from
/// (INF-268). Echoform bars, the Bubbles pet, and any future avatar are all
/// views over this same signal; none of them talk to watchers, playback, or
/// input monitors directly.
public enum CompanionActivityPhase: String, CaseIterable, Codable, Sendable {
    /// No pinned sessions and nothing else happening: the companion can rest.
    case sleeping
    /// Sessions are pinned but everything is quiet.
    case idle
    /// An agent is working with no visible tool activity, or the personality
    /// is composing a live answer.
    case agentThinking
    /// A finished turn is arriving: its recap is being composed or its speech
    /// synthesized, the beat between the agent finishing and Attaché speaking.
    case agentResponding
    /// An agent is visibly running tools right now; `toolKind` says what flavor.
    case toolRunning
    /// Attaché is speaking out loud.
    case speaking
    /// Playback is paused mid-recap.
    case paused
    /// A watched session is waiting on the user's answer.
    case blockedOnUser
    /// A watched session errored recently, or a live call failed.
    case error
}

/// Which agent the current phase belongs to, driving which speech bubble
/// lights up in agent-aware renderers.
public enum CompanionAgentIdentity: String, CaseIterable, Codable, Sendable {
    case none
    case codex
    case claude

    /// Maps a `SourceKind` raw value (the string stored on cards, sessions,
    /// and events) to a bubble identity. Non-agent sources read as `.none`.
    public init(sourceKindRawValue: String?) {
        switch sourceKindRawValue {
        case SourceKind.codex.rawValue: self = .codex
        case SourceKind.claudeCode.rawValue: self = .claude
        default: self = .none
        }
    }
}

/// The flavor of tool an agent is running, for renderers that vary the
/// animation per kind (shell shakes, edit scribbles, web orbits).
public enum CompanionToolKind: String, CaseIterable, Codable, Sendable {
    case edit
    case read
    case shell
    case web
    case other

    /// Classify a live activity phrase from `SessionActivityWatcher`'s fixed
    /// vocabulary. `sourceHint` is the phrase's source raw value
    /// ("toolIntent", "toolResult", "editEvent", "externalTool"); the phrase
    /// text refines within a hint. Keyword matching keeps this stable if the
    /// watcher's vocabulary grows: unknown phrases degrade to `.other`, never
    /// to a wrong strong flavor. Order matters: edit before read before shell
    /// so "editing files" never reads as a file read and "checking git" stays
    /// a read, not a shell run.
    public static func classify(phrase: String, sourceHint: String) -> CompanionToolKind {
        if sourceHint == "editEvent" { return .edit }
        if sourceHint == "externalTool" {
            return phrase.lowercased() == "finding tools" ? .other : .web
        }
        let lower = phrase.lowercased()
        if lower.contains("edit") { return .edit }
        if lower.contains("read") || lower.contains("scan") || lower.contains("search")
            || lower.contains("parsing") || lower.contains("diff") || lower.contains("git")
            || lower.contains("viewing") {
            return .read
        }
        if lower.contains("running") || lower.contains("build") || lower.contains("packag")
            || lower.contains("command") || lower.contains("test") || lower.contains("verif")
            || lower.contains("launch") || lower.contains("checking") {
            return .shell
        }
        if lower.contains("endpoint") || lower.contains("web") { return .web }
        return .other
    }
}

/// One pinned session as the fleet display sees it (INF-275): which agent's
/// bubble it belongs to, whether it is working, parked, or needs the user,
/// whether it is the focused session, and how many sub-agents it is running.
public struct CompanionFleetSession: Equatable, Sendable, Identifiable {
    public enum State: String, CaseIterable, Codable, Sendable {
        /// Records are landing; the mote orbits.
        case working
        /// Nothing recent; the mote parks, dimmed.
        case quiet
        /// Awaiting an answer or possibly waiting; the mote turns amber,
        /// shows a question mark, and pulses.
        case blocked
        /// The turn completed; the mote shows a check until the session
        /// goes active again or the user focuses it (INF-280).
        case finished
    }

    public var id: String
    public var agent: CompanionAgentIdentity
    public var state: State
    public var isFocused: Bool
    /// Live sub-agents (pending Task/Agent tool calls in a Claude session's
    /// main chain). Always 0 for sources with no sub-agent signal.
    public var activeSubAgents: Int
    /// Display title for hover affordances.
    public var title: String

    public init(
        id: String,
        agent: CompanionAgentIdentity,
        state: State,
        isFocused: Bool = false,
        activeSubAgents: Int = 0,
        title: String = ""
    ) {
        self.id = id
        self.agent = agent
        self.state = state
        self.isFocused = isFocused
        self.activeSubAgents = activeSubAgents
        self.title = title
    }
}

/// The consolidated state a companion renderer consumes. Semantic fields
/// change at semantic rate (attention transitions, playback flips, phrase
/// decay); `audio` is the existing 20 Hz `VisualizerRenderState` passed
/// through so a speaking mouth can track level without a second audio path.
/// The publisher deliberately refreshes on semantic changes only; views that
/// need live audio compose it per frame via `with(audio:)` from the
/// `PlaybackTimeline` they already observe, keeping the whole-window
/// invalidation rate unchanged.
public struct CompanionActivityState: Equatable, Sendable {
    public var phase: CompanionActivityPhase
    public var activeAgent: CompanionAgentIdentity
    /// Set only while `phase == .toolRunning`.
    public var toolKind: CompanionToolKind?
    public var audio: VisualizerRenderState
    /// The user is actively typing in the app (event occurrence only; no
    /// content, no keycodes; see `TypingActivityMonitor`).
    public var userTyping: Bool
    public var unreadCount: Int
    public var hasCards: Bool
    /// Every pinned session, for fleet displays (INF-275). Pass-through like
    /// `unreadCount`: derived from the watch list and attention states the
    /// app already tracks, never new monitoring.
    public var fleet: [CompanionFleetSession]

    public init(
        phase: CompanionActivityPhase = .sleeping,
        activeAgent: CompanionAgentIdentity = .none,
        toolKind: CompanionToolKind? = nil,
        audio: VisualizerRenderState = VisualizerRenderState(),
        userTyping: Bool = false,
        unreadCount: Int = 0,
        hasCards: Bool = false,
        fleet: [CompanionFleetSession] = []
    ) {
        self.phase = phase
        self.activeAgent = activeAgent
        self.toolKind = toolKind
        self.audio = audio
        self.userTyping = userTyping
        self.unreadCount = unreadCount
        self.hasCards = hasCards
        self.fleet = fleet
    }

    public static let initial = CompanionActivityState()

    /// The same semantic state with a fresh audio frame, for per-frame
    /// composition inside a renderer.
    public func with(audio: VisualizerRenderState) -> CompanionActivityState {
        var next = self
        next.audio = audio
        return next
    }
}

/// A plain-value snapshot of the signals `CompanionActivityState.derive(from:)`
/// reduces, mirroring the `CallSignals` pattern: the app layer maps its own
/// types (attention states, watcher phrases, playback flags) into these
/// fields at one choke point, and the reducer stays pure and unit-testable.
///
/// Per-phase agent attribution comes pre-resolved (`blockedAgent`,
/// `speakingAgent`, ...) because the mapping from a session or card to its
/// `SourceKind` lives in the app layer; the reducer only picks whose moment
/// wins.
public struct CompanionActivitySignals: Equatable, Sendable {
    /// Any session is currently attached (pinned) for watching.
    public var hasPinnedSessions: Bool
    /// A watched session needs the user (awaiting answer / possibly waiting).
    public var blockedAgent: CompanionAgentIdentity?
    /// A watched session's tail shows a recent error.
    public var erroredAgent: CompanionAgentIdentity?
    /// A watched session is actively working (records landing).
    public var workingAgent: CompanionAgentIdentity?
    /// A finished turn's recap is being composed or synthesized right now.
    public var respondingAgent: CompanionAgentIdentity?
    /// A fresh tool signal was observed (within the app layer's dwell window).
    public var toolAgent: CompanionAgentIdentity?
    /// The flavor of that fresh tool signal.
    public var toolKind: CompanionToolKind?
    public var playbackIsPlaying: Bool
    public var playbackIsPaused: Bool
    /// Whose card is loaded in playback, for bubble identity while speaking.
    public var speakingAgent: CompanionAgentIdentity?
    /// A live conversation turn is waiting on the personality.
    public var isConversing: Bool
    /// The live call surface is showing a failure.
    public var hasConversationFailure: Bool
    public var userTyping: Bool
    public var unreadCount: Int
    public var hasCards: Bool
    public var fleet: [CompanionFleetSession]

    public init(
        hasPinnedSessions: Bool = false,
        blockedAgent: CompanionAgentIdentity? = nil,
        erroredAgent: CompanionAgentIdentity? = nil,
        workingAgent: CompanionAgentIdentity? = nil,
        respondingAgent: CompanionAgentIdentity? = nil,
        toolAgent: CompanionAgentIdentity? = nil,
        toolKind: CompanionToolKind? = nil,
        playbackIsPlaying: Bool = false,
        playbackIsPaused: Bool = false,
        speakingAgent: CompanionAgentIdentity? = nil,
        isConversing: Bool = false,
        hasConversationFailure: Bool = false,
        userTyping: Bool = false,
        unreadCount: Int = 0,
        hasCards: Bool = false,
        fleet: [CompanionFleetSession] = []
    ) {
        self.hasPinnedSessions = hasPinnedSessions
        self.blockedAgent = blockedAgent
        self.erroredAgent = erroredAgent
        self.workingAgent = workingAgent
        self.respondingAgent = respondingAgent
        self.toolAgent = toolAgent
        self.toolKind = toolKind
        self.playbackIsPlaying = playbackIsPlaying
        self.playbackIsPaused = playbackIsPaused
        self.speakingAgent = speakingAgent
        self.isConversing = isConversing
        self.hasConversationFailure = hasConversationFailure
        self.userTyping = userTyping
        self.unreadCount = unreadCount
        self.hasCards = hasCards
        self.fleet = fleet
    }
}

/// A one-shot beat played over the continuous phase (INF-271): a hop when a
/// watched turn completes, a bubble pop when a voicemail lands unplayed, a
/// yawn when a pinned session goes stale. Moments never replace the phase;
/// renderers queue them, play them when no signal phase (blocked, speaking,
/// paused) owns the stage, and drop them once stale.
public struct CompanionActivityMoment: Equatable, Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        /// A watched session's turn finished (attention active -> turnComplete).
        case celebrate
        /// A new voicemail card was filed without playing live.
        case cardArrived
        /// A pinned session went stale (attention -> quiet).
        case drowsy
    }

    public var id: UUID
    public var kind: Kind
    public var agent: CompanionAgentIdentity
    public var at: Date

    public init(id: UUID = UUID(), kind: Kind, agent: CompanionAgentIdentity, at: Date) {
        self.id = id
        self.kind = kind
        self.agent = agent
        self.at = at
    }

    /// Moments older than this are dropped instead of played; a celebration
    /// for something the user no longer remembers reads as a glitch.
    public static let shelfLife: TimeInterval = 8
}

/// Dwell rules between the raw derived state and what renderers see
/// (INF-271): rapid tool-call bursts and thinking/tool flapping must read as
/// sustained activity, not strobing.
///
/// The rules, in order:
/// 1. Signal phases (blockedOnUser, speaking, paused, error) switch
///    immediately, in both directions; the user must never wait out a dwell
///    to see that an agent needs them.
/// 2. An ambient phase (sleeping, idle, agentThinking, agentResponding,
///    toolRunning) holds for at least `ambientDwell` before yielding to a
///    DIFFERENT ambient phase. Pass-through fields (audio, typing, unread)
///    always update.
/// 3. Within toolRunning, the tool kind holds for at least `toolKindDwell`
///    so a shell/read/edit storm reads as one sustained gesture.
/// 4. The active agent may change with the phase; while a phase is held, its
///    original agent is held with it (bubble identity always matches what is
///    being shown, not what is coming next).
public final class CompanionActivityDamper {
    private let ambientDwell: TimeInterval
    private let toolKindDwell: TimeInterval
    private var current: CompanionActivityState?
    private var phaseChangedAt: Date?
    private var toolKindChangedAt: Date?

    private static let signalPhases: Set<CompanionActivityPhase> = [
        .blockedOnUser, .speaking, .paused, .error,
    ]

    public init(ambientDwell: TimeInterval = 1.2, toolKindDwell: TimeInterval = 2.0) {
        self.ambientDwell = ambientDwell
        self.toolKindDwell = toolKindDwell
    }

    public func damp(_ proposed: CompanionActivityState, now: Date) -> CompanionActivityState {
        guard var held = current, let changedAt = phaseChangedAt else {
            current = proposed
            phaseChangedAt = now
            toolKindChangedAt = now
            return proposed
        }

        if proposed.phase == held.phase {
            if held.phase == .toolRunning,
               proposed.toolKind != held.toolKind,
               let kindChangedAt = toolKindChangedAt,
               now.timeIntervalSince(kindChangedAt) < toolKindDwell {
                held.audio = proposed.audio
                held.userTyping = proposed.userTyping
                held.unreadCount = proposed.unreadCount
                held.hasCards = proposed.hasCards
                held.fleet = proposed.fleet
                current = held
                return held
            }
            if proposed.toolKind != held.toolKind {
                toolKindChangedAt = now
            }
            current = proposed
            return proposed
        }

        let switchingIsInstant = Self.signalPhases.contains(proposed.phase)
            || Self.signalPhases.contains(held.phase)
        if switchingIsInstant || now.timeIntervalSince(changedAt) >= ambientDwell {
            current = proposed
            phaseChangedAt = now
            toolKindChangedAt = now
            return proposed
        }

        held.audio = proposed.audio
        held.userTyping = proposed.userTyping
        held.unreadCount = proposed.unreadCount
        held.hasCards = proposed.hasCards
        held.fleet = proposed.fleet
        current = held
        return held
    }
}

extension CompanionActivityState {
    /// Pure reducer from a signal snapshot to the state renderers show.
    ///
    /// Precedence (highest first):
    ///
    /// 1. `blockedOnUser` - an agent waiting on the user must never be
    ///    covered by anything, including speech.
    /// 2. `speaking` - active narration is the app's core act; the mouth
    ///    moving to it beats ambient agent activity.
    /// 3. `paused` - a held recap still owns the stage.
    /// 4. `error` - a session error or failed call interrupts ambience but
    ///    never live speech (the speech is often the error being narrated).
    /// 5. `agentResponding` - a turn just finished; its recap is on the way.
    /// 6. `toolRunning` - visible tool activity, with `toolKind` flavor.
    /// 7. `agentThinking` - an agent (or the live personality) is working
    ///    with nothing more specific to show.
    /// 8. `idle` - sessions pinned, everything quiet.
    /// 9. `sleeping` - nothing pinned at all.
    ///
    /// `toolKind` is populated only for `toolRunning`; every other phase
    /// clears it so a renderer never shows a stale flavor.
    public static func derive(
        from signals: CompanionActivitySignals,
        audio: VisualizerRenderState = VisualizerRenderState()
    ) -> CompanionActivityState {
        let ambient = { (phase: CompanionActivityPhase, agent: CompanionAgentIdentity) in
            CompanionActivityState(
                phase: phase,
                activeAgent: agent,
                toolKind: phase == .toolRunning ? signals.toolKind : nil,
                audio: audio,
                userTyping: signals.userTyping,
                unreadCount: signals.unreadCount,
                hasCards: signals.hasCards,
                fleet: signals.fleet
            )
        }

        if let blocked = signals.blockedAgent {
            return ambient(.blockedOnUser, blocked)
        }
        if signals.playbackIsPlaying, !signals.playbackIsPaused {
            return ambient(.speaking, signals.speakingAgent ?? .none)
        }
        if signals.playbackIsPaused {
            return ambient(.paused, signals.speakingAgent ?? .none)
        }
        if let errored = signals.erroredAgent {
            return ambient(.error, errored)
        }
        if signals.hasConversationFailure {
            return ambient(.error, .none)
        }
        if let responding = signals.respondingAgent {
            return ambient(.agentResponding, responding)
        }
        if signals.toolAgent != nil || signals.toolKind != nil {
            return ambient(.toolRunning, signals.toolAgent ?? .none)
        }
        if let working = signals.workingAgent {
            return ambient(.agentThinking, working)
        }
        if signals.isConversing {
            return ambient(.agentThinking, .none)
        }
        if signals.hasPinnedSessions {
            return ambient(.idle, .none)
        }
        return ambient(.sleeping, .none)
    }
}
