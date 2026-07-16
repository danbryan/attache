import AppKit
import Combine
import AttacheCore
import Foundation
import UniformTypeIdentifiers

struct HomeNotice: Equatable, Identifiable {
    enum Kind { case voicemail, mode, info }
    let id: UUID
    let text: String
    let kind: Kind
}

struct ConversationTurn: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id: String
    let role: Role
    let text: String
    let createdAt: Date
    /// Assistant output derived from local-only evidence remains local-only.
    /// User-authored turns default to allowedRemote because sending a later
    /// turn is the user's explicit disclosure, not an inferred declassification.
    let egress: AttacheContextItemEgress

    init(
        id: String,
        role: Role,
        text: String,
        createdAt: Date,
        egress: AttacheContextItemEgress = .allowedRemote
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.egress = egress
    }
}

enum ConversationDestination: String, CaseIterable, Identifiable {
    case attache
    case agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .attache: return "Ask Attaché"
        case .agent: return "Tell Agent"
        }
    }
}

struct AgentSendTarget: Equatable {
    let sessionID: String
    let sourceKind: String
    let displayTitle: String
    let workingDirectory: String?

    var sourceDisplayName: String {
        (SourceKind(rawValue: sourceKind) ?? .generic).displayName
    }
}

struct ConversationTargetSnapshot: Equatable {
    let target: CodexSessionTarget
    let workingDirectory: String?
    /// The app-owned session authorization captured at the moment the call
    /// starts. It is nil when the catalog target has no current indexed log,
    /// so an attachment can still receive explicit agent sends without
    /// accidentally gaining transcript/file-read authority.
    let focusedSession: AttacheFocusedSession?

    var agentSendTarget: AgentSendTarget {
        AgentSendTarget(
            sessionID: target.id,
            sourceKind: target.sourceKind.rawValue,
            displayTitle: target.displayTitle,
            workingDirectory: workingDirectory
        )
    }
}

/// Immutable authority for one live-call request. Tool proposals may be
/// decoded off the main actor, but every effect revalidates this exact pair on
/// the main actor immediately before claiming or mutating state.
struct ConversationRequestAuthorization: Equatable, Sendable {
    let callID: UUID
    let requestID: UUID
}

/// App-owned state for a model-requested session search. Rows and the opaque
/// selection token are visible only to the native picker; the model receives
/// the content-free `result` value.
struct ModelSessionDiscoveryPickerState {
    let token: UUID
    let query: String
    let orderedResults: [SessionSearchHit]
}

/// One explicit whole-session review frozen to a live call, session epoch,
/// personality, model, strategy, and source version. Replacing the preview
/// replaces this value atomically; late progress from the prior ID is ignored.
private struct ActiveExhaustiveReviewContext {
    let callID: UUID
    let preparedID: String
    let runtime: AttacheExhaustiveReviewRuntime
    let source: SessionContextRuntime.FrozenReviewSource
    let baseSnapshot: AttacheRequestSnapshot
}

private struct PendingAgentSend {
    let text: String
    let target: AgentSendTarget
    let origin: InstructionOrigin
    let sourceUtterance: String?
}

private struct AgentInstructionToolArguments: Decodable {
    let instruction: String
    /// The agent the personality explicitly declared this instruction is for
    /// (INF-246), matching `SourceKind.rawValue` ("codex" | "claude_code").
    /// Optional: its absence must behave exactly as before this ticket.
    let intendedAgent: String?

    private enum CodingKeys: String, CodingKey {
        case instruction
        case intendedAgent = "intended_agent"
    }
}

private struct MemoryProposalToolArguments: Decodable {
    let statement: String
    let type: String
    let scope: String
    let scopeValue: String?
    let sensitivity: String
    let egress: String

    private enum CodingKeys: String, CodingKey {
        case statement, type, scope, sensitivity, egress
        case scopeValue = "scope_value"
    }
}

struct CardPersonalityMarker: Equatable {
    let id: String
    let name: String
    let isUnavailable: Bool

    var displayName: String {
        isUnavailable ? "\(name) (deleted)" : name
    }
}

enum VoicemailInboxScope: String, CaseIterable, Identifiable {
    case all
    case focused
    case watched
    case codex
    case claudeCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return NSLocalizedString("All", comment: "")
        case .focused: return NSLocalizedString("Focused", comment: "")
        case .watched: return NSLocalizedString("Watched", comment: "")
        case .codex: return "Codex"
        case .claudeCode: return "Claude"
        }
    }

    func titleWithCount(_ count: Int) -> String {
        count > 0 ? "\(title) \(count)" : title
    }
}

enum AttacheHistoryScope: String, CaseIterable, Identifiable {
    case focused
    case watched
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focused: return NSLocalizedString("Focused", comment: "")
        case .watched: return NSLocalizedString("Watched", comment: "")
        case .all: return NSLocalizedString("All", comment: "")
        }
    }

    func titleWithCount(_ count: Int) -> String {
        count > 0 ? "\(title) \(count)" : title
    }
}

final class AppModel: ObservableObject {
    @Published private(set) var cards: [VoicemailCard] = []
    @Published var inboxScope: VoicemailInboxScope = .all
    @Published var selectedCardID: String? {
        didSet {
            if selectedCardID != oldValue {
                selectedStartProgress = 0
                resetFollowUpAnswerStatus()
            }
        }
    }
    @Published var intakeStatus: String = "Listening for local events."
    @Published var followUpText: String = ""
    @Published var followUpStatus: String = "Ask Attaché about this update."
    @Published var followUpAnswerText: String = ""
    @Published private(set) var followUpReceiptResponseID: String?
    @Published private(set) var isGeneratingFollowUpAnswer: Bool = false
    @Published var liveFollowUpText: String = ""
    @Published var liveFollowUpStatus: String = "Ask Attaché about the current session."
    @Published var liveFollowUpAnswerText: String = ""
    @Published private(set) var liveFollowUpReceiptResponseID: String?
    @Published private(set) var isGeneratingLiveFollowUpAnswer: Bool = false
    @Published var conversationActive: Bool = false
    @Published private(set) var conversationMessages: [ConversationTurn] = []
    @Published private(set) var isConversing: Bool = false
    @Published var conversationDraft: String = ""
    @Published var conversationDestination: ConversationDestination = .attache
    @Published private(set) var conversationTargetSnapshot: ConversationTargetSnapshot?
    @Published private(set) var conversationStatus: String = ""
    @Published private(set) var conversationRecovery: ConversationRecovery?
    /// Set when the user picks a new model/provider from the recovery menu,
    /// cleared the moment a new attempt starts (`sendConversationMessage`).
    /// `CallStatusPresentation` shows this in place of the stale failure
    /// message while `callPhase` is still `.failed` (the phase itself does
    /// not change until the retry actually runs).
    @Published private(set) var conversationRecoveryConfirmation: String?
    @Published private(set) var conversationElapsedSeconds: Int = 0
    @Published private(set) var pendingAssistantReply: String?
    private var pendingAssistantInference: AttacheInferenceMetadata?
    private var pendingAssistantReplyEgress: AttacheContextItemEgress = .allowedRemote
    /// The live-call phase, derived from `isConversing`, playback state,
    /// mic state, `conversationRecovery`, and the two-way send log by the
    /// pure `CallPhase.derive(from:)` reducer (see `refreshCallPhase()`).
    /// Not yet consumed by any view (that's a later ticket, A2); computing
    /// and publishing it here replaces nothing about today's rendering.
    @Published private(set) var callPhase: CallPhase = .idle

    // MARK: - Recap / follow-up recovery (INF-254)
    //
    // Same shape as the live call's `conversationRecovery` above, extended to
    // two more surfaces that used to degrade silently: the inbox recap and
    // follow-up answers. Each surface keeps its own recovery state (retrying
    // means something different per surface: replay the same cards, or
    // re-ask the same question) but all three classify with the identical
    // `ConversationRecovery.classify` (D1) and only offer the affordance when
    // `offersModelSwitch` is true.
    @Published private(set) var recapRecovery: ConversationRecovery?
    @Published private(set) var recapRecoveryConfirmation: String?
    private var recapRetryCards: [VoicemailCard] = []
    @Published private(set) var followUpRecovery: ConversationRecovery?
    @Published private(set) var liveFollowUpRecovery: ConversationRecovery?
    /// Incremented whenever background topic tagging (`.tagging` role) fails.
    /// Tagging stays silent to the user by design (per docs/reviews); this is
    /// the diagnostics-only counter the review asked for instead. It maps
    /// onto `AttacheCore.DiagnosticSnapshot.taggingFailureCount`, the closest
    /// existing "diagnostics surface" in the codebase, though nothing in the
    /// shipped app constructs a `DiagnosticSnapshot` yet (it exists today only
    /// as a data structure exercised by unit tests) - wiring an actual
    /// bug-report UI to it is out of scope here.
    @Published private(set) var taggingFailureCount: Int = 0

    // MARK: - Opt-in auto-fallback chain (INF-258/D5)
    //
    // Conversation role only (spec scope). Settings state below is persisted;
    // `conversationFallbackState` is call-scoped and deliberately NOT
    // persisted, reset at the start of every call (`startConversation()`) so
    // the primary provider is retried automatically on the next call, never
    // mid-call. See `ConversationFallbackChain.swift` for the pure
    // advance/sticky rules this only ever calls into.
    @Published var conversationFallbackChainEnabled: Bool = false {
        didSet {
            defaults.set(conversationFallbackChainEnabled, forKey: AttachePreferenceKey.conversationFallbackChainEnabled)
        }
    }
    @Published var conversationFallbackChain: [AttachePresentationProvider] = [] {
        didSet {
            defaults.set(
                conversationFallbackChain.map(\.rawValue),
                forKey: AttachePreferenceKey.conversationFallbackChainProviders
            )
        }
    }
    private var conversationFallbackState = ConversationFallbackState()
    private var conversationFallbackRetryTimer: Timer?
    /// One ledger per user turn, retained across every model tool round and an
    /// automatic provider fallback. A fresh explicit retry creates a new turn
    /// and therefore a new ledger (INF-337).
    private(set) var conversationTurnEffectLedger: ConversationTurnEffectLedger?
    /// Every fallback hop this launch, for a future diagnostics snapshot
    /// (`DiagnosticSnapshot.conversationFallbackCount`); mirrors
    /// `taggingFailureCount`'s in-memory-only counter above (spec item 6).
    @Published private(set) var conversationFallbackHopCount: Int = 0
    /// The live-call phase (`CallPhase.fallbackAnnounced`) needs its own
    /// signal distinct from `conversationStatus`: `CallStatusPresentation`
    /// derives on-call status text entirely from `callPhase`, which does not
    /// read `conversationStatus` for most phases (`.thinking`/`.speaking` use
    /// fixed text), so the announcement would otherwise never actually be
    /// visible in the call composer. Set for the announcement's rough
    /// duration, cleared the moment the delayed retry actually starts.
    @Published private(set) var conversationFallbackAnnouncement: String?

    @Published var voiceInputMode: AttacheVoiceInputMode = .pushToTalk {
        didSet {
            guard voiceInputMode != oldValue else { return }
            defaults.set(voiceInputMode.rawValue, forKey: AttachePreferenceKey.voiceInputMode)
            applyVoiceInputMode()
        }
    }
    @Published var narrationDetail: AttacheNarrationDetail = .milestones {
        didSet {
            guard narrationDetail != oldValue else { return }
            defaults.set(narrationDetail.rawValue, forKey: AttachePreferenceKey.narrationDetail)
            codexSessionWatcher.quietPolls = narrationDetail.coalescerQuietPolls
        }
    }
    @Published var microphoneDeviceID: String = "" {
        didSet {
            guard microphoneDeviceID != oldValue else { return }
            defaults.set(microphoneDeviceID, forKey: AttachePreferenceKey.microphoneDeviceID)
            applyMicConfiguration()
        }
    }
    @Published private(set) var microphoneDevices: [MicrophoneInputDevice] = []
    @Published var serverURLText: String = "http://127.0.0.1:7531/events"
    @Published private(set) var codexSessions: [CodexSessionTarget] = []
    @Published private(set) var archivedCodexSessions: [CodexSessionTarget] = []
    @Published private(set) var codexAutomations: [CodexSessionTarget] = []

    @Published var attachedCodexSessionID: String? {
        didSet {
            guard attachedCodexSessionID != oldValue else { return }
            if let attachedCodexSessionID {
                defaults.set(attachedCodexSessionID, forKey: AttachePreferenceKey.attachedCodexSessionID)
            } else {
                defaults.removeObject(forKey: AttachePreferenceKey.attachedCodexSessionID)
            }
            // Drop any queued live updates from the previous focus so they don't
            // play against the newly attached session.
            livePlaybackQueue.reset()
            loadAttachedSessionHistory()
        }
    }
    @Published private(set) var attachedSessionHistory: [VoicemailCard] = []
    @Published private(set) var selectedStartProgress: Double = 0
    @Published var visualMode: AttacheVisualMode = .character {
        didSet { defaults.set(visualMode.rawValue, forKey: AttachePreferenceKey.visualMode) }
    }
    /// The desktop mini attache window (INF-272).
    @Published var miniAttacheEnabled: Bool = false {
        didSet { defaults.set(miniAttacheEnabled, forKey: AttachePreferenceKey.miniAttache) }
    }
    @Published var miniAttacheClickThrough: Bool = false {
        didSet { defaults.set(miniAttacheClickThrough, forKey: AttachePreferenceKey.miniAttacheClickThrough) }
    }
    /// Install Claude Code's Notification and Stop hooks so the character's status is
    /// exact (needs-you and done come from Claude Code itself, not a transcript
    /// guess). On by default; toggling off removes only Attaché's hook entries.
    @Published var installClaudeHooks: Bool = true {
        didSet {
            defaults.set(installClaudeHooks, forKey: AttachePreferenceKey.installClaudeHooks)
            applyClaudeHooks()
        }
    }
    /// Where the user last parked the focused mote on the session ring
    /// (INF-280); only dragging it writes a new angle.
    @Published var characterFocusAngle: Double = AttacheCharacterChoreography.defaultFocusAngle {
        didSet { defaults.set(characterFocusAngle, forKey: AttachePreferenceKey.characterFocusAngle) }
    }
    /// The character in the middle of the ring (INF-283). Volt is the
    /// default (INF-286): it pairs with the robotic default system voice a
    /// fresh install speaks with.
    @Published var character: AttacheCharacter = .robot {
        didSet { defaults.set(character.rawValue, forKey: AttachePreferenceKey.character) }
    }
    /// The shiny easter egg (INF-273): a one-time random roll persisted per
    /// profile, so roughly 1 in 20 installs gets a golden-arc Attache. Zero
    /// configuration on purpose; discovery is the point.
    lazy var characterShiny: Bool = {
        if defaults.object(forKey: AttachePreferenceKey.characterShinySeed) == nil {
            defaults.set(Int.random(in: 0..<20), forKey: AttachePreferenceKey.characterShinySeed)
        }
        return defaults.integer(forKey: AttachePreferenceKey.characterShinySeed) == 0
    }()
    @Published var theme: AttacheTheme = .macOS {
        didSet { defaults.set(theme.rawValue, forKey: AttachePreferenceKey.theme) }
    }
    @Published var appearanceMode: AttacheAppearanceMode = .system {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: AttachePreferenceKey.appearanceMode)
            applyAppearance()
        }
    }
    @Published var customThemes: [AttacheThemeSpec] = []
    @Published var activeCustomThemeID: String? {
        didSet { defaults.set(activeCustomThemeID, forKey: AttachePreferenceKey.customThemeID) }
    }
    private var customThemePersistWork: DispatchWorkItem?
    @Published var surfaceOpacity: Double = 1.0 {
        didSet {
            let clamped = min(1.0, max(0.35, surfaceOpacity))
            if surfaceOpacity != clamped {
                surfaceOpacity = clamped
                return
            }
            defaults.set(surfaceOpacity, forKey: AttachePreferenceKey.surfaceOpacity)
        }
    }
    @Published var showOnboarding: Bool = false
    private var inboxCatchUpQueue: [String] = []
    @Published var uiTextScale: Double = 1.0 {
        didSet {
            let clamped = AttacheTypeScale.clamp(uiTextScale)
            if uiTextScale != clamped {
                uiTextScale = clamped
                return
            }
            defaults.set(uiTextScale, forKey: AttachePreferenceKey.uiTextScale)
        }
    }
    @Published var seekStepSeconds: Int = 5 {
        didSet {
            let clamped = min(30, max(2, seekStepSeconds))
            if seekStepSeconds != clamped {
                seekStepSeconds = clamped
                return
            }
            defaults.set(seekStepSeconds, forKey: AttachePreferenceKey.seekStepSeconds)
            mediaRemote.setSkipInterval(seconds: seekStepSeconds)
        }
    }
    @Published var captionsEnabled: Bool = true {
        didSet { defaults.set(captionsEnabled, forKey: AttachePreferenceKey.captionsEnabled) }
    }
    static let captionLineRange = 1...5
    static let captionFontRange: ClosedRange<Double> = 18...34
    @Published var captionFontSize: Double = 24 {
        didSet {
            let clamped = min(Self.captionFontRange.upperBound, max(Self.captionFontRange.lowerBound, captionFontSize))
            if captionFontSize != clamped {
                captionFontSize = clamped
                return
            }
            defaults.set(captionFontSize, forKey: AttachePreferenceKey.captionFontSize)
        }
    }
    @Published var captionLineCount: Int = 2 {
        didSet {
            let clamped = min(Self.captionLineRange.upperBound, max(Self.captionLineRange.lowerBound, captionLineCount))
            if captionLineCount != clamped {
                captionLineCount = clamped
                return
            }
            defaults.set(captionLineCount, forKey: AttachePreferenceKey.captionLineCount)
        }
    }
    @Published var audioCacheRetentionMinutes: Int = 24 * 60 {
        didSet {
            let preset = Self.nearestAudioCacheRetentionOption(to: audioCacheRetentionMinutes).minutes
            if audioCacheRetentionMinutes != preset {
                audioCacheRetentionMinutes = preset
                return
            }
            defaults.set(audioCacheRetentionMinutes, forKey: AttachePreferenceKey.audioCacheRetentionMinutes)
            playback.setAudioCacheRetention(minutes: audioCacheRetentionMinutes)
        }
    }
    static let audioCacheRetentionOptions: [(label: String, minutes: Int)] = [
        ("Off", 0),
        ("15 minutes", 15),
        ("30 minutes", 30),
        ("1 hour", 60),
        ("6 hours", 6 * 60),
        ("12 hours", 12 * 60),
        ("1 day", 24 * 60),
        ("2 days", 2 * 24 * 60),
        ("7 days", 7 * 24 * 60),
        ("30 days", 30 * 24 * 60)
    ]

    static func nearestAudioCacheRetentionOption(to minutes: Int) -> (label: String, minutes: Int) {
        audioCacheRetentionOptions.min { abs($0.minutes - minutes) < abs($1.minutes - minutes) }
            ?? ("1 day", 24 * 60)
    }
    @Published var spokenLanguage: String = "en" {
        didSet {
            defaults.set(spokenLanguage, forKey: AttachePreferenceKey.spokenLanguage)
            applyMicConfiguration()
        }
    }
    /// When on (Voicemail mode), nothing auto-speaks: every update queues silently
    /// as an unread voicemail and posts a notification so you can play it later.
    @Published var voicemailMode: Bool = true {
        didSet {
            guard voicemailMode != oldValue else { return }
            defaults.set(voicemailMode, forKey: AttachePreferenceKey.voicemailMode)
            if voicemailMode {
                AttacheNotifier.shared.requestAuthorizationIfUndetermined()
            }
        }
    }
    /// Ambient home: when on, the chrome (dock, banner, history) fades while the
    /// pointer is still and wakes on movement. Off keeps everything always visible.
    @Published var autoHideControls: Bool = true {
        didSet { defaults.set(autoHideControls, forKey: AttachePreferenceKey.autoHideControls) }
    }
    @Published var autoHideDelaySeconds: Double = 2.5 {
        didSet { defaults.set(autoHideDelaySeconds, forKey: AttachePreferenceKey.autoHideDelaySeconds) }
    }
    @Published var showPersonalitySwitcher: Bool = true {
        didSet { defaults.set(showPersonalitySwitcher, forKey: AttachePreferenceKey.showPersonalitySwitcher) }
    }
    @Published var showPersonalityNameInDock: Bool = false {
        didSet { defaults.set(showPersonalityNameInDock, forKey: AttachePreferenceKey.showPersonalityNameInDock) }
    }
    /// Attention state per watched session (INF-179). Only sessions with
    /// something notable appear; quiet sessions are absent.
    @Published var sessionAttention: [String: SessionAttentionState] = [:]
    @Published var notifyScope: AttacheNotifyScope = .allUpdates {
        didSet { defaults.set(notifyScope.rawValue, forKey: AttachePreferenceKey.notifyScope) }
    }
    @Published var showInMenuBar: Bool = true {
        didSet { defaults.set(showInMenuBar, forKey: AttachePreferenceKey.showInMenuBar) }
    }
    @Published var showTips: Bool = true {
        didSet { defaults.set(showTips, forKey: AttachePreferenceKey.showTips) }
    }
    private let tipEngine = AttacheTipEngine()
    @Published var playbackSpeed: Double = 1.0 {
        didSet {
            let clamped = min(1.6, max(0.8, playbackSpeed))
            if clamped != playbackSpeed { playbackSpeed = clamped; return }
            defaults.set(clamped, forKey: AttachePreferenceKey.playbackSpeed)
            playback.playbackRate = Float(clamped)
            if let index = personalities.firstIndex(where: { $0.id == activePersonalityID }),
               abs((personalities[index].playbackSpeed ?? 1.0) - clamped) > 0.001 {
                personalities[index].playbackSpeed = clamped
                personalityStore.save(personalities, activeID: activePersonalityID)
            }
        }
    }

    var playbackSpeedLabel: String {
        abs(playbackSpeed - 1.0) < 0.01 ? "1x" : String(format: "%.1fx", playbackSpeed)
    }

    func cyclePlaybackSpeed() {
        let presets: [Double] = [1.0, 1.1, 1.2, 1.3, 1.5, 0.9]
        let index = presets.firstIndex(where: { abs($0 - playbackSpeed) < 0.05 }) ?? 0
        playbackSpeed = presets[(index + 1) % presets.count]
    }
    // Default ON (was off through 0.1.3): the ambient verbs are the "glance
    // at the corner and see what your agents are up to" experience, and users
    // expected them without knowing there was a toggle. A stored preference
    // still wins on load, so anyone who turned them off stays off.
    @Published var showActivityInsights: Bool = true {
        didSet {
            defaults.set(showActivityInsights, forKey: AttachePreferenceKey.showActivityInsights)
            updateCodexWatcher()
        }
    }
    @Published private(set) var activityPhrases: [AgentActivityPhrase] = []
    /// A transient chip that pokes through the ambient glow when news arrives.
    @Published var homeNotice: HomeNotice?
    private var homeNoticeClearItem: DispatchWorkItem?

    func postHomeNotice(_ text: String, kind: HomeNotice.Kind, duration: TimeInterval) {
        let notice = HomeNotice(id: UUID(), text: text, kind: kind)
        homeNotice = notice
        homeNoticeClearItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            if self?.homeNotice?.id == notice.id { self?.homeNotice = nil }
        }
        homeNoticeClearItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Flips the interrupt mode and confirms it with a brief chip (used by the
    /// dock toggle, the menu bar, and the shortcut so loading doesn't chip).
    func toggleVoicemailMode() {
        voicemailMode.toggle()
        postHomeNotice(
            voicemailMode ? "Inbox: updates will wait quietly" : "Live: updates speak as they arrive",
            kind: .mode,
            duration: 2.2
        )
    }
    @Published var captionSyncOffsetMs: Int = 0 {
        didSet { defaults.set(captionSyncOffsetMs, forKey: AttachePreferenceKey.captionSyncOffsetMs) }
    }
    @Published var presentationLLMEnabled: Bool = true {
        didSet {
            if !presentationLLMEnabled {
                presentationLLMEnabled = true
                return
            }
            defaults.set(presentationLLMEnabled, forKey: AttachePreferenceKey.presentationLLMEnabled)
            refreshPresentationStatus()
        }
    }
    /// Set only while a conversation-recovery Switch-model action is applying
    /// a new provider/model (`selectConversationRecoveryModel`/
    /// `selectConversationRecoveryProvider`). The didSets below check this to
    /// persist the choice to the `conversation` role's per-role keys instead
    /// of the global `presentationLLM*` keys every other role falls back to
    /// (INF-247): a call-time model switch must never change what
    /// presentation/recap/tagging use. The in-memory published value still
    /// updates normally either way, so the Settings > Model page and the
    /// recovery menu keep reflecting the current selection.
    private var isApplyingConversationRecoveryOverride = false
    @Published var presentationProvider: AttachePresentationProvider = .ollama {
        didSet {
            let key = isApplyingConversationRecoveryOverride
                ? AttachePreferenceKey.presentationLLMRoleKey(.conversation, .provider)
                : AttachePreferenceKey.presentationLLMProvider
            defaults.set(presentationProvider.rawValue, forKey: key)
            refreshPresentationStatus()
        }
    }
    @Published var presentationBaseURL: String = AttachePresentationProvider.ollama.defaultBaseURL {
        didSet {
            let key = isApplyingConversationRecoveryOverride
                ? AttachePreferenceKey.presentationLLMRoleKey(.conversation, .baseURL)
                : AttachePreferenceKey.presentationLLMBaseURL
            defaults.set(presentationBaseURL, forKey: key)
            refreshPresentationStatus()
        }
    }
    @Published var presentationModel: String = AttachePresentationProvider.ollama.defaultModel {
        didSet {
            let key = isApplyingConversationRecoveryOverride
                ? AttachePreferenceKey.presentationLLMRoleKey(.conversation, .model)
                : AttachePreferenceKey.presentationLLMModel
            defaults.set(presentationModel, forKey: key)
            refreshPresentationStatus()
        }
    }
    @Published var presentationReasoningEffort: String = AttachePresentationProvider.ollama.defaultReasoningEffort {
        didSet {
            let key = isApplyingConversationRecoveryOverride
                ? AttachePreferenceKey.presentationLLMRoleKey(.conversation, .reasoningEffort)
                : AttachePreferenceKey.presentationReasoningEffort
            defaults.set(presentationReasoningEffort, forKey: key)
            refreshPresentationStatus()
        }
    }
    @Published var presentationServiceTier: String = "default" {
        didSet {
            let key = isApplyingConversationRecoveryOverride
                ? AttachePreferenceKey.presentationLLMRoleKey(.conversation, .serviceTier)
                : AttachePreferenceKey.presentationServiceTier
            defaults.set(presentationServiceTier, forKey: key)
            refreshPresentationStatus()
        }
    }
    @Published var presentationAPIKey: String = ""
    @Published var presentationAPIKeySecretRef: String = "" {
        didSet {
            let key = isApplyingConversationRecoveryOverride
                ? AttachePreferenceKey.presentationLLMRoleKey(.conversation, .apiKeySecretRef)
                : AttachePreferenceKey.presentationLLMAPIKeySecretRef
            defaults.set(presentationAPIKeySecretRef, forKey: key)
            refreshPresentationStatus()
        }
    }
    @Published var presentationModelOptions: [AttachePresentationModelOption] = []
    @Published private(set) var presentationModelDiscoveryStatus: String = "Model discovery not checked"
    @Published private(set) var presentationStatus: String = "Presentation LLM not checked"
    // MARK: Per-role model overrides (Settings > Model > Advanced disclosure, INF-253/D3)
    //
    // A role missing from `roleModelProvider` means "Use main model": it falls
    // back to the main provider/model above, exactly like
    // `AttachePresentationSettings.load(role:)` already resolves an unset
    // per-role key (D2/INF-247). Populated once at launch by
    // `loadRoleModelOverrides()` and mutated only through `selectRoleProvider`,
    // `selectRoleModel`/`selectRoleModelID`, and `setRoleReasoningEffort`/
    // `setRoleServiceTier` below, which keep these dictionaries and the
    // matching `presentationLLMRoleKey` defaults entries in sync.
    @Published private(set) var roleModelProvider: [ModelRole: AttachePresentationProvider] = [:]
    @Published private(set) var roleModelID: [ModelRole: String] = [:]
    @Published private(set) var roleReasoningEffort: [ModelRole: String] = [:]
    @Published private(set) var roleServiceTier: [ModelRole: String] = [:]
    @Published private(set) var roleModelOptions: [ModelRole: [AttachePresentationModelOption]] = [:]
    @Published private(set) var roleModelDiscoveryStatus: [ModelRole: String] = [:]
    @Published private(set) var attacheMemoryStatus: String = "Memory not checked"
    @Published private(set) var speechVoiceOptions: [AttacheVoiceOption] = []
    @Published private(set) var elevenLabsVoiceOptions: [RemoteVoiceOption] = []
    @Published private(set) var xaiVoiceOptions: [RemoteVoiceOption] = []
    @Published private(set) var openaiVoiceOptions: [RemoteVoiceOption] = []
    @Published private(set) var voiceProviderStatus: String = "Voice provider not checked"
    @Published var speechProvider: AttacheSpeechProvider = .system {
        didSet {
            defaults.set(speechProvider.rawValue, forKey: AttachePreferenceKey.speechProvider)
            applySpeechConfiguration()
        }
    }
    @Published var speechVoiceIdentifier: String? {
        didSet {
            if let speechVoiceIdentifier {
                defaults.set(speechVoiceIdentifier, forKey: AttachePreferenceKey.speechVoiceIdentifier)
            } else {
                defaults.set(Self.systemVoicePreference, forKey: AttachePreferenceKey.speechVoiceIdentifier)
            }
            applySpeechConfiguration()
        }
    }
    @Published var elevenLabsAPIKey: String = "" {
        didSet { applySpeechConfiguration() }
    }
    @Published var elevenLabsVoiceID: String = "" {
        didSet {
            defaults.set(elevenLabsVoiceID, forKey: AttachePreferenceKey.elevenLabsVoiceID)
            applySpeechConfiguration()
        }
    }
    @Published var elevenLabsVoiceName: String = "" {
        didSet { defaults.set(elevenLabsVoiceName, forKey: AttachePreferenceKey.elevenLabsVoiceName) }
    }
    @Published var elevenLabsModelID: String = "eleven_flash_v2_5" {
        didSet {
            defaults.set(elevenLabsModelID, forKey: AttachePreferenceKey.elevenLabsModelID)
            applySpeechConfiguration()
        }
    }
    @Published var elevenLabsOutputFormat: String = "mp3_44100_128" {
        didSet {
            defaults.set(elevenLabsOutputFormat, forKey: AttachePreferenceKey.elevenLabsOutputFormat)
            applySpeechConfiguration()
        }
    }
    @Published var xaiAPIKey: String = "" {
        didSet { applySpeechConfiguration() }
    }
    @Published var xaiVoiceID: String = "" {
        didSet {
            defaults.set(xaiVoiceID, forKey: AttachePreferenceKey.xaiVoiceID)
            applySpeechConfiguration()
        }
    }
    @Published var xaiVoiceName: String = "" {
        didSet { defaults.set(xaiVoiceName, forKey: AttachePreferenceKey.xaiVoiceName) }
    }
    @Published var xaiBaseURL: String = "https://api.x.ai/v1" {
        didSet {
            defaults.set(xaiBaseURL, forKey: AttachePreferenceKey.xaiBaseURL)
            applySpeechConfiguration()
        }
    }
    @Published var xaiLanguage: String = "en" {
        didSet {
            defaults.set(xaiLanguage, forKey: AttachePreferenceKey.xaiLanguage)
            applySpeechConfiguration()
        }
    }
    @Published var openaiVoiceAPIKey: String = "" {
        didSet { applySpeechConfiguration() }
    }
    @Published var openaiVoiceID: String = "" {
        didSet {
            defaults.set(openaiVoiceID, forKey: AttachePreferenceKey.openaiVoiceID)
            applySpeechConfiguration()
        }
    }
    @Published var openaiVoiceName: String = "" {
        didSet { defaults.set(openaiVoiceName, forKey: AttachePreferenceKey.openaiVoiceName) }
    }

    let playback = SpeechPlaybackController()
    let micTranscript = MicTranscriptController()
    private let livePlaybackQueue = LivePlaybackQueue()
    /// Newest source time actually spoken per session, so a much-older event that
    /// finished preparing late is filed read instead of narrated as new (INF-163).
    private var lastSpokenSourceTime: [String: Date] = [:]
    /// Per-session tail of in-flight presentation work, chained so same-session
    /// events prepare and persist in arrival order (INF-163).
    private var sessionPrepareTasks: [String: Task<Void, Never>] = [:]
    private let mediaRemote = MediaRemoteController()
    private var cancellables = Set<AnyCancellable>()
    private var silenceTimer: Timer?
    private var revealTimer: Timer?
    private var conversationWaitTimer: Timer?
    private var conversationWaitStartedAt: Date?
    /// One hard deadline and identity per live personality request. Hanging up
    /// invalidates the identity immediately, so a late HTTP or CLI completion
    /// can never speak after the call has ended or leak into the next call.
    private var conversationRequestTimeoutTimer: Timer?
    /// Owned task for the current multi-round personality request. Hang-up and
    /// the hard request deadline cancel it, which stops any later corrective,
    /// tool-result, or final-answer egress instead of merely hiding its result.
    private var conversationRequestTask: Task<Void, Never>?
    private var conversationCompiledInference: (requestID: UUID, inference: AttacheInferenceMetadata)?
    private var activeConversationRequestID: UUID?
    private var activeConversationID: UUID?
    private static let conversationRequestTimeoutSeconds: TimeInterval = 90
    // @Published (rather than a plain var) so refreshCallPhase()'s Combine
    // subscription (setupConversationObservers()) picks up every transition,
    // including the ones driven from playback callbacks in init rather than
    // from a mutating method here.
    @Published private var expectingReplyAudio = false
    /// Tokens for in-flight narration composition (INF-264 follow-up): the
    /// LLM call that writes a watched session's spoken recap
    /// (`prepareAndPersist`, `AttachePresentationService.prepare`) runs
    /// entirely before `playback.isBusy` ever goes true, so without a signal
    /// of its own, a Tell Agent reply's recap-composing window had nothing
    /// to show once `.sendDelivered` moved past its own emphasis window.
    /// Keyed tokens rather than a plain counter or a single session ID so
    /// overlapping compositions across different watched sessions can't
    /// clobber each other's start/end bookkeeping; the value is the event's
    /// source raw value so `attacheActivity` can attribute the responding
    /// agent (INF-268).
    @Published private var composingNarrationTokens: [UUID: String] = [:]
    /// When the current "preparing a recap / its audio" burst began, for the
    /// agentResponding clock (INF-290). Reset each time composing and audio
    /// prep both idle, so the counter tracks the current update, not the sum
    /// of overlapping composes.
    private var respondingBurstStartedAt: Date?
    /// After this long, a still-"preparing" state is treated as a stalled
    /// compose and the crown falls back to calm rather than a runaway clock.
    private static let respondingSelfHealSeconds: TimeInterval = 20
    /// Failed instructions the user has moved past (snapshotted at call
    /// start): they stay in the Sent log but stop surfacing as a red error
    /// in the call composer. Memory-only on purpose; a relaunch re-surfaces
    /// an unresolved failure once, which is the right amount of nagging.
    private var acknowledgedFailedSendIDs: Set<String> = []
    /// The one semantic state every attache renderer consumes (INF-268).
    /// Refreshed at semantic rate through `refreshAttacheActivity()`'s
    /// choke point; renderers compose live audio per frame via
    /// `with(audio:)` from the `PlaybackTimeline` they already observe.
    @Published private(set) var attacheActivity: AttacheActivityState = .initial
    /// Debug override driven by the activity simulator panel
    /// (`ATTACHE_ACTIVITY_SIMULATOR=1`); nil means live derivation.
    @Published var simulatedActivity: AttacheActivityState? {
        didSet { refreshAttacheActivity() }
    }
    /// The user is typing in the app right now (occurrence only, no content;
    /// see `TypingActivityMonitor`).
    @Published private(set) var userTyping = false
    private let typingMonitor = TypingActivityMonitor()
    /// Dwell rules between raw derivation and what renderers see (INF-271):
    /// tool-call storms read as sustained activity instead of strobing. A
    /// held phase flips once its dwell elapses on the next refresh; the
    /// choke point's sources tick at least every 2 s, so the flip lands
    /// promptly without a dedicated timer.
    private let activityDamper = AttacheActivityDamper()
    /// When each watched session's attention last changed, so multi-session
    /// priority can prefer the most recent activity (INF-271).
    private var attentionChangedAt: [String: Date] = [:]
    /// The last exact attention state posted by a Claude Code lifecycle hook
    /// (Notification -> needs you, Stop -> done) with when it fired. It stays
    /// authoritative over the transcript classifier's guess until a transcript
    /// record lands after `firedAt`, i.e. until the session actually moves, so
    /// a guessed state never flips an exact one to a finished check.
    private var hookAttention: [String: (state: SessionAttentionState, firedAt: Date)] = [:]
    /// When each session began compacting its context (PreCompact), cleared on
    /// PostCompact. Only the focused session's value drives the character's squish.
    private var compactingSince: [String: Date] = [:]
    /// Live sub-agent counts per watched session (INF-275), from the
    /// watcher's transcript assessment.
    @Published private var subAgentCounts: [String: Int] = [:]
    /// The latest one-shot beat for renderers (celebrate, card pop, drowsy).
    /// Renderers queue and play these; publishing the next one never cancels
    /// an animation already running.
    @Published private(set) var attacheMoment: AttacheActivityMoment?
    /// How long a watcher phrase stays "fresh" enough to read as live tool
    /// activity. Tighter than the phrase's own 36s display lifetime so the
    /// character stops miming tools soon after the burst ends; INF-271 tunes this.
    private static let toolActivityDwell: TimeInterval = 10
    var activitySimulatorEnabled: Bool {
        ["1", "cycle"].contains(ProcessInfo.processInfo.environment["ATTACHE_ACTIVITY_SIMULATOR"])
    }
    /// `ATTACHE_ACTIVITY_SIMULATOR=cycle` starts the phase cycler on launch,
    /// so an unattended posed screenshot proves the override pipe without a
    /// human clicking the panel.
    var activitySimulatorAutoCycles: Bool {
        ProcessInfo.processInfo.environment["ATTACHE_ACTIVITY_SIMULATOR"] == "cycle"
    }
    private static let sessionIndexURL = AttacheAppSupport.supportDirectory().appendingPathComponent("SessionIndex.json")
    // AppModel is frequently constructed with CardStore.inMemory() in unit
    // tests. Do not even read the user's persisted session cache before init
    // has learned which store it received. Production replaces this inert
    // indexer in rebuildSessionIndexer().
    private var sessionIndexer = SessionIndexer(
        cacheURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-unconfigured-session-index-\(UUID().uuidString).json"),
        scanners: []
    )
    private let sessionIndexQueue = DispatchQueue(label: "com.bryanlabs.attache.sessionindex")
    @Published private(set) var sessionRecords: [SessionRecord] = []
    @Published private(set) var sessionIndexRevision = 0   // bumps on any record change, incl. new tags
    @Published private(set) var isIndexingSessions = false
    @Published private(set) var isTaggingSessions = false
    @Published private(set) var sessionRenames: [String: String] = [:]
    @Published private(set) var modelSessionDiscoveryPicker: ModelSessionDiscoveryPickerState?
    @Published private(set) var codexSourceEnabled = false
    @Published private(set) var claudeCodeSourceEnabled = false
    private lazy var curatedProjectPaths: [String] = Self.loadCuratedProjectPaths()
    let store: CardStore

    private var eventServer: LocalEventServer?
    private let projectPath = FileManager.default.currentDirectoryPath
    private let defaults = UserDefaults.standard
    private let codexSessionCatalog = CodexSessionCatalog()
    private var isRefreshingCatalog = false   // guards the off-main catalog load against overlap
    /// The in-flight model-discovery task, owned so a superseding call or a
    /// deallocated model cancels it. Unowned discovery tasks used to keep
    /// running after the unit test that spawned them finished, mutating
    /// shared UserDefaults state under later tests (the full-suite
    /// flakiness diagnosed on the INF-236 umbrella).
    private var modelDiscoveryTask: Task<Void, Never>?
    /// Two-way (send-to-agent) coordinator; set up in init once the store exists.
    private(set) var twoWay: TwoWayCoordinator!
    /// The instruction the user is currently confirming before it sends, if any.
    @Published var pendingInstruction: Instruction?
    @Published var agentInstructionSendPolicy: AgentInstructionSendPolicy = .defaultValue {
        didSet { defaults.set(agentInstructionSendPolicy.rawValue, forKey: AttachePreferenceKey.agentInstructionSendPolicy) }
    }
    var directAgentSendEnabled: Bool {
        get { agentInstructionSendPolicy.sendsDirectlyAfterSessionEnable }
        set { agentInstructionSendPolicy = newValue ? .directAfterSessionEnable : .confirmEveryInstruction }
    }
    /// Drives the first-use two-way enable sheet.
    @Published var showTwoWayEnable = false
    private var twoWayEnablePendingSend: PendingAgentSend?
    private let codexSessionWatcher = CodexSessionWatcher()
    private let sessionActivityWatcher = SessionActivityWatcher()
    private let presentationEnvironment: [String: String]
    private let presentationService: AttachePresentationService
    private let attacheMemoryStore: AttacheMemoryStore
    private var memoryRuntime: AttacheMemoryRuntime!
    private var directChatRuntime: AttacheDirectChatRuntime!
    private var sessionContextRuntime: SessionContextRuntime!
    private var activeExhaustiveReview: ActiveExhaustiveReviewContext?
    private var exhaustiveReviewTask: Task<Void, Never>?
    private var exhaustiveReviewExecutionID: UUID?
    private var exhaustiveReviewProviderExecutionID: UUID?
    private var exhaustiveReviewRefreshTask: Task<Void, Never>?
    private var exhaustiveReviewRefreshID: UUID?
    /// One cumulative evidence reserve per explicit user turn. Automatic
    /// provider fallback reuses it; a new user turn or hang-up replaces it.
    private var conversationSessionToolRuntime: SessionContextToolRuntime?
    private var codexSessionRefreshTimer: Timer?
    private var followUpAnswerRequestID: UUID?
    private var liveFollowUpAnswerRequestID: UUID?
    private var personalityPreviewRequestID: UUID?
    private static let systemVoicePreference = "system"
    private static let legacyAutoSelectedSamanthaVoiceID = "com.apple.voice.compact.en-US.Samantha"
    private static let elevenLabsDevelopmentSecretAccount = "elevenlabs-api-key"
    private static let xaiDevelopmentSecretAccount = "xai-api-key"
    private static let openaiDevelopmentSecretAccount = "openai-api-key"
    private static let codexSessionRefreshInterval: TimeInterval = 8

    @Published var personalities: [Personality] = []
    @Published var activePersonalityID: String = ""
    private let personalityStore = PersonalityStore()

    @Published var groqAPIKey: String = ""
    @Published var customAPIKey: String = "" {
        didSet { applySpeechConfiguration() }   // an OpenAI key here can power OpenAI voices too
    }
    @Published var integrationHealth: [String: IntegrationHealth] = [:]
    @Published var integrationFocusProviderID: String?
    private var integrationLastChecked: [String: Date] = [:]
    @Published var ollamaBaseURL: String = AttachePresentationProvider.ollama.defaultBaseURL {
        didSet { defaults.set(ollamaBaseURL, forKey: AttachePreferenceKey.ollamaBaseURL) }
    }
    @Published var customBaseURL: String = AttachePresentationProvider.custom.defaultBaseURL {
        didSet {
            defaults.set(customBaseURL, forKey: AttachePreferenceKey.customBaseURL)
            applySpeechConfiguration()
        }
    }

    init(store: CardStore? = nil) {
        let environment = ProcessInfo.processInfo.environment
        presentationEnvironment = environment
        presentationService = AttachePresentationService(environment: environment)
        attacheMemoryStore = AttacheMemoryStore(environment: environment)

        do {
            if let store {
                self.store = store
            } else {
                do {
                    self.store = try CardStore.defaultStore()
                } catch {
                    self.store = try CardStore.inMemory()
                    intakeStatus = "Saved history is unavailable; running in memory for this session."
                }
            }
            let memoryDatabaseURL: URL
            if self.store.isInMemory {
                memoryDatabaseURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("attache-memory-\(UUID().uuidString).sqlite")
            } else {
                memoryDatabaseURL = URL(fileURLWithPath: self.store.databasePath)
                    .deletingLastPathComponent()
                    .appendingPathComponent("AttacheMemory.sqlite")
            }
            memoryRuntime = AttacheMemoryRuntime(
                databaseURL: memoryDatabaseURL,
                legacySnapshot: attacheMemoryStore.loadSnapshot(),
                defaults: defaults
            )
            let directChatDatabaseURL: URL
            if self.store.isInMemory {
                directChatDatabaseURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("attache-direct-chat-\(UUID().uuidString).sqlite")
            } else {
                directChatDatabaseURL = URL(fileURLWithPath: self.store.databasePath)
                    .deletingLastPathComponent()
                    .appendingPathComponent("DirectChatSummaries.sqlite")
            }
            directChatRuntime = AttacheDirectChatRuntime(databaseURL: directChatDatabaseURL)
            let sessionContextDatabaseURL: URL
            if self.store.isInMemory {
                sessionContextDatabaseURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("attache-session-context-\(UUID().uuidString).sqlite")
            } else {
                sessionContextDatabaseURL = URL(fileURLWithPath: self.store.databasePath)
                    .deletingLastPathComponent()
                    .appendingPathComponent("SessionFTS.sqlite")
            }
            sessionContextRuntime = SessionContextRuntime(databaseURL: sessionContextDatabaseURL)
            loadPreferences()
            refreshMicrophoneDevices()
            loadPersonalities()
            refreshPresentationStatus()
            if !self.store.isInMemory {
                refreshCodexSessions(updateStatus: false)
            }
            resetLiveFollowUpAnswerStatus()
            _ = try? self.store.pruneArchivedCards()   // bound growth on launch (INF-170)
            reloadCards()
        } catch {
            fatalError("Unable to open \(AttacheAppSupport.appDisplayName) store: \(error.localizedDescription)")
        }

        twoWay = TwoWayCoordinator(
            store: self.store,
            locateSessionFile: { AttacheSessionReader.sessionFileURL(forSessionID: $0) },
            expiryWindow: InstructionReplyEngine.expiryWindow(fromEnvironment: environment)
        )
        if let recoveryMessage = twoWay.startupRecoveryMessage {
            intakeStatus = recoveryMessage
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.memoryRuntime.bind(to: .shared)
            self.bindExhaustiveReviewUI(to: .shared)
        }
        twoWay.onEventDrivenPump = { [weak self] changed in
            self?.handleTwoWayDeliveryChanges(changed)
        }

        playback.onFinished = { [weak self] cardID, success in
            self?.finishPlayback(cardID: cardID, success: success)
        }
        playback.onPreviewFinished = { [weak self] in
            if self?.expectingReplyAudio == true {
                if self?.pendingAssistantReply != nil {
                    self?.revealPendingReply()
                }
                self?.expectingReplyAudio = false
                self?.maybeResumeContinuousListening()
            }
            self?.resumeLiveQueueAfterReply()
        }
        playback.onPlaybackError = { [weak self] message in
            self?.intakeStatus = message
            self?.voiceProviderStatus = message
            self?.postHomeNotice(message, kind: .info, duration: 6)
            if self?.conversationActive == true, self?.expectingReplyAudio == true {
                self?.conversationStatus = "Voice playback failed. Reply was filed."
            }
        }
        setupMediaRemote()
        setupConversationObservers()
        setupAttacheActivityObservers()
        // Screenshot-matrix pose support (INF-244): inert unless
        // ATTACHE_UI_TEST_FORCE_LISTENING=1 rides alongside ATTACHE_UI_TEST=1
        // (see MicTranscriptController.shouldForceListeningForPose). Applied
        // right after setupConversationObservers() subscribes to
        // micTranscript.$isListening so the pose still reaches the first
        // callPhase refresh.
        micTranscript.applyForcedListeningPoseIfRequested(environment: environment)
        if !self.store.isInMemory {
            rebuildSessionIndexer()
            sessionRecords = filteredEnabledRecords(sessionIndexer.allRecords)
            refreshSessionIndex()
        }
        codexSessionWatcher.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.receive(event)
                // Event-driven delivery (INF-255/B4): session file activity the
                // watcher observed can mean a two-way send's session just went
                // quiet, so try a pump instead of waiting for the next periodic
                // timer tick. Debounced inside the coordinator so a burst of
                // rapid events collapses to one pump, not one per event. The
                // periodic timer (`startCodexSessionRefreshTimer`) is untouched
                // and remains the backstop for a session with no further event
                // to trigger this path.
                self?.twoWay.scheduleEventDrivenPump()
            }
        }
        codexSessionWatcher.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                self?.intakeStatus = status
            }
        }
        codexSessionWatcher.onAttention = { [weak self] sessionID, state, recordAt in
            DispatchQueue.main.async {
                self?.handleAttentionChange(sessionID: sessionID, state: state, recordTimestamp: recordAt)
            }
        }
        codexSessionWatcher.onSubAgents = { [weak self] sessionID, count in
            DispatchQueue.main.async {
                if count == 0 {
                    self?.subAgentCounts.removeValue(forKey: sessionID)
                } else {
                    self?.subAgentCounts[sessionID] = count
                }
            }
        }
        NotificationCenter.default.addObserver(forName: .attachePlayCard, object: nil, queue: .main) { [weak self] note in
            guard let self, let id = note.object as? String,
                  let card = self.cards.first(where: { $0.id == id }) else { return }
            self.playInboxCard(card)
        }
        NotificationCenter.default.addObserver(forName: .attacheFocusSession, object: nil, queue: .main) { [weak self] note in
            guard let self, let id = note.object as? String else { return }
            self.focusCodexSession(id)
        }
        // One quiet tip per launch, well after startup settles, never during
        // onboarding, playback, or a call.
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            self?.offerTipIfAppropriate()
        }
        sessionActivityWatcher.onPhrases = { [weak self] phrases in
            DispatchQueue.main.async {
                self?.activityPhrases = phrases
            }
        }
        applyMicConfiguration()
        if !self.store.isInMemory {
            updateCodexWatcher()
            startCodexSessionRefreshTimer()
        }
    }

    deinit {
        codexSessionRefreshTimer?.invalidate()
        conversationRequestTimeoutTimer?.invalidate()
        sessionActivityWatcher.stop()
        typingMonitor.stop()
        modelDiscoveryTask?.cancel()
    }

    var unreadCount: Int {
        cards.filter { $0.status == .unread }.count
    }

    var unreadCards: [VoicemailCard] {
        cards
            .filter { $0.status == .unread }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var scopedUnreadCards: [VoicemailCard] {
        unreadCards(for: inboxScope)
    }

    var focusedUnreadCount: Int {
        guard let attachedCodexSessionID else { return 0 }
        return unreadCount(forSessionID: attachedCodexSessionID)
    }

    var watchedUnreadCount: Int {
        let watchedIDs = Set(attachedTargets.keys)
        guard !watchedIDs.isEmpty else { return 0 }
        return unreadCards.filter { card in
            guard let sessionID = card.externalSessionID else { return false }
            return watchedIDs.contains(sessionID)
        }.count
    }

    var generalUnreadCount: Int {
        unreadCards.filter { Self.isGeneralVoicemailCard($0) }.count
    }

    var unreadCountsBySessionID: [String: Int] {
        Dictionary(grouping: unreadCards.compactMap(\.externalSessionID), by: { $0 })
            .mapValues(\.count)
    }

    func unreadCount(forSessionID sessionID: String) -> Int {
        unreadCountsBySessionID[sessionID] ?? 0
    }

    func unreadCards(for scope: VoicemailInboxScope) -> [VoicemailCard] {
        switch scope {
        case .all:
            return unreadCards
        case .focused:
            guard let attachedCodexSessionID else { return [] }
            return unreadCards.filter { $0.externalSessionID == attachedCodexSessionID }
        case .watched:
            let watchedIDs = Set(attachedTargets.keys)
            guard !watchedIDs.isEmpty else { return [] }
            return unreadCards.filter { card in
                guard let sessionID = card.externalSessionID else { return false }
                return watchedIDs.contains(sessionID)
            }
        case .codex:
            return unreadCards.filter { $0.sourceKind == SourceKind.codex.rawValue }
        case .claudeCode:
            return unreadCards.filter { $0.sourceKind == SourceKind.claudeCode.rawValue }
        }
    }

    func unreadCount(for scope: VoicemailInboxScope) -> Int {
        unreadCards(for: scope).count
    }

    func isGeneralVoicemailCard(_ card: VoicemailCard) -> Bool {
        Self.isGeneralVoicemailCard(card)
    }

    private static func isGeneralVoicemailCard(_ card: VoicemailCard) -> Bool {
        guard let sessionID = card.externalSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return true
        }
        return sessionID.hasPrefix("local-")
    }

    var selectedCard: VoicemailCard? {
        if let selectedCardID, let card = cards.first(where: { $0.id == selectedCardID }) {
            return card
        }
        return cards.first
    }

    /// The watch list: every attached session (id → target), watched concurrently so
    /// each one's updates become voicemails. Holds the target directly so a session
    /// from any tool resolves even when it isn't in the Codex catalog. One of these is
    /// the focused session (`attachedCodexSessionID`).
    @Published private(set) var attachedTargets: [String: CodexSessionTarget] = [:] {
        didSet { persistWatchedSessions() }
    }

    /// The focused session: the one you look at and would call. Updates from it speak
    /// live while you're on a call; the rest of the watch list just collects voicemail.
    var attachedCodexSession: CodexSessionTarget? {
        guard let attachedCodexSessionID else { return nil }
        if let target = attachedTargets[attachedCodexSessionID] { return target }
        return (codexSessions + archivedCodexSessions)
            .first { $0.id == attachedCodexSessionID }
    }

    /// All attached sessions for the UI (focused first), sorted by most recent.
    var attachedSessionList: [CodexSessionTarget] {
        attachedTargets.values.sorted { lhs, rhs in
            if (lhs.id == attachedCodexSessionID) != (rhs.id == attachedCodexSessionID) {
                return lhs.id == attachedCodexSessionID
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    /// The only work session a conversation may read. Watching a session and
    /// focusing it are explicit user actions; recency, a selected voicemail,
    /// and an indexed transcript are never authorization to attach context.
    /// A nil value still permits a context-free conversation with the character.
    var talkContextSession: CodexSessionTarget? {
        attachedCodexSession
    }

    /// The call's immutable, explicitly focused context while live. Nil means
    /// the call is character-only and carries no work-session context or tools.
    var conversationContextSession: CodexSessionTarget? {
        if conversationActive || isConversing || pendingAssistantReply != nil {
            return conversationTargetSnapshot?.target
        }
        return attachedCodexSession
    }

    private func captureConversationTargetSnapshot() -> ConversationTargetSnapshot? {
        guard let focused = attachedCodexSession else { return nil }
        synchronizeSessionContextFocus()
        let authority = sessionContextRuntime.authoritySnapshot().session
        let authorized = authority?.sessionID == focused.id
            && authority?.sourceKind == focused.sourceKind.rawValue
            ? authority
            : nil
        return ConversationTargetSnapshot(
            target: focused,
            workingDirectory: workingDirectory(for: focused.id),
            focusedSession: authorized
        )
    }

    /// Resolve the profile prompt for a personality using the single authority
    /// precedence (INF-304): explicit environment override, then the selected
    /// personality's prompt, then the built-in default. The legacy file store is
    /// a migration input, not a runtime authority, so it never participates.
    private func resolvedProfilePrompt(for personality: Personality?) -> String {
        let testOverride = presentationEnvironment["ATTACHE_PERSONALITY_PROMPT"]
            ?? presentationEnvironment["ATTACHE_PROFILE_PROMPT"]
            ?? presentationEnvironment["COMPANION_PERSONALITY_PROMPT"]
        return AttacheRequestAuthority.resolvedProfilePrompt(
            testOverride: testOverride,
            selectedPersonalityPrompt: personality?.prompt ?? "",
            migratedLegacyPrompt: nil
        )
    }

    /// Freeze the immutable authority boundary for one model request (INF-304).
    /// Captures the active personality, resolved profile prompt, memory scope,
    /// user input, and session authorization before any async work begins. The
    /// legacy file store is a migration input, not a runtime authority, so the
    /// selected personality's prompt wins; only an explicit environment override
    /// beats it.
    func captureRequestSnapshot(
        role: AttacheRequestRole,
        userInput: String,
        personalityOverride: Personality? = nil,
        settingsOverride: AttachePresentationSettings? = nil
    ) -> AttacheRequestSnapshot {
        let personality = personalityOverride ?? activePersonality ?? Personality.builtIns[0]
        let session = requestSessionAuthorization(for: role)
        let profilePrompt = resolvedProfilePrompt(for: personality)
        let contextStrategy = AttacheContextStrategy.resolving(
            override: personality.contextStrategy,
            global: AttacheContextUIState.persistedGlobalStrategy(defaults: defaults)
        )
        let unresolvedSettings = settingsOverride ?? AttachePresentationSettings.load(
            role: Self.modelRole(for: role),
            defaults: defaults,
            environment: presentationEnvironment,
            resolveSecrets: false
        )
        let requestSettings: AttachePresentationSettings
        if let settingsOverride {
            requestSettings = settingsOverride
        } else if unresolvedSettings.llmEnabled,
                  unresolvedSettings.hasProviderConfiguration {
            requestSettings = AttachePresentationSettings.load(
                role: Self.modelRole(for: role),
                defaults: defaults,
                environment: presentationEnvironment
            )
        } else {
            requestSettings = unresolvedSettings
        }
        let requestIsRemote = requestSettings.provider
            .dataEgress(endpoint: requestSettings.baseURL.absoluteString)
            // Memory's `localOnly` contract means this Mac, not this network.
            // LAN inference is intentionally consent-light, but it still crosses
            // the memory egress boundary and must exclude local-only records.
            .isRemote
        let consentScope = PresentationConsentScope(
            provider: requestSettings.provider,
            endpoint: requestSettings.baseURL.absoluteString
        )
        let consentedScopes = Set(
            defaults.array(forKey: AttachePreferenceKey.cloudConsentPresentationProviders)
                as? [String] ?? []
        )
        let modelSettings = requestSettings.llmEnabled
            && requestSettings.hasProviderConfiguration
            && requestSettings.isConfigured
            && (!consentScope.egress.isRemoteService || consentedScopes.contains(consentScope.storageKey))
            ? requestSettings
            : nil
        var contextItems: [AttacheContextItem] = []
        var memoryReceipt: [AttacheMemoryReceiptEntry] = []
        var directChatMessages: [AttacheChatMessage] = []
        var directChatMessageSources: [AttachePrebuiltMessageSource] = []

        if Self.roleUsesDurableMemory(role) {
            // A hang-up is a hard boundary. Prior call turns may remain in the
            // visible UI until the next call starts, but they must not steer
            // memory retrieval for an off-call voicemail follow-up or any new
            // request. Only the active call may contribute retrieval terms.
            let recent = conversationActive
                && (role == .conversation || role == .liveFollowUp)
                ? conversationMessages.suffix(8).map(\.text).joined(separator: "\n")
                : ""
            let selected = memoryRuntime.contextItems(
                userTurn: userInput,
                personalityID: personality.id,
                explicitTopic: memoryRuntime.explicitTopic(matching: userInput),
                recentDirectChatContext: recent.isEmpty ? nil : recent,
                strategy: contextStrategy,
                memoryBudgetTokens: Self.memoryBudget(for: contextStrategy),
                requestIsRemote: requestIsRemote
            )
            contextItems.append(contentsOf: selected.items)
            memoryReceipt = selected.receipt
        }

        if role == .conversation, case .focused = session,
           let latest = conversationLatestAgentCard,
           latest.externalSessionID == session.focusedSession?.sessionID {
            contextItems.append(AttacheContextItem(
                source: .latestAgentReply,
                content: latest.rawText,
                provenance: "focused-latest-reply:\(latest.id)",
                authorization: session,
                priority: 700,
                treatment: .headTailExcerpt
            ))
        }
        if role == .conversation, let callID = activeConversationID {
            let capability = AttachePresentationModelService.capabilityProfile(
                provider: requestSettings.provider,
                baseURLText: requestSettings.baseURL.absoluteString,
                modelID: requestSettings.model
            )
            let directChat = directChatRuntime.capture(
                turns: conversationMessages,
                callID: callID,
                strategy: contextStrategy,
                capability: capability,
                userInput: userInput,
                profilePrompt: profilePrompt
            )
            contextItems.append(contentsOf: directChat.summaryItems)
            directChatMessages = directChat.exactMessages
            directChatMessageSources = directChat.exactMessageSources
        }
        return AttacheRequestSnapshot(
            role: role,
            personality: personality,
            profilePrompt: profilePrompt,
            userInput: userInput,
            session: session,
            modelSettings: modelSettings,
            contextItems: contextItems,
            contextStrategy: contextStrategy,
            memorySelectionReceipt: memoryReceipt,
            directChatMessages: directChatMessages,
            directChatMessageSources: directChatMessageSources
        )
    }

    private func requestSessionAuthorization(for role: AttacheRequestRole) -> AttacheSessionAuthorization {
        switch role {
        case .conversation:
            return conversationTargetSnapshot?.focusedSession.map(AttacheSessionAuthorization.focused)
                ?? .contextFree
        case .liveFollowUp:
            if let frozen = conversationTargetSnapshot?.focusedSession {
                return .focused(frozen)
            }
            synchronizeSessionContextFocus()
            guard let focused = sessionContextRuntime.authoritySnapshot().session,
                  focused.sessionID == attachedCodexSession?.id else { return .contextFree }
            return .focused(focused)
        case .presentation, .recap, .followUp, .anotherTake, .preview, .topicTagging:
            return .contextFree
        }
    }

    private static func roleUsesDurableMemory(_ role: AttacheRequestRole) -> Bool {
        switch role {
        case .conversation, .followUp, .liveFollowUp: return true
        case .presentation, .recap, .anotherTake, .preview, .topicTagging: return false
        }
    }

    private static func memoryBudget(for strategy: AttacheContextStrategy) -> Int {
        switch strategy.kind {
        case .efficient: return 1_024
        case .automatic: return 2_048
        case .maximumCoverage: return 4_096
        case .custom:
            return min(max(strategy.custom?.effectiveInputLimit.map { $0 / 8 } ?? 2_048, 512), 16_384)
        }
    }

    private static func modelRole(for role: AttacheRequestRole) -> ModelRole {
        switch role {
        case .recap: return .recap
        case .topicTagging: return .tagging
        case .conversation, .followUp, .liveFollowUp: return .conversation
        case .presentation, .anotherTake, .preview: return .presentation
        }
    }

    var attachedCodexSessionLabel: String {
        if let session = attachedCodexSession {
            return session.displayTitle
        }
        return "No session attached"
    }

    var databasePath: String { store.databasePath }

    var currentVoiceSummary: String {
        if voicePlaybackFallbackDescription != nil {
            return "On-device fallback"
        }
        switch speechProvider {
        case .system:
            if let speechVoiceIdentifier,
               let option = speechVoiceOptions.first(where: { $0.id == speechVoiceIdentifier }) {
                return "On-device \(option.title)"
            }
            if let fallbackIdentifier = AttacheVoiceCatalog.fileExportFallbackVoiceID(),
               let option = speechVoiceOptions.first(where: { $0.id == fallbackIdentifier }) {
                return "On-device \(option.title)"
            } else {
                return "On-device system default"
            }
        case .elevenLabs:
            return elevenLabsVoiceName.isEmpty ? "ElevenLabs voice not selected" : "ElevenLabs \(elevenLabsVoiceName)"
        case .xai:
            return xaiVoiceName.isEmpty ? "xAI \(xaiVoiceID)" : "xAI \(xaiVoiceName)"
        case .openai:
            return openaiVoiceName.isEmpty ? "OpenAI \(openaiVoiceID)" : "OpenAI \(openaiVoiceName)"
        }
    }

    var voicePlaybackFallbackDescription: String? {
        guard let reason = selectedSpeechConfiguration.playbackUnavailableReason else { return nil }
        return "\(reason) Playback will use an on-device voice."
    }

    var presentationProviderSummary: String {
        "\(presentationProvider.title) \(presentationModel)"
    }

    var presentationRequiresAPIKey: Bool {
        presentationProvider.requiresAPIKey
    }

    var selectedPresentationReasoningOptions: [String] {
        if let option = presentationModelOptions.first(where: { $0.id == presentationModel }) {
            return option.reasoningEfforts
        }
        return AttachePresentationModelService.fallbackReasoningEfforts(
            provider: presentationProvider,
            modelID: presentationModel
        )
    }

    /// True when the selected main model is discovered and reports no
    /// reasoning levels (an Ollama Qwen, for example), so Settings can say
    /// so instead of offering knobs that do nothing (INF-286).
    var selectedPresentationModelLacksReasoning: Bool {
        guard let option = presentationModelOptions.first(where: { $0.id == presentationModel }) else {
            return false
        }
        return option.reasoningEfforts.isEmpty
    }

    /// Role-override flavor of `selectedPresentationModelLacksReasoning`.
    func roleModelLacksReasoning(for role: ModelRole) -> Bool {
        guard let provider = roleModelProvider[role] else { return false }
        let modelID = roleModelID[role] ?? provider.defaultModel
        guard let option = (roleModelOptions[role] ?? []).first(where: { $0.id == modelID }) else {
            return false
        }
        return option.reasoningEfforts.isEmpty
    }

    var selectedPresentationServiceTierOptions: [AttachePresentationServiceTierOption] {
        let options: [AttachePresentationServiceTierOption]
        if let option = presentationModelOptions.first(where: { $0.id == presentationModel }) {
            options = option.serviceTiers
        } else {
            options = AttachePresentationModelService.fallbackServiceTierOptions(
                provider: presentationProvider,
                modelID: presentationModel
            )
        }
        guard !options.isEmpty else { return [] }
        if options.contains(where: { $0.id == "default" }) {
            return options
        }
        return [AttachePresentationServiceTierOption(
            id: "default",
            title: "Default",
            detail: "Use the provider default"
        )] + options
    }

    func startEventServer() {
        do {
            let (token, _) = try LocalEventServer.provisionToken()
            let server = try LocalEventServer(port: 7531, token: token) { [weak self] body in
                DispatchQueue.main.async {
                    self?.ingestEventData(body)
                }
            } commandHandler: { [weak self] command in
                DispatchQueue.main.async {
                    self?.handle(command)
                }
                return self?.canHandle(command) ?? false
            }
            eventServer = server
            server.start()
            serverURLText = "http://127.0.0.1:7531/events"
            // A pending two-way restart-recovery message (set above in init,
            // from `TwoWayCoordinator.startupRecoveryMessage`) is safety-
            // relevant (docs/two-way.md, "Restart fails closed": "the same
            // message is surfaced in the app's status area on launch") and
            // must not be silently clobbered by this routine status before
            // the window is even shown; `startEventServer()` runs
            // synchronously right after init, before the window appears
            // (INF-256/E4).
            if twoWay.startupRecoveryMessage == nil {
                intakeStatus = "Listening on \(serverURLText)."
            }
            applyClaudeHooks()
        } catch {
            intakeStatus = "Event intake blocked: \(error.localizedDescription)"
        }
    }

    /// Install or remove Attaché's Claude Code hooks off the main thread (small
    /// file IO). Idempotent, so calling it on launch and on every toggle is
    /// cheap. Under UI tests, skip it so a headless run never edits real
    /// Claude Code settings.
    func applyClaudeHooks() {
        guard ProcessInfo.processInfo.environment["ATTACHE_UI_TEST"] != "1" else { return }
        let enabled = installClaudeHooks
        DispatchQueue.global(qos: .utility).async {
            ClaudeHookSetup.apply(enabled: enabled)
        }
    }

    func reloadCards(select cardID: String? = nil) {
        do {
            // Bound the fetch so months of watched sessions don't grow the
            // main-thread scan without limit; the inbox shows the most recent
            // window (INF-170).
            cards = try store.fetchCards(limit: Self.maxLoadedCards)
            let storedReceipts = cards.compactMap { card in
                card.contextReceipt.map { (card.id, $0) }
            }
            if !storedReceipts.isEmpty {
                Task { @MainActor in
                    for (cardID, receipt) in storedReceipts {
                        AttacheContextUIState.shared.publishReceipt(receipt, responseID: cardID)
                    }
                }
            }
            if let cardID {
                selectedCardID = cardID
            } else if selectedCardID == nil || !cards.contains(where: { $0.id == selectedCardID }) {
                selectedCardID = cards.first?.id
            }
            loadAttachedSessionHistory()
        } catch {
            intakeStatus = "Storage read failed: \(error.localizedDescription)"
        }
    }

    @Published var newlyDownloadedVoice: AttacheVoiceOption?

    func startOnboarding() {
        showOnboarding = true
    }

    /// Called when the app becomes active while onboarding is up: a fresh
    /// helper process re-reads the voice registry (the in-process copy is
    /// cached for the process lifetime) and flags a premium voice the user
    /// downloaded mid-flow so the sheet can offer a one-click relaunch.
    func detectNewlyDownloadedVoice() {
        guard showOnboarding, newlyDownloadedVoice == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self,
                  let fresh = AttacheVoiceCatalog.freshOptions() else { return }
            DispatchQueue.main.async {
                self.newlyDownloadedVoice = AttacheVoiceCatalog.newlyAvailableVoice(
                    fresh: fresh, current: self.speechVoiceOptions)
            }
        }
    }

    /// Relaunches the app, resuming onboarding at the given step with the
    /// freshly downloaded voice auto-selected on the way back in.
    func relaunchForNewVoice(resumeStep: Int) {
        if let voice = newlyDownloadedVoice {
            speechVoiceIdentifier = voice.id
        }
        defaults.set(resumeStep, forKey: AttachePreferenceKey.onboardingResumeStep)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// The persisted resume step, cleared on read.
    func takeOnboardingResumeStep() -> Int? {
        guard defaults.object(forKey: AttachePreferenceKey.onboardingResumeStep) != nil else { return nil }
        let step = defaults.integer(forKey: AttachePreferenceKey.onboardingResumeStep)
        defaults.removeObject(forKey: AttachePreferenceKey.onboardingResumeStep)
        return step
    }

    func completeOnboarding() {
        defaults.set(true, forKey: AttachePreferenceKey.onboardingCompleted)
        showOnboarding = false
    }

    /// Onboarding's final step: a demo event through the normal pipeline,
    /// then play the resulting card so the first spoken recap happens inside
    /// the welcome flow.
    func onboardingProveTheLoop() {
        simulateEvent()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            if let card = self.cards.first(where: { $0.status == .unread }) ?? self.cards.first {
                self.playInboxCard(card)
            }
        }
    }

    func simulateEvent() {
        var event = EventNormalizer.simulatedEvent(projectPath: projectPath)
        if let attachedCodexSessionID {
            event.externalSessionID = attachedCodexSessionID
            event.metadata["attached_codex_session_id"] = attachedCodexSessionID
        }
        receive(event)
    }

    func ingestEventData(_ data: Data) {
        do {
            var event = try EventNormalizer.decode(data: data)
            // HTTP hooks don't carry a source time; stamp receipt time so ordering
            // and dedup have a stable timeline (INF-163).
            if event.metadata["source_time"] == nil {
                event.metadata["source_time"] = PipelineOrdering.isoString(from: Date())
            }
            receive(event)
        } catch {
            intakeStatus = "Event blocked: \(error.localizedDescription)"
        }
    }

    func receive(_ event: NormalizedEvent) {
        // Exact needs-you tier from the local bridge (e.g. a Claude Code
        // Notification hook posting event_type "needs_attention"): filed
        // instantly with no LLM pass, cleared automatically once the
        // session's transcript moves again.
        if event.eventType == "needs_attention" {
            var notice = event
            notice.metadata["companion_needs_decision"] = "1"
            notice.metadata["companion_notice"] = "needs_attention"
            if let sessionID = event.externalSessionID {
                // Exact waiting-on-you from Claude Code's Notification hook.
                // Record it as a hook state so the transcript classifier can't
                // flip it to a finished check while the ask is still pending.
                let wasNeeding = sessionAttention[sessionID]?.needsUser ?? false
                hookAttention[sessionID] = (state: .awaitingAnswer, firedAt: Date())
                sessionAttention[sessionID] = .awaitingAnswer
                attentionChangedAt[sessionID] = Date()
                if !wasNeeding {
                    attacheMoment = AttacheActivityMoment(
                        kind: .needsYou, agent: agentIdentity(forSessionID: sessionID), at: Date()
                    )
                }
            }
            persistNeedsYouNotice(event: notice, line: event.text)
            return
        }
        // Exact turn completion from Claude Code's Stop hook. The character's finished
        // check comes only from this, never from a transcript quiet-gap guess.
        if event.eventType == "turn_complete" {
            if let sessionID = event.externalSessionID {
                handleAttentionChange(sessionID: sessionID, state: .turnComplete, fromHook: true)
            }
            return
        }
        // Instant "working" on prompt submit (UserPromptSubmit hook), so the
        // orbit starts immediately instead of waiting for the transcript poll.
        if event.eventType == "turn_started" {
            if let sessionID = event.externalSessionID {
                handleAttentionChange(sessionID: sessionID, state: .active, fromHook: true)
            }
            return
        }
        // Sustained, focus-tied compaction: the focused session's squish ramps
        // while this holds (PreCompact -> PostCompact).
        if event.eventType == "compact_start" {
            if let sid = event.externalSessionID {
                compactingSince[sid] = Date()
                refreshAttacheActivity()
            }
            return
        }
        if event.eventType == "compact_end" {
            if let sid = event.externalSessionID {
                compactingSince.removeValue(forKey: sid)
                refreshAttacheActivity()
            }
            return
        }
        // One-shot character moments from the other lifecycle hooks (errored, greet,
        // farewell, configuring).
        if let momentKind = Self.momentKind(forEventType: event.eventType) {
            let agent = event.externalSessionID.map { agentIdentity(forSessionID: $0) } ?? .none
            attacheMoment = AttacheActivityMoment(kind: momentKind, agent: agent, at: Date())
            return
        }
        intakeStatus = event.source == SourceKind.codex.rawValue
            ? "Preparing Codex spoken update."
            : "Preparing spoken update."
        // Serialize presentation per session so a slow LLM call for an earlier
        // event can't let a later one's card land first. Different sessions still
        // prepare concurrently (INF-163).
        let key = event.externalSessionID ?? "local-\(event.source)"
        let personality = activePersonality
        let previous = sessionPrepareTasks[key]
        sessionPrepareTasks[key] = Task { [weak self] in
            _ = await previous?.value
            await self?.prepareAndPersist(event, personality: personality)
        }
    }

    // MARK: Needs-you attention (INF-179)

    /// A watched session's attention state changed. Entering a needs-user
    /// state files a priority notice; leaving it clears any unread notices so
    /// the inbox never claims an agent is waiting after it moved on.
    func handleAttentionChange(sessionID: String, state: SessionAttentionState,
                               recordTimestamp: Date? = nil, fromHook: Bool = false) {
        if fromHook {
            hookAttention[sessionID] = (state: state, firedAt: Date())
            applyAttentionState(sessionID: sessionID, state: state)
            return
        }
        // Classifier path: an exact hook state stays authoritative until the
        // transcript advances past when the hook fired, so a guessed state
        // never stomps it (a still-working or waiting-on-you session was
        // flipping to a finished check).
        if let hook = hookAttention[sessionID] {
            let advanced = (recordTimestamp.map { $0 > hook.firedAt }) ?? false
            guard advanced else { return }
            hookAttention.removeValue(forKey: sessionID)
        }
        applyAttentionState(sessionID: sessionID, state: state)
    }

    private func applyAttentionState(sessionID: String, state: SessionAttentionState) {
        let previous = sessionAttention[sessionID]
        let effective: SessionAttentionState? = (state == .quiet) ? nil : state
        // Idempotent: the watcher also emits when only the newest record moved,
        // so a repeat of the same effective state is a no-op. This avoids churn
        // and never resets the changed-at time multi-session priority reads.
        guard effective != previous else { return }
        attentionChangedAt[sessionID] = Date()
        AttacheLog.watcher.info("attention \(String(sessionID.prefix(8)), privacy: .public): \(String(describing: previous), privacy: .public) -> \(String(describing: state), privacy: .public)")
        sessionAttention[sessionID] = effective
        let wasNeeding = previous?.needsUser ?? false
        if state.needsUser, !wasNeeding {
            fileNeedsYouNotice(sessionID: sessionID, state: state)
            attacheMoment = AttacheActivityMoment(
                kind: .needsYou, agent: agentIdentity(forSessionID: sessionID), at: Date()
            )
        } else if !state.needsUser, wasNeeding {
            resolveNeedsYouNotices(sessionID: sessionID)
        }
        // One-shot beats for the character (INF-271): a finished turn celebrates,
        // a still-pinned session going stale yawns. Transitions only, so a
        // first classification after attach never fires a stale celebration.
        if previous == .active, state == .turnComplete {
            attacheMoment = AttacheActivityMoment(
                kind: .celebrate, agent: agentIdentity(forSessionID: sessionID), at: Date()
            )
        } else if state == .quiet, previous != nil, attachedTargets[sessionID] != nil {
            attacheMoment = AttacheActivityMoment(
                kind: .drowsy, agent: agentIdentity(forSessionID: sessionID), at: Date()
            )
        }
        if let moment = attacheMoment, moment.at.timeIntervalSinceNow > -1 {
            AttacheLog.watcher.info("attache moment \(moment.kind.rawValue, privacy: .public) for \(moment.agent.rawValue, privacy: .public) (attention \(String(describing: previous), privacy: .public) -> \(String(describing: state), privacy: .public))")
        }
    }

    var anyWatchedSessionNeedsUser: Bool {
        sessionAttention.values.contains(where: \.needsUser)
    }

    /// The state half of the fleet summary ("2 running · 1 needs you"), shared
    /// by the watching rail and the menu bar. Nil when everything is quiet.
    var fleetStateSummary: String? {
        let running = sessionAttention.values.filter { $0 == .active }.count
        let needs = sessionAttention.values.filter(\.needsUser).count
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if needs > 0 { parts.append("\(needs) \(needs == 1 ? "needs" : "need") you") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func fileNeedsYouNotice(sessionID: String, state: SessionAttentionState) {
        let target = attachedTargets[sessionID]
        let title = sessionRecords.first(where: { $0.id == sessionID }).map(displaySessionTitle)
            ?? target?.displayTitle
            ?? "a session"
        let sourceName = target?.sourceKind.displayName ?? "Your agent"
        let line: String
        switch state {
        case .awaitingAnswer:
            line = "\(sourceName) is waiting on your answer in \(title)."
        default:
            line = "\(sourceName) may be waiting on you in \(title)."
        }
        let event = NormalizedEvent(
            source: target?.sourceKind.rawValue ?? SourceKind.claudeCode.rawValue,
            eventType: "needs_attention",
            externalSessionID: sessionID,
            projectPath: nil,
            title: title,
            text: line,
            metadata: [
                "companion_needs_decision": "1",
                "companion_notice": "needs_attention"
            ]
        )
        persistNeedsYouNotice(event: event, line: line)
    }

    private func persistNeedsYouNotice(event: NormalizedEvent, line: String) {
        do {
            let card = try store.insertEvent(event)
            reloadCards()
            intakeStatus = line
            // The banner is the alert: delivery, sound, and any spoken
            // announcement follow the user's macOS notification settings
            // (Announce Notifications), never a voice of our own.
            if notifyScope.allowsNeedsYou {
                AttacheNotifier.shared.post(card: card, kind: .needsYou)
            }
        } catch {
            intakeStatus = "Could not file a needs-you notice."
        }
    }

    /// Hook-tier notices belong to sessions the transcript watcher may not
    /// cover, so archiving the last open notice clears the urgency instead of
    /// leaving the dock alarmed forever. Watched sessions stay owned by the
    /// transcript classifier.
    private func pruneResolvedAttention() {
        for (id, state) in sessionAttention where state.needsUser {
            guard attachedTargets[id] == nil else { continue }
            let hasOpenNotice = cards.contains { card in
                card.externalSessionID == id
                    && card.status == .unread
                    && metadataDictionary(for: card)["companion_notice"] == "needs_attention"
            }
            if !hasOpenNotice {
                sessionAttention.removeValue(forKey: id)
                hookAttention.removeValue(forKey: id)
                compactingSince.removeValue(forKey: id)
            }
        }
    }

    private func offerTipIfAppropriate() {
        guard showTips,
              defaults.bool(forKey: AttachePreferenceKey.onboardingCompleted),
              !onCall,
              !playback.isBusy,
              ProcessInfo.processInfo.environment["ATTACHE_UI_TEST"] == nil,
              let tip = tipEngine.nextTip() else { return }
        postHomeNotice(tip.text, kind: .info, duration: 9)
    }

    private func resolveNeedsYouNotices(sessionID: String) {
        let notices = cards.filter { card in
            card.externalSessionID == sessionID
                && card.status == .unread
                && metadataDictionary(for: card)["companion_notice"] == "needs_attention"
        }
        guard !notices.isEmpty else { return }
        archiveCards(notices)
        intakeStatus = "Cleared a needs-you notice; the session moved on."
    }

    private func prepareAndPersist(_ event: NormalizedEvent, personality: Personality?) async {
        // Marks this composition in flight for the whole LLM call below, so
        // the live call composer has something to show (INF-264 follow-up:
        // `CallSignals.isComposingNarration`) instead of going blank while a
        // Tell Agent reply's recap is being written. Same main-actor-hop
        // reasoning as `persist` below applies to every mutation here.
        let token = UUID()
        await MainActor.run { composingNarrationTokens[token] = event.source }
        let snapshot = captureRequestSnapshot(
            role: .presentation,
            userInput: event.text,
            personalityOverride: personality
        )
        let presented: AttachePreparedEventResult = await withCheckedContinuation { continuation in
            presentationService.prepare(event, snapshot: snapshot) { presentedEvent in
                continuation.resume(returning: presentedEvent)
            }
        }
        // persist() mutates observed @Published state (the card list, playback
        // queue, intake status). It runs from a background Task here, so it must
        // hop to the main actor: mutating @Published off-main makes SwiftUI flush
        // a transaction synchronously and re-enter body, overflowing the stack.
        await MainActor.run {
            composingNarrationTokens.removeValue(forKey: token)
            persist(presented.event)
        }
    }

    private func persist(_ event: NormalizedEvent) {
        do {
            let card = try store.insertEvent(event)
            // If this narration is the agent's reply to an instruction we sent,
            // link it so the delivery log can jump to it (INF-173).
            if let sessionID = event.externalSessionID {
                twoWay?.linkResponseCard(
                    cardID: card.id,
                    sessionID: sessionID,
                    eventText: event.text,
                    transcriptEndOffset: event.metadata["transcript_end_offset"].flatMap(Int64.init)
                )
            }
            // A late-arriving event whose source time predates the newest already
            // spoken update for this session is filed read, not narrated as new.
            let sessionKey = event.externalSessionID ?? "local-\(event.source)"
            if let eventTime = event.metadata["source_time"].flatMap(PipelineOrdering.date(from:)),
               PipelineOrdering.isStale(eventTime: eventTime, newestSpokenTime: lastSpokenSourceTime[sessionKey]) {
                try? store.markHeard(cardID: card.id)
                reloadCards()
                intakeStatus = "Filed a late out-of-order update as read."
                return
            }
            if shouldPlayLive(event) {
                reloadCards(select: card.id)
                // The card stays unread until it has actually been spoken; the
                // queue decides whether to play now or hold it. Heard state is set
                // in finishPlayback on success, never before synthesis.
                livePlaybackQueue.reconcile(isBusy: playback.isBusy)
                if let toPlay = livePlaybackQueue.enqueue(card.id, isBusy: playback.isBusy) {
                    playCardLive(cardID: toPlay)
                    intakeStatus = "Playing attached \(card.sourceDisplayName) update live."
                } else {
                    intakeStatus = "Queued attached \(card.sourceDisplayName) update until current playback finishes."
                }
            } else {
                if selectedCardID == nil {
                    reloadCards(select: card.id)
                } else {
                    reloadCards()
                }
                intakeStatus = "Queued \(card.sourceDisplayName) update in voicemail for \(card.projectPath ?? "unknown project")."
                attacheMoment = AttacheActivityMoment(
                    kind: .cardArrived,
                    agent: AttacheAgentIdentity(sourceKindRawValue: card.sourceKind),
                    at: Date()
                )
                if voicemailMode, notifyScope.allowsRecaps {
                    AttacheNotifier.shared.post(card: card, kind: .recap)
                }
                postHomeNotice(
                    "New voicemail\(card.sessionTitle.map { " · \($0)" } ?? "")",
                    kind: .voicemail,
                    duration: 4.5
                )
            }
        } catch {
            intakeStatus = "Card creation failed: \(error.localizedDescription)"
        }
    }

    /// Right-click affordance on the mini attache (INF-272): replay the
    /// newest update without opening the main window.
    func replayLastUpdate() {
        guard let card = cards.max(by: { $0.createdAt < $1.createdAt }) else { return }
        playInboxCard(card)
    }

    /// Hear an "another take" of a card in a different personality's voice
    /// (INF-299). Switches to the target personality, asks the model for its own
    /// spin on the original, then files and plays a linked card. A live-call
    /// clarification carries the call id that requested it; hanging up makes a
    /// late result inert. Explicit off-call Another Take actions pass no call id.
    func anotherTake(
        card: VoicemailCard,
        targetPersonalityID: String,
        requiredCallID: UUID? = nil
    ) {
        guard let target = personalities.first(where: { $0.id == targetPersonalityID }) else { return }
        let explicitAuthorization = AnotherTakeRequestAuthorization.explicit(card: card)
        guard let currentCard = cards.first(where: { $0.id == card.id }),
              explicitAuthorization.authorizes(currentCard) else {
            intakeStatus = "Another Take stopped because that update is no longer available."
            return
        }
        let originalIsLocalOnlyDerived = cardIsLocalOnlyDerived(currentCard)
        if originalIsLocalOnlyDerived {
            let provider = target.modelRef?.provider ?? presentationProvider
            let egress = provider.dataEgress(endpoint: endpointForIntegration(provider))
            guard !egress.isRemote else {
                intakeStatus = "This reply contains local-only memory. Another Take requires an on-device model."
                return
            }
        }

        let authorization: AnotherTakeRequestAuthorization
        if let requiredCallID {
            guard conversationActive,
                  activeConversationID == requiredCallID,
                  let focusedSessionID = conversationTargetSnapshot?.target.id,
                  currentCard.externalSessionID == focusedSessionID else {
                intakeStatus = "Another Take stopped because the live session authorization changed."
                return
            }
            authorization = .live(
                card: currentCard,
                callID: requiredCallID,
                focusedSessionID: focusedSessionID
            )
        } else {
            authorization = explicitAuthorization
        }

        let priorName = currentCard.producedByPersonalityName ?? activePersonality?.name ?? "Attaché"
        selectPersonality(targetPersonalityID)
        intakeStatus = "Getting another take from \(target.name)…"
        let snapshot = captureRequestSnapshot(
            role: .anotherTake,
            userInput: currentCard.rawText,
            personalityOverride: target
        )
        presentationService.prepareAnotherTake(
            original: currentCard,
            targetPersonality: target,
            priorPersonalityName: priorName,
            authorization: authorization,
            snapshot: snapshot
        ) { [weak self] presented in
            guard let self else { return }
            if let requiredCallID {
                guard self.conversationActive, self.activeConversationID == requiredCallID else { return }
            }
            guard var presented else {
                self.intakeStatus = "Another take needs a presentation model. Set one up in Settings."
                return
            }
            if originalIsLocalOnlyDerived {
                presented.event.metadata["attache_local_only_derived"] = "true"
            }
            do {
                let takeCard = try self.store.insertEvent(presented.event)
                self.reloadCards(select: takeCard.id)
                self.playInboxCard(takeCard)
                self.intakeStatus = "Another take from \(target.name)."
            } catch {
                self.intakeStatus = "Another take failed: \(error.localizedDescription)"
            }
        }
    }

    func playSelected() {
        guard let card = selectedCard else { return }
        let startProgress = selectedStartProgress
        selectedStartProgress = 0
        let startTimeMs = Int((Double(max(0, card.durationMs)) * startProgress).rounded())
        playCardRespectingEgress(card, startTimeMs: startTimeMs)
    }

    func replaySelected() {
        guard let card = selectedCard else { return }
        selectedStartProgress = 0
        replayCardRespectingEgress(card)
    }

    /// The best displayable session name for a card: the live session
    /// record's (desktop-named, markup-cleaned) title when the session is
    /// known, otherwise the card's stored title run through markup cleanup,
    /// since cards persisted before a session was renamed keep old strings.
    func displaySessionTitle(forCard card: VoicemailCard) -> String? {
        if let sessionID = card.externalSessionID,
           let record = sessionRecords.first(where: { $0.id == sessionID }),
           !record.title.isEmpty {
            return record.title
        }
        guard let stored = card.sessionTitle, !stored.isEmpty else { return nil }
        return SessionDigest.title(from: stored)
    }

    /// Heard recaps and replies, newest first (the ⌘Y palette's source).
    var historyCards: [VoicemailCard] {
        cards
            .filter { $0.status == .heard }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func historyCards(for scope: AttacheHistoryScope) -> [VoicemailCard] {
        switch scope {
        case .focused:
            guard let attachedCodexSessionID else { return [] }
            return historyCards.filter { $0.externalSessionID == attachedCodexSessionID }
        case .watched:
            let watchedIDs = Set(attachedTargets.keys)
            guard !watchedIDs.isEmpty else { return [] }
            return historyCards.filter { card in
                guard let sessionID = card.externalSessionID else { return false }
                return watchedIDs.contains(sessionID)
            }
        case .all:
            return historyCards
        }
    }

    func historyCount(for scope: AttacheHistoryScope) -> Int {
        historyCards(for: scope).count
    }

    /// Everything sent to an agent, newest first, for the History palette's
    /// Sent tab. Backed by `TwoWayCoordinator.log`, which already mirrors
    /// `InstructionReplyEngine`'s persisted audit log after every state
    /// transition, so no separate storage or refresh path is needed here.
    func sentInstructions(for scope: AttacheHistoryScope) -> [Instruction] {
        let all = twoWay.log
        switch scope {
        case .focused:
            guard let attachedCodexSessionID else { return [] }
            return all.filter { $0.sessionID == attachedCodexSessionID }
        case .watched:
            let watchedIDs = Set(attachedTargets.keys)
            guard !watchedIDs.isEmpty else { return [] }
            return all.filter { watchedIDs.contains($0.sessionID) }
        case .all:
            return all
        }
    }

    func sentInstructionsCount(for scope: AttacheHistoryScope) -> Int {
        sentInstructions(for: scope).count
    }

    /// Escape dismisses live playback immediately instead of waiting for the
    /// audio to finish (v0.1.2 behavior).
    func dismissCurrentPlayback() -> Bool {
        let hasPlaybackSurface = playback.isPlaying
            || playback.isPaused
            || !playback.currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasPlaybackSurface else { return false }

        selectedStartProgress = 0
        playback.stop()
        if pendingAssistantReply != nil {
            revealPendingReply()
        } else {
            expectingReplyAudio = false
            maybeResumeContinuousListening()
        }
        return true
    }

    private func cardIsLocalOnlyDerived(_ card: VoicemailCard) -> Bool {
        metadataDictionary(for: card)["attache_local_only_derived"] == "true"
    }

    private func playCardRespectingEgress(_ card: VoicemailCard, startTimeMs: Int = 0) {
        if cardIsLocalOnlyDerived(card) {
            playback.play(
                card,
                startTimeMs: startTimeMs,
                configuration: localOnlySpeechConfiguration
            )
        } else {
            playback.play(card, startTimeMs: startTimeMs)
        }
    }

    private func replayCardRespectingEgress(_ card: VoicemailCard) {
        if cardIsLocalOnlyDerived(card) {
            playback.replay(card, configuration: localOnlySpeechConfiguration)
        } else {
            playback.replay(card)
        }
    }

    func playHistoryCard(_ card: VoicemailCard) {
        selectedCardID = card.id
        selectedStartProgress = 0
        replayCardRespectingEgress(card)
        intakeStatus = "Replaying history for \(card.sessionTitle ?? card.externalSessionID ?? "attached session")."
    }

    func playInboxCard(_ card: VoicemailCard, fromCatchUp: Bool = false) {
        if !fromCatchUp {
            inboxCatchUpQueue.removeAll()
        }
        selectedCardID = card.id
        selectedStartProgress = 0
        replayCardRespectingEgress(card)
        intakeStatus = "Playing voicemail for \(card.sessionTitle ?? card.externalSessionID ?? "General")."
    }

    /// One line summarizing the waiting inbox, composed deterministically from
    /// the already-presented card summaries (INF-169).
    func inboxDigestText(for cards: [VoicemailCard]) -> String {
        let groups = Dictionary(grouping: cards) { card in
            card.externalSessionID ?? "general:\(card.sourceKind)"
        }
        let slices = groups.map { entry -> InboxDigest.SessionSlice in
            let cards = entry.value
            let newest = cards.max(by: { $0.createdAt < $1.createdAt })
            let title = newest.flatMap { self.displaySessionTitle(forCard: $0) }
            return InboxDigest.SessionSlice(
                title: (title?.isEmpty == false ? title! : (newest?.sourceDisplayName ?? "General")),
                unheardCount: cards.count,
                latestSummary: newest?.summary ?? "",
                needsDecision: cards.contains(where: \.needsDecision)
            )
        }
        return InboxDigest.text(slices: slices)
    }

    /// Personalized "Recap": condense the waiting inbox into one short spoken
    /// update via the presentation LLM, persist it as a replayable history card
    /// tagged as a recap, archive the summarized originals out of the unread
    /// inbox (they stay in history), and play the recap through normal card
    /// playback so it uses the chosen voice and lazy synthesis. When the
    /// presentation LLM is not configured, fall back to the deterministic digest
    /// preview (the pre-INF-169-followup behavior) instead of failing.
    func playInboxRecap(for cards: [VoicemailCard]) {
        applySpeechConfiguration()

        // A fresh attempt (whether the user pressed "Play recap" again or this
        // is the explicit retry after a failure) supersedes any stale recovery
        // banner from a previous attempt (INF-254).
        recapRecovery = nil
        recapRecoveryConfirmation = nil
        recapRetryCards = []

        let summarized = cards
        guard !summarized.isEmpty else {
            playback.preview(inboxDigestText(for: summarized))
            return
        }

        guard presentationService.isPresentationConfigured(for: .recap) else {
            // Deterministic fallback: speak the template digest, ephemeral, and
            // leave the inbox untouched exactly as before.
            playback.preview(inboxDigestText(for: summarized))
            return
        }

        // Snapshot everything the background Task needs from observed state here,
        // on the calling (main) actor, so the Task never reads @Published state
        // off-main.
        let personality = activePersonality
        let profilePrompt = resolvedProfilePrompt(for: personality)
        let spokenLanguageName = AttachePresentationService.spokenLanguageName(defaults: defaults)
        let prompt = AttachePersonality.recapPrompt(
            items: summarized.map { recapItem(for: $0) },
            profilePrompt: profilePrompt,
            memoryContext: nil,
            spokenLanguageName: spokenLanguageName
        )
        let system = prompt.messages.first(where: { $0.role == "system" })?.content ?? ""
        let user = prompt.messages.first(where: { $0.role == "user" })?.content ?? ""
        let snapshot = captureRequestSnapshot(
            role: .recap,
            userInput: user,
            personalityOverride: personality
        )

        intakeStatus = "Writing your recap…"

        Task { [weak self] in
            guard let self else { return }
            do {
                let completion = try await self.presentationService.complete(
                    snapshot: snapshot,
                    system: system,
                    user: user
                )
                // persist/play mutate @Published state and the store, so hop back
                // to the main actor before touching either (mutating observed
                // state off-main re-enters SwiftUI's body and overflows the stack).
                await MainActor.run {
                    let trimmed = AttachePersonality.stripDashes(completion.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                    guard !trimmed.isEmpty else {
                        // The LLM was configured but returned nothing usable: fall
                        // back to the deterministic digest and leave the inbox as
                        // is. Not a classified failure (no thrown error), so no
                        // recovery is offered, matching prior behavior exactly.
                        self.playback.preview(self.inboxDigestText(for: summarized))
                        self.intakeStatus = "Recap unavailable; played the quick digest instead."
                        AttacheContextUIState.shared.publishReceipt(completion.inference.receiptView)
                        return
                    }
                    self.deliverRecap(
                        trimmed,
                        summarizing: summarized,
                        personality: personality,
                        inference: completion.inference
                    )
                }
            } catch {
                // The deterministic fallback itself is unchanged (INF-254): still
                // play the digest. This only ADDS a recovery affordance alongside
                // it when the failure is structurally recoverable.
                await MainActor.run {
                    self.playback.preview(self.inboxDigestText(for: summarized))
                    self.intakeStatus = "Recap unavailable; played the quick digest instead."
                    let underlyingError = (error as? AttacheBrokerAttemptFailure)?.underlying ?? error
                    let presentationError = underlyingError as? AttachePresentationError
                    let recovery = ConversationRecovery.classify(
                        errorMessage: error.localizedDescription,
                        failedPrompt: "",
                        httpStatus: presentationError?.httpStatus,
                        urlErrorCode: presentationError?.urlErrorCode ?? (underlyingError as? URLError)?.code,
                        isCLIProvider: self.recapEffectiveProvider.isCLI
                    )
                    if let attempted = error as? AttacheBrokerAttemptFailure {
                        AttacheContextUIState.shared.publishReceipt(attempted.inference.receiptView)
                    }
                    if recovery.offersModelSwitch {
                        self.recapRecovery = recovery
                        self.recapRetryCards = summarized
                        // Model discovery for the recap recovery menu (same
                        // pattern the live-call failure handler already uses).
                        self.loadPresentationModels(preserveCurrentSelection: true)
                    }
                }
            }
        }
    }

    /// Persist the generated recap as a replayable history card, archive the
    /// originals it summarized (they remain in history for replay), and play the
    /// recap card through normal playback. Main-actor only.
    private func deliverRecap(
        _ recapText: String,
        summarizing cards: [VoicemailCard],
        personality: Personality?,
        inference: AttacheInferenceMetadata
    ) {
        var metadata: [String: String] = [
            "companion_recap": "1",
            "companion_history_kind": "recap",
            "companion_summary": Self.conversationReplySummary(from: recapText),
            "companion_spoken_text": recapText,
            "companion_presentation_strategy": "attache-inbox-recap"
        ]
        if let personality {
            metadata["companion_personality_id"] = personality.id
            metadata["companion_personality_name"] = personality.name
        }
        if let receipt = inference.receiptView.encodedMetadataValue() {
            metadata[AttacheContextReceiptView.metadataKey] = receipt
        }
        // Attribute the recap to the focused session when there is one, so it
        // files alongside that session's history; otherwise it lives in General.
        let sessionID = attachedCodexSessionID
        if let sessionID {
            metadata["attached_codex_session_id"] = sessionID
        }
        let source = sessionID
            .flatMap { id in sessionRecords.first(where: { $0.id == id })?.sourceKind.rawValue }
            ?? cards.first?.sourceKind
            ?? SourceKind.generic.rawValue

        let event = NormalizedEvent(
            source: source,
            eventType: "attache.inbox.recap",
            externalSessionID: sessionID,
            projectPath: nil,
            title: "Recap",
            text: recapText,
            metadata: metadata
        )

        do {
            let card = try store.insertEvent(event, status: .heard)
            // Archive the summarized originals so they leave the unread inbox.
            // They stay in history (archived, not deleted) and remain replayable.
            archiveCards(cards)
            reloadCards(select: card.id)
            // Prefer the reloaded (store-normalized) card so playback uses its
            // computed spoken text and caption alignment.
            let recapCard = selectedCard?.id == card.id ? (selectedCard ?? card) : card
            selectedStartProgress = 0
            playCardRespectingEgress(recapCard)
            intakeStatus = "Playing your recap of \(cards.count) update\(cards.count == 1 ? "" : "s")."
        } catch {
            // Persisting failed: still give the user something by speaking the
            // recap text, and leave the inbox untouched.
            playback.preview(recapText)
            intakeStatus = "Played the recap but could not save it: \(error.localizedDescription)"
        }
    }

    private func recapItem(for card: VoicemailCard) -> AttachePersonality.RecapItem {
        AttachePersonality.RecapItem(
            sessionTitle: displaySessionTitle(forCard: card) ?? card.sourceDisplayName,
            summary: card.summary,
            spokenText: card.spokenText,
            needsDecision: card.needsDecision
        )
    }

    /// Catch-me-up: play every waiting card oldest-first, auto-advancing.
    /// An explicit user action, so it is exempt from the INF-163 drain gating
    /// that applies to automatic playback.
    func playAllUnread(_ cards: [VoicemailCard]) {
        let ordered = cards.sorted { $0.createdAt < $1.createdAt }
        guard let first = ordered.first else { return }
        inboxCatchUpQueue = Array(ordered.dropFirst().map(\.id))
        playInboxCard(first, fromCatchUp: true)
    }

    private func advanceCatchUpQueueIfNeeded() -> Bool {
        while !inboxCatchUpQueue.isEmpty {
            let nextID = inboxCatchUpQueue.removeFirst()
            if let card = cards.first(where: { $0.id == nextID }) {
                playInboxCard(card, fromCatchUp: true)
                return true
            }
        }
        return false
    }

    var playbackCurrentCardID: String? { playback.currentCardID }

    func togglePlaybackPause() {
        playback.togglePause()
    }

    func toggleSelectedPlayback() {
        guard let card = selectedCard else { return }
        if playback.currentCardID == card.id, playback.isPlaying {
            playback.togglePause()
        } else {
            playSelected()
        }
    }

    func seekSelected(to progress: Double) {
        let clampedProgress = min(1, max(0, progress))
        guard let card = selectedCard else {
            selectedStartProgress = clampedProgress
            return
        }

        if playback.currentCardID == card.id, playback.isPlaying, playback.durationMs > 0 {
            playback.seek(to: Int((Double(playback.durationMs) * clampedProgress).rounded()))
            refreshNowPlaying()
        } else {
            selectedStartProgress = clampedProgress
        }
    }

    /// Seek so the given caption word starts playing. `captionTimeMs` is in the
    /// caption's timescale; the sync offset maps it back to playback time.
    func seekToCaptionTime(_ captionTimeMs: Int) {
        guard let card = selectedCard, playback.currentCardID == card.id, playback.durationMs > 0 else { return }
        playback.seek(to: max(0, captionTimeMs - captionSyncOffsetMs))
        refreshNowPlaying()
    }

    func seekToCaptionTimeAndResume(_ captionTimeMs: Int) {
        seekToCaptionTime(captionTimeMs)
        if playback.isPaused {
            playback.resume()
            refreshNowPlaying()
        }
    }

    func skipBackward() {
        seekRelative(milliseconds: -seekStepSeconds * 1000)
    }

    func skipForward() {
        seekRelative(milliseconds: seekStepSeconds * 1000)
    }

    func togglePause() {
        playback.togglePause()
    }

    func adjustUITextScale(by delta: Double) {
        uiTextScale = AttacheTypeScale.clamp(uiTextScale + delta)
    }

    func adjustCaptionLines(by delta: Int) {
        captionLineCount = min(Self.captionLineRange.upperBound, max(Self.captionLineRange.lowerBound, captionLineCount + delta))
    }

    // MARK: - Live voice conversation

    func startConversation() {
        let wasActive = conversationActive
        if !wasActive {
            activeConversationID = UUID()
            conversationDestination = .attache
            // Hang-up is a context boundary. A new call must never inherit
            // transcript turns from a prior call that may have had a different
            // focused session, even though replayable replies remain in History.
            conversationMessages = []
            conversationTargetSnapshot = captureConversationTargetSnapshot()
            // The auto-fallback chain is sticky for a call, never across
            // calls (INF-258/D5 spec item 3): a fresh call always starts back
            // on the primary/configured provider.
            conversationFallbackState.reset()
            conversationTurnEffectLedger = nil
            conversationSessionToolRuntime = nil
        }
        conversationActive = true
        if conversationStatus.isEmpty {
            conversationStatus = conversationTargetSnapshot == nil
                ? "No session attached. I can still chat."
                : "Talking about \(conversationTargetSnapshot?.target.displayTitle ?? "this session")."
        }
        if voiceInputMode == .alwaysOn {
            beginConversationDictation()
        }
    }

    func endConversation() {
        let endingConversationID = activeConversationID
        let endingReviewID = activeExhaustiveReview?.preparedID
        exhaustiveReviewRefreshTask?.cancel()
        exhaustiveReviewRefreshTask = nil
        exhaustiveReviewRefreshID = nil
        exhaustiveReviewTask?.cancel()
        if let endingReview = activeExhaustiveReview {
            endingReview.runtime.cancel(id: endingReview.preparedID)
        }
        exhaustiveReviewTask = nil
        exhaustiveReviewExecutionID = nil
        exhaustiveReviewProviderExecutionID = nil
        activeExhaustiveReview = nil
        conversationRequestTask?.cancel()
        conversationRequestTask = nil
        conversationCompiledInference = nil
        conversationActive = false
        if let endingConversationID {
            directChatRuntime.endCall(endingConversationID)
        }
        activeConversationID = nil
        activeConversationRequestID = nil
        conversationRequestTimeoutTimer?.invalidate()
        conversationRequestTimeoutTimer = nil
        isConversing = false
        silenceTimer?.invalidate(); silenceTimer = nil
        revealTimer?.invalidate(); revealTimer = nil
        endConversationWait()
        conversationFallbackRetryTimer?.invalidate()
        conversationFallbackRetryTimer = nil
        conversationFallbackAnnouncement = nil
        conversationTurnEffectLedger = nil
        conversationSessionToolRuntime = nil
        sessionContextRuntime.advanceRequestBoundary()
        pendingAssistantReply = nil
        pendingAssistantInference = nil
        pendingAssistantReplyEgress = .allowedRemote
        expectingReplyAudio = false
        conversationRecovery = nil
        conversationRecoveryConfirmation = nil
        conversationStatus = ""
        conversationDestination = .attache
        conversationTargetSnapshot = nil
        Task { @MainActor [weak self] in
            guard self?.activeConversationID == nil
                    || self?.activeConversationID == endingConversationID else { return }
            AttacheContextUIState.shared.dismissOverflowRecovery()
            AttacheContextUIState.shared.dismissExhaustiveReview(id: endingReviewID)
        }
        micTranscript.stop(status: "")
        // Hanging up silences live narration immediately: stop what's speaking and
        // drop the queued backlog so it doesn't keep talking. The rest stays in the
        // inbox as unread (INF-163).
        playback.stop()
        livePlaybackQueue.reset()
    }

    func clearConversation() {
        conversationMessages = []
        conversationStatus = ""
        conversationRecovery = nil
    }

    func cycleVoiceInputMode() {
        voiceInputMode = voiceInputMode.next
    }

    /// True while waiting on the model or preparing the reply audio.
    var isAwaitingReply: Bool {
        isConversing || pendingAssistantReply != nil || (expectingReplyAudio && playback.isBusy)
    }

    var conversationProgressText: String {
        if isConversing {
            return conversationElapsedSeconds > 0
                ? "Thinking \(Self.elapsedConversationTime(conversationElapsedSeconds))"
                : "Thinking…"
        }
        if playback.isPlaying {
            return "Speaking…"
        }
        if playback.isPaused {
            return "Playback paused"
        }
        if expectingReplyAudio, playback.isBusy {
            return "Preparing audio…"
        }
        if pendingAssistantReply != nil {
            return "Preparing audio…"
        }
        return conversationStatus
    }

    /// Re-apply the input mode to a live conversation when the setting changes:
    /// start hands-free listening, or stop it.
    private func applyVoiceInputMode() {
        guard conversationActive else { return }
        if voiceInputMode == .alwaysOn {
            if !micTranscript.isListening, !micTranscript.isPreparing { beginConversationDictation() }
        } else {
            silenceTimer?.invalidate(); silenceTimer = nil
            if micTranscript.isListening || micTranscript.isPreparing { micTranscript.stop(status: "") }
        }
    }

    func beginConversationDictation() {
        micTranscript.clearTranscript()
        micTranscript.start()
    }

    /// Push-to-talk release, toggle-off, or a hands-free pause: finalize and send.
    func endConversationDictationAndSend() {
        silenceTimer?.invalidate(); silenceTimer = nil
        let micStatusBeforeFinish = micTranscript.status
        micTranscript.finishAndDeliver { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                self.conversationStatus = Self.meaningfulMicStatus(self.micTranscript.status)
                    ?? Self.meaningfulMicStatus(micStatusBeforeFinish)
                    ?? "Didn't catch that — try again."
                self.maybeResumeContinuousListening()
            } else {
                self.micTranscript.clearTranscript()
                self.sendConversationMessage(trimmed)
            }
        }
    }

    /// Toggle-mode mic: start listening, or finalize + send if already listening.
    func toggleConversationDictation() {
        if micTranscript.isPreparing {
            micTranscript.stop(status: "Voice input canceled.")
        } else if micTranscript.isListening {
            endConversationDictationAndSend()
        } else {
            beginConversationDictation()
        }
    }

    func sendConversationMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard conversationActive, !trimmed.isEmpty, !isAwaitingReply else { return }

        conversationFallbackRetryTimer?.invalidate()
        conversationFallbackRetryTimer = nil
        conversationFallbackAnnouncement = nil
        removeFailedTurnsBeforeRetry()
        conversationRecovery = nil
        conversationRecoveryConfirmation = nil
        conversationDraft = ""
        appendConversationTurn(role: .user, text: trimmed)

        if conversationDestination == .agent {
            let target = conversationTargetSnapshot?.agentSendTarget
            // Tell Agent is deliberately one-shot. Continuous listening and the
            // next typed turn return to the personality unless the user selects it again.
            conversationDestination = .attache
            let reply = stageConversationAgentInstruction(
                trimmed,
                target: target,
                origin: .tellAgent,
                sourceUtterance: trimmed
            )
            surfaceConversationReply(reply)
            return
        }

        // This is a new explicit user turn. Automatic fallback below reuses
        // this exact ledger; only another explicit turn/retry replaces it.
        conversationTurnEffectLedger = ConversationTurnEffectLedger()
        conversationSessionToolRuntime = nil
        isConversing = true
        beginConversationWait()
        performConversationRequest(trimmed)
    }

    /// Sends `trimmed` to the personality and handles the result. Split out
    /// of `sendConversationMessage` (INF-258/D5) so the opt-in auto-fallback
    /// chain can transparently retry the identical prompt against the next
    /// provider without re-appending a duplicate user turn to the transcript.
    /// `sendConversationMessage` calls this once after appending the user's
    /// turn; `announceConversationFallback` below calls it again, with the
    /// same `trimmed` text, once a fallback provider has been chosen.
    private func performConversationRequest(
        _ trimmed: String,
        frozenSnapshot: AttacheRequestSnapshot? = nil,
        frozenSettingsOverride: AttachePresentationSettings? = nil,
        priorAttemptInference: AttacheInferenceMetadata? = nil
    ) {
        guard conversationActive, activeConversationID != nil else {
            isConversing = false
            endConversationWait()
            return
        }
        let context = conversationTargetSnapshot
        let agentTarget = context?.agentSendTarget
        let allowAgentInstructionTool = agentTarget != nil
        // Sticky for the rest of the call (INF-258/D5): once a fallback is
        // active, every subsequent turn in this call keeps using it.
        let fallbackProvider = conversationFallbackState.activeProvider
        let settingsOverride = frozenSettingsOverride
            ?? fallbackProvider.map(conversationFallbackSettings(for:))
        let attemptedProvider = settingsOverride?.provider
            ?? fallbackProvider
            ?? effectiveRecoveryProvider(for: .conversation)
        let snapshot = frozenSnapshot ?? captureRequestSnapshot(
                role: .conversation,
                userInput: trimmed,
                settingsOverride: settingsOverride
            )
        let messages = buildConversationMessages(snapshot: snapshot)
        let allowMemoryProposalTool = AttacheContextUIState.persistedMemoryMode(defaults: defaults)
            .allowsProposals
        let allowSessionDiscoveryTool = localAgentSourcesEnabled
        if conversationSessionToolRuntime == nil,
           let focusedSession = snapshot.focusedSession {
            let reserve = snapshot.contextStrategy.kind == .custom
                ? (snapshot.contextStrategy.custom?.toolReserve ?? 4_096)
                : 4_096
            conversationSessionToolRuntime = sessionContextRuntime.makeToolRuntime(
                frozenSession: focusedSession,
                strategy: snapshot.contextStrategy,
                toolReserveTokens: reserve
            )
        }
        // Freeze the tool object into this request closure. Provider fallback
        // re-enters this method but reuses the same per-turn object and reserve.
        let sessionTools = conversationSessionToolRuntime
        let effectLedger: ConversationTurnEffectLedger
        if let existing = conversationTurnEffectLedger {
            effectLedger = existing
        } else {
            let created = ConversationTurnEffectLedger()
            conversationTurnEffectLedger = created
            effectLedger = created
        }
        conversationRequestTask?.cancel()
        conversationCompiledInference = nil
        guard let authorization = issueConversationRequestAuthorization() else {
            isConversing = false
            endConversationWait()
            return
        }
        let requestID = authorization.requestID
        beginConversationRequestDeadline(
            requestID: requestID,
            prompt: trimmed,
            attemptedProvider: attemptedProvider,
            frozenSnapshot: snapshot
        )

        conversationRequestTask = presentationService.converse(
            snapshot: snapshot,
            messages: messages,
            allowSessionContextTools: snapshot.isFocused,
            allowAgentInstructionTool: allowAgentInstructionTool,
            allowMemoryProposalTool: allowMemoryProposalTool,
            allowSessionDiscoveryTool: allowSessionDiscoveryTool,
            allowExhaustiveReviewTool: snapshot.isFocused,
            settingsOverride: settingsOverride,
            requestIsActive: { [weak self] in
                guard let self else { return false }
                return await MainActor.run {
                    self.conversationRequestIsAuthorized(authorization)
                }
            },
            attemptDidCompile: { [weak self] inference in
                guard let self else { return }
                await MainActor.run {
                    guard self.conversationRequestIsAuthorized(authorization) else { return }
                    self.conversationCompiledInference = (authorization.requestID, inference)
                }
            },
            executeTool: { [weak self] name, arguments in
                guard let self else { return "Attaché is no longer available for that tool call." }
                guard await MainActor.run(body: {
                    self.conversationRequestIsAuthorized(authorization)
                }) else {
                    return "That conversation request ended, so this tool call was canceled without any side effect."
                }
                if name == "propose_memory" {
                    let callID = authorization.callID.uuidString
                    return await self.applyMemoryProposalTool(
                        arguments: arguments,
                        sourceUtterance: trimmed,
                        personalityID: snapshot.personalityID,
                        sourceLocator: "call:\(callID):request:\(snapshot.requestID)",
                        effectLedger: effectLedger,
                        authorization: authorization
                    )
                }
                if name == "request_session_search" {
                    return await self.applySessionDiscoveryTool(
                        arguments: arguments,
                        sourceUtterance: trimmed,
                        effectLedger: effectLedger,
                        authorization: authorization
                    )
                }
                if name == "request_exhaustive_review" {
                    return await self.prepareExhaustiveReviewTool(
                        snapshot: snapshot,
                        authorization: authorization
                    )
                }
                guard snapshot.isFocused, context != nil else {
                    return "No work-session tools are authorized for this conversation."
                }
                if name == "stage_agent_instruction" {
                    return await self.applyStageAgentInstructionTool(
                        arguments: arguments,
                        target: agentTarget,
                        sourceUtterance: trimmed,
                        effectLedger: effectLedger,
                        authorization: authorization
                    )
                }
                return sessionTools?.execute(name: name, arguments: arguments)
                    ?? "No frozen work-session evidence is authorized for this conversation turn."
            },
            completion: { [weak self] result in
                guard let self,
                      self.conversationActive,
                      self.activeConversationRequestID == requestID else { return }
                self.conversationRequestTask = nil
                self.conversationCompiledInference = nil
                self.activeConversationRequestID = nil
                self.conversationRequestTimeoutTimer?.invalidate()
                self.conversationRequestTimeoutTimer = nil
                self.isConversing = false
                self.endConversationWait()
                switch result {
                case .success(let reply):
                    let inference = priorAttemptInference.map {
                        reply.inference.recordingFallback(after: $0)
                    } ?? reply.inference
                    self.surfaceConversationReply(
                        reply.text,
                        toolCallLost: reply.toolCallLost,
                        inference: inference
                    )
                case .failure(let error):
                    self.handleConversationFailure(
                        error,
                        failedPrompt: trimmed,
                        attemptedProvider: attemptedProvider,
                        frozenSnapshot: snapshot,
                        attemptedSettings: settingsOverride ?? snapshot.modelSettings
                    )
                }
            }
        )
    }

    /// Issue the only token accepted by conversation effects. Keeping issuance
    /// in one method makes the call/request pair impossible to mix across a
    /// fallback, timeout, or subsequent call.
    func issueConversationRequestAuthorization() -> ConversationRequestAuthorization? {
        guard conversationActive, let callID = activeConversationID else { return nil }
        let authorization = ConversationRequestAuthorization(callID: callID, requestID: UUID())
        activeConversationRequestID = authorization.requestID
        return authorization
    }

    @MainActor
    private func conversationRequestIsAuthorized(
        _ authorization: ConversationRequestAuthorization
    ) -> Bool {
        conversationActive
            && activeConversationID == authorization.callID
            && activeConversationRequestID == authorization.requestID
    }

    /// A live voice turn should feel conversational, not like an unbounded job.
    /// The model operation may still unwind in the background, but its request id
    /// is invalidated here so it cannot mutate UI or play audio when it eventually
    /// returns. CLI subprocesses have a matching hard process timeout.
    private func beginConversationRequestDeadline(
        requestID: UUID,
        prompt: String,
        attemptedProvider: AttachePresentationProvider,
        frozenSnapshot: AttacheRequestSnapshot
    ) {
        conversationRequestTimeoutTimer?.invalidate()
        let configured = presentationEnvironment["ATTACHE_CONVERSATION_TIMEOUT_SECONDS"]
            .flatMap(TimeInterval.init)
            .flatMap { $0 > 0 ? $0 : nil }
        let timeout = configured ?? Self.conversationRequestTimeoutSeconds
        conversationRequestTimeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self,
                  self.conversationActive,
                  self.activeConversationRequestID == requestID else { return }
            self.conversationRequestTask?.cancel()
            self.conversationRequestTask = nil
            let attemptedInference = self.conversationCompiledInference.flatMap {
                $0.requestID == requestID ? $0.inference : nil
            }
            self.conversationCompiledInference = nil
            self.activeConversationRequestID = nil
            self.conversationRequestTimeoutTimer = nil
            self.isConversing = false
            self.endConversationWait()
            self.handleConversationFailure(
                AttachePresentationError.transport(URLError(.timedOut)),
                failedPrompt: prompt,
                attemptedProvider: attemptedProvider,
                frozenSnapshot: frozenSnapshot,
                attemptedSettings: frozenSnapshot.modelSettings,
                attemptedInference: attemptedInference
            )
        }
    }

    /// Classifies a failed conversation attempt and either (a) transparently
    /// retries on the next configured-and-consented fallback provider
    /// (INF-258/D5, only while the toggle is on and no fallback is active yet
    /// this call), or (b) falls through to the existing manual Switch model /
    /// Retry recovery, unchanged from before this feature existed.
    func handleConversationFailure(
        _ error: Error,
        failedPrompt: String,
        attemptedProvider: AttachePresentationProvider,
        frozenSnapshot: AttacheRequestSnapshot,
        attemptedSettings: AttachePresentationSettings?,
        attemptedInference: AttacheInferenceMetadata? = nil
    ) {
        let errorMessage = error.localizedDescription
        let underlyingError = (error as? AttacheBrokerAttemptFailure)?.underlying ?? error
        let presentationError = underlyingError as? AttachePresentationError
        let httpStatus = presentationError?.httpStatus
        let urlErrorCode = presentationError?.urlErrorCode ?? (underlyingError as? URLError)?.code
        let recovery = ConversationRecovery.classify(
            errorMessage: errorMessage,
            failedPrompt: failedPrompt,
            httpStatus: httpStatus,
            urlErrorCode: urlErrorCode,
            isCLIProvider: attemptedProvider.isCLI
        )
        let fallbackFailureCategory = Self.fallbackFailureCategory(for: error)
        let fallbackDecision = AttacheFallbackRecompiler.shouldFallback(for: fallbackFailureCategory)

        if fallbackFailureCategory == .contextLimitOverflow {
            presentConversationOverflowRecovery(
                failedPrompt: failedPrompt,
                frozenSnapshot: frozenSnapshot,
                attemptedSettings: attemptedSettings
            )
            return
        }

        if fallbackDecision.shouldFallback,
           let fallback = conversationFallbackState.advance(
            enabled: conversationFallbackChainEnabled,
            category: recovery.category,
            chain: conversationFallbackChain,
            failedProvider: attemptedProvider,
            isConfigured: { [weak self] provider in self?.connectedTextProviders.contains(provider) ?? false },
            isConsented: { [weak self] provider in
                guard let self else { return false }
                return !self.presentationProviderSendsToCloud(provider) || self.cloudConsentAcknowledged(for: provider)
            }
        ) {
            announceConversationFallback(
                category: recovery.category,
                from: attemptedProvider,
                to: fallback,
                retryPrompt: failedPrompt,
                frozenSnapshot: frozenSnapshot,
                primaryFailureInference: attemptedInference
                    ?? (error as? AttacheBrokerAttemptFailure)?.inference
            )
            return
        }

        let message = "I hit a problem: \(errorMessage)"
        conversationRecovery = recovery
        conversationStatus = errorMessage
        appendConversationTurn(role: .assistant, text: message)
        if recovery.offersModelSwitch {
            // Preserve the user's exact words. Switching only changes
            // the selected brain; retry remains an explicit action.
            conversationDraft = failedPrompt
            loadPresentationModels(preserveCurrentSelection: true)
        } else {
            maybeResumeContinuousListening()
        }
    }

    private func presentConversationOverflowRecovery(
        failedPrompt: String,
        frozenSnapshot: AttacheRequestSnapshot,
        attemptedSettings: AttachePresentationSettings?
    ) {
        conversationRecovery = nil
        conversationRecoveryConfirmation = nil
        conversationDraft = failedPrompt
        conversationStatus = "This model ran out of context space. Choose an explicit retry strategy."
        guard let requiredCallID = activeConversationID else { return }
        let frozenSettings = attemptedSettings ?? frozenSnapshot.modelSettings
        let recovery = AttacheFallbackRecompiler.overflowRecovery(preserving: failedPrompt)

        Task { @MainActor [weak self] in
            guard let self,
                  self.conversationActive,
                  self.activeConversationID == requiredCallID else { return }
            AttacheContextUIState.shared.presentOverflowRecovery(recovery) {
                [weak self, frozenSnapshot, frozenSettings] strategyKind, preservedDraft in
                guard let self,
                      self.conversationActive,
                      self.activeConversationID == requiredCallID,
                      self.activeConversationRequestID == nil else { return }
                let strategy: AttacheContextStrategy
                switch strategyKind {
                case .automatic:
                    strategy = .automatic
                case .efficient:
                    strategy = .efficient
                default:
                    return
                }
                let retrySnapshot = frozenSnapshot.retryingOverflow(with: strategy)
                self.conversationDraft = ""
                self.isConversing = true
                self.beginConversationWait()
                self.performConversationRequest(
                    preservedDraft,
                    frozenSnapshot: retrySnapshot,
                    frozenSettingsOverride: frozenSettings
                )
            }
        }
    }

    /// Structural fallback gate shared by HTTP and CLI failures (INF-337).
    /// Authentication and context-window failures are terminal for automatic
    /// fallback even when a provider reports them under a generic 5xx status.
    static func fallbackFailureCategory(for error: Error) -> AttacheFallbackFailureCategory {
        let underlyingError = (error as? AttacheBrokerAttemptFailure)?.underlying ?? error
        if let compilerError = underlyingError as? AttacheContextCompilerError {
            switch compilerError {
            case .protectedContentOverflow, .preEgressOverflow:
                return .contextLimitOverflow
            case .budgetPlanningFailure(.protectedContentOverflow):
                return .contextLimitOverflow
            case .budgetPlanningFailure(.invalidCustomPolicy),
                 .requiresStagedProcessing,
                 .unauthorizedPrebuiltMessage:
                return .unknown
            }
        }
        let presentationError = underlyingError as? AttachePresentationError
        let body = presentationError?.responseBody ?? underlyingError.localizedDescription
        let normalized = body.lowercased()
        let contextMarkers = [
            "context length", "context window", "maximum context", "token limit",
            "too many tokens", "prompt is too long", "request too large"
        ]
        if contextMarkers.contains(where: normalized.contains) {
            return .contextLimitOverflow
        }
        let authenticationMarkers = [
            "unauthorized", "authentication", "invalid api key", "incorrect api key",
            "missing api key", "forbidden"
        ]
        if authenticationMarkers.contains(where: normalized.contains) {
            return .authenticationFailure
        }
        return AttacheFallbackRecompiler.classifyFailure(
            statusCode: presentationError?.httpStatus,
            errorBody: body
        )
    }

    /// Surfaces the fallback hop in the status line and as one spoken
    /// sentence (spec item 3), then retries `retryPrompt` against `fallback`
    /// once the announcement has had roughly enough time to play, so the
    /// retry's own reply audio doesn't immediately cut it off.
    private func announceConversationFallback(
        category: ConversationFailureCategory,
        from failedProvider: AttachePresentationProvider,
        to fallback: AttachePresentationProvider,
        retryPrompt: String,
        frozenSnapshot: AttacheRequestSnapshot,
        primaryFailureInference: AttacheInferenceMetadata?
    ) {
        guard conversationActive else { return }
        let announcement = ConversationFallbackChain.announcement(
            category: category,
            failedProviderTitle: failedProvider.title,
            fallbackProviderTitle: fallback.title
        )
        conversationFallbackHopCount += 1
        // Spec item 6: log every hop with the category + provider pair, not
        // just the aggregate count above. Never logs prompt/reply content
        // (AttacheLog's own rule), only provider identifiers and the
        // structural category.
        AttacheLog.presentation.info(
            "conversation auto-fallback hop category=\(category.rawValue, privacy: .public) from=\(failedProvider.rawValue, privacy: .public) to=\(fallback.rawValue, privacy: .public)"
        )
        conversationStatus = announcement
        conversationFallbackAnnouncement = announcement
        playback.preview(announcement)
        let fallbackSettings = conversationFallbackSettings(for: fallback)

        let delaySeconds = Double(CaptionAlignmentBuilder.estimatedDurationMs(for: announcement)) / 1000.0 + 0.2
        conversationFallbackRetryTimer?.invalidate()
        conversationFallbackRetryTimer = Timer.scheduledTimer(withTimeInterval: delaySeconds, repeats: false) { [weak self] _ in
            guard let self, self.conversationActive else { return }
            self.conversationFallbackRetryTimer = nil
            self.conversationFallbackAnnouncement = nil
            self.isConversing = true
            self.beginConversationWait()
            self.performConversationRequest(
                retryPrompt,
                frozenSnapshot: frozenSnapshot,
                frozenSettingsOverride: fallbackSettings,
                priorAttemptInference: primaryFailureInference
            )
        }
    }

    /// Builds full call settings for `provider` directly (INF-258/D5),
    /// bypassing every per-role persisted override: the auto-fallback chain
    /// must not touch Settings, only this call. Reuses the exact helpers
    /// Settings itself uses to resolve a provider's endpoint and credentials.
    private func conversationFallbackSettings(for provider: AttachePresentationProvider) -> AttachePresentationSettings {
        AttachePresentationSettings.forFallback(
            provider: provider,
            baseURLText: endpointForIntegration(provider),
            apiKey: readConfiguredSecret(account: provider.developmentSecretAccount) ?? "",
            profilePrompt: defaults.string(forKey: AttachePreferenceKey.personalityPrompt) ?? ""
        )
    }

    // MARK: Per-character fallback chain runtime (INF-258/D5)

    func addConversationFallbackChainProvider(_ provider: AttachePresentationProvider) {
        guard provider.supportsSafePersonalityInference,
              !conversationFallbackChain.contains(provider) else { return }
        conversationFallbackChain.append(provider)
    }

    func removeConversationFallbackChainProvider(_ provider: AttachePresentationProvider) {
        conversationFallbackChain.removeAll { $0 == provider }
    }

    func moveConversationFallbackChainProvider(at index: Int, up: Bool) {
        let targetIndex = up ? index - 1 : index + 1
        guard conversationFallbackChain.indices.contains(index),
              conversationFallbackChain.indices.contains(targetIndex) else { return }
        conversationFallbackChain.swapAt(index, targetIndex)
    }

    var conversationRecoveryProviders: [AttachePresentationProvider] {
        connectedTextProviders.filter { $0 != presentationProvider }
    }

    var conversationRecoveryModels: [AttachePresentationModelOption] {
        var options = presentationModelOptions.filter { $0.id != presentationModel }
        if presentationModel != "default", !options.contains(where: { $0.id == "default" }) {
            options.insert(AttachePresentationModelOption(
                id: "default",
                detail: "use \(presentationProvider.title)'s configured model",
                reasoningEfforts: AttachePresentationModelService.fallbackReasoningEfforts(
                    provider: presentationProvider,
                    modelID: "default"
                )
            ), at: 0)
        }
        return options
    }

    var canRetryConversationFailure: Bool {
        guard conversationRecovery?.offersModelSwitch == true, !isAwaitingReply else { return false }
        return !conversationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func selectConversationRecoveryModel(_ option: AttachePresentationModelOption) {
        // An explicit manual choice always wins over the sticky auto-fallback
        // (INF-258/D5): the user is picking a specific brain, so the rest of
        // this call should use exactly that, not silently keep redirecting to
        // whatever the chain had already switched to.
        conversationFallbackState.reset()
        isApplyingConversationRecoveryOverride = true
        selectPresentationModel(option)
        isApplyingConversationRecoveryOverride = false
        conversationDestination = .attache
        let confirmation = "Switched to \(presentationProvider.title) \(option.id). Review the restored draft, then retry."
        conversationStatus = confirmation
        conversationRecoveryConfirmation = confirmation
    }

    func selectConversationRecoveryProvider(_ provider: AttachePresentationProvider) {
        conversationFallbackState.reset()
        isApplyingConversationRecoveryOverride = true
        selectPresentationProvider(provider)
        selectPresentationModelID(provider.defaultModel)
        conversationDestination = .attache
        let confirmation = "Switched to \(provider.title) \(presentationModel). Review the restored draft, then retry."
        conversationStatus = confirmation
        conversationRecoveryConfirmation = confirmation
        // Model discovery for the new provider can still mutate
        // presentationModel/presentationReasoningEffort/etc. once it
        // completes; keep redirecting those writes to the conversation
        // role's keys until it finishes (see loadPresentationModels' doc).
        loadPresentationModels { [weak self] in
            self?.isApplyingConversationRecoveryOverride = false
        }
    }

    func retryConversationAfterFailure() {
        guard let recovery = conversationRecovery, !isAwaitingReply else { return }
        let editedDraft = conversationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        sendConversationMessage(editedDraft.isEmpty ? recovery.failedPrompt : editedDraft)
    }

    // MARK: - Role-scoped recovery (recap / follow-up, INF-254)
    //
    // The live call's recovery above predates the per-role model plumbing
    // (D2/D3) and switches by temporarily redirecting the main model row's
    // setters at the `.conversation` role's key (`isApplyingConversationRecoveryOverride`).
    // Recap and follow-up did not exist as separate roles back then; they use
    // the generic per-role mechanism D3 already built for Settings > Model >
    // Advanced (`selectRoleProvider`/`selectRoleModel`/`loadRoleModels`)
    // directly, so a recovery switch here updates only the failing role's
    // override, never the global keys other roles fall back to (the same
    // requirement the live call's mechanism satisfies its own way).

    /// The provider a role is currently using: its own override if one is
    /// set, else the main model row, mirroring
    /// `AttachePresentationSettings.load(role:)`'s own fallback.
    private func effectiveRecoveryProvider(for role: ModelRole) -> AttachePresentationProvider {
        roleModelProvider[role] ?? presentationProvider
    }

    private func effectiveRecoveryModelID(for role: ModelRole) -> String {
        roleModelID[role] ?? presentationModel
    }

    private func recoveryProviders(for role: ModelRole) -> [AttachePresentationProvider] {
        connectedTextProviders.filter { $0 != effectiveRecoveryProvider(for: role) }
    }

    private func recoveryModelOptions(for role: ModelRole) -> [AttachePresentationModelOption] {
        let currentModelID = effectiveRecoveryModelID(for: role)
        // No override yet: the role is using the main row, so its discovered
        // models are the main row's (`presentationModelOptions`), exactly what
        // the live call's own `conversationRecoveryModels` reads.
        let source = roleModelProvider[role] != nil ? (roleModelOptions[role] ?? []) : presentationModelOptions
        var options = source.filter { $0.id != currentModelID }
        if currentModelID != "default", !options.contains(where: { $0.id == "default" }) {
            let provider = effectiveRecoveryProvider(for: role)
            options.insert(AttachePresentationModelOption(
                id: "default",
                detail: "use \(provider.title)'s configured model",
                reasoningEfforts: AttachePresentationModelService.fallbackReasoningEfforts(provider: provider, modelID: "default")
            ), at: 0)
        }
        return options
    }

    /// Switches one role's override to a new provider (never the global
    /// fallback other roles read) and starts model discovery for it.
    private func selectRoleRecoveryProvider(_ provider: AttachePresentationProvider, for role: ModelRole) {
        selectRoleProvider(provider, for: role)
        loadRoleModels(for: role)
    }

    /// Picks a model within a role's current effective provider. Seeds an
    /// explicit override for that provider first if the role was still on
    /// "Use main model" (a mere failure never seeds one on its own; only this
    /// explicit user action does).
    private func selectRoleRecoveryModel(_ option: AttachePresentationModelOption, for role: ModelRole) {
        if roleModelProvider[role] == nil {
            selectRoleProvider(effectiveRecoveryProvider(for: role), for: role)
        }
        selectRoleModel(option, for: role)
    }

    var recapEffectiveProvider: AttachePresentationProvider { effectiveRecoveryProvider(for: .recap) }
    /// Both follow-up surfaces (card-based and live/session-based) ride the
    /// `.conversation` role (see `ModelRole`'s doc), so they share this one
    /// "which provider is follow-up currently using" reading.
    var followUpEffectiveProvider: AttachePresentationProvider { effectiveRecoveryProvider(for: .conversation) }
    var recapRecoveryProviders: [AttachePresentationProvider] { recoveryProviders(for: .recap) }
    var recapRecoveryModels: [AttachePresentationModelOption] { recoveryModelOptions(for: .recap) }

    var canRetryRecapFailure: Bool {
        recapRecovery?.offersModelSwitch == true && !recapRetryCards.isEmpty
    }

    func selectRecapRecoveryProvider(_ provider: AttachePresentationProvider) {
        selectRoleRecoveryProvider(provider, for: .recap)
        recapRecoveryConfirmation = "Switched recap to \(provider.title). Retry the recap when ready."
    }

    func selectRecapRecoveryModel(_ option: AttachePresentationModelOption) {
        selectRoleRecoveryModel(option, for: .recap)
        recapRecoveryConfirmation = "Switched recap to \(recapEffectiveProvider.title) \(option.id). Retry the recap when ready."
    }

    /// Replays the recap for the same cards that failed, exactly like the
    /// user pressing "Play recap" again; `playInboxRecap` itself clears the
    /// recovery state at the top of a fresh attempt.
    func retryRecapAfterFailure() {
        guard canRetryRecapFailure else { return }
        let cards = recapRetryCards
        playInboxRecap(for: cards)
    }

    var followUpRecoveryProviders: [AttachePresentationProvider] { recoveryProviders(for: .conversation) }
    var followUpRecoveryModels: [AttachePresentationModelOption] { recoveryModelOptions(for: .conversation) }

    var canRetryFollowUpFailure: Bool {
        followUpRecovery?.offersModelSwitch == true
            && !isGeneratingFollowUpAnswer
            && !followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func selectFollowUpRecoveryProvider(_ provider: AttachePresentationProvider) {
        selectRoleRecoveryProvider(provider, for: .conversation)
        followUpStatus = "Switched to \(provider.title). Ask Attaché again to retry."
    }

    func selectFollowUpRecoveryModel(_ option: AttachePresentationModelOption) {
        selectRoleRecoveryModel(option, for: .conversation)
        followUpStatus = "Switched to \(effectiveRecoveryProvider(for: .conversation).title) \(option.id). Ask Attaché again to retry."
    }

    /// Re-asks the same question, exactly like pressing "Ask Again".
    func retryFollowUpAfterFailure() {
        guard canRetryFollowUpFailure else { return }
        createFollowUpAnswer()
    }

    var liveFollowUpRecoveryProviders: [AttachePresentationProvider] { recoveryProviders(for: .conversation) }
    var liveFollowUpRecoveryModels: [AttachePresentationModelOption] { recoveryModelOptions(for: .conversation) }

    var canRetryLiveFollowUpFailure: Bool {
        liveFollowUpRecovery?.offersModelSwitch == true
            && !isGeneratingLiveFollowUpAnswer
            && !liveFollowUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func selectLiveFollowUpRecoveryProvider(_ provider: AttachePresentationProvider) {
        selectRoleRecoveryProvider(provider, for: .conversation)
        liveFollowUpStatus = "Switched to \(provider.title). Ask Attaché again to retry."
    }

    func selectLiveFollowUpRecoveryModel(_ option: AttachePresentationModelOption) {
        selectRoleRecoveryModel(option, for: .conversation)
        liveFollowUpStatus = "Switched to \(effectiveRecoveryProvider(for: .conversation).title) \(option.id). Ask Attaché again to retry."
    }

    /// Re-asks the same question, exactly like pressing "Ask Again".
    func retryLiveFollowUpAfterFailure() {
        guard canRetryLiveFollowUpFailure else { return }
        createLiveFollowUpAnswer()
    }

    /// Classifies a follow-up answer's failure (INF-254) when it degraded via
    /// the LLM-error fallback strategy; `nil` for every other strategy
    /// (including the deliberate "not configured" fallback, which is not a
    /// failure) or when the classification isn't recoverable.
    private func classifyFollowUpRecovery(_ answer: AttacheFollowUpAnswerResult) -> ConversationRecovery? {
        guard answer.strategy == "deterministic-follow-up-fallback-after-llm-error",
              let errorDescription = answer.errorDescription else { return nil }
        let recovery = ConversationRecovery.classify(
            errorMessage: errorDescription,
            failedPrompt: "",
            httpStatus: answer.errorHTTPStatus,
            urlErrorCode: answer.errorURLErrorCode,
            isCLIProvider: effectiveRecoveryProvider(for: .conversation).isCLI
        )
        return recovery.offersModelSwitch ? recovery : nil
    }

    private func removeFailedTurnsBeforeRetry() {
        guard let recovery = conversationRecovery else { return }
        let assistantFailure = "I hit a problem: \(recovery.errorMessage)"
        if conversationMessages.last?.role == .assistant,
           conversationMessages.last?.text == assistantFailure {
            conversationMessages.removeLast()
        }
        if conversationMessages.last?.role == .user,
           conversationMessages.last?.text == recovery.failedPrompt {
            conversationMessages.removeLast()
        }
    }

    private func surfaceConversationReply(
        _ reply: String,
        toolCallLost: Bool = false,
        inference: AttacheInferenceMetadata? = nil
    ) {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard conversationActive, !trimmed.isEmpty else { return }
        // Keep the HUD in an audio-prep state until the normal delivery path,
        // captions and a replayable card, is ready.
        conversationStatus = "Preparing audio…"
        let replyEgress: AttacheContextItemEgress = inference?.containsLocalOnlyContext == true
            ? .localOnly
            : .allowedRemote
        pendingAssistantReply = trimmed
        pendingAssistantInference = inference
        pendingAssistantReplyEgress = replyEgress
        expectingReplyAudio = true
        // The reply preempts any live update mid-flight; requeue it so it resumes
        // after the reply instead of being lost. The reply is filed as a
        // replayable history card, while live delivery uses the same preview
        // playback/caption path as other immediate voice responses.
        livePlaybackQueue.replyStarted()
        _ = persistConversationReply(
            trimmed,
            toolCallLost: toolCallLost,
            inference: inference,
            egress: replyEgress
        )
        if replyEgress == .localOnly {
            playback.preview(trimmed, configuration: localOnlySpeechConfiguration)
        } else {
            playback.preview(trimmed)
        }
        revealTimer?.invalidate()
        revealTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            self?.revealPendingReply()
        }
    }

    private func persistConversationReply(
        _ reply: String,
        toolCallLost: Bool = false,
        inference: AttacheInferenceMetadata? = nil,
        egress: AttacheContextItemEgress = .allowedRemote
    ) -> VoicemailCard? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let session = conversationTargetSnapshot?.target
        let personality = activePersonality
        var metadata: [String: String] = [
            "companion_history_kind": "direct_reply",
            "companion_summary": Self.conversationReplySummary(from: trimmed),
            "companion_spoken_text": trimmed,
            "companion_presentation_strategy": "attache-direct-chat",
            "companion_direct_reply": "true"
        ]
        // INF-243: a CLI personality attempted a tool call that never
        // recovered into a valid directive, even after the one corrective
        // retry. The card still carries the spoken degrade above; this only
        // flags that a tool call was attempted and lost.
        if toolCallLost {
            metadata["companion_tool_call_lost"] = "true"
        }
        if egress == .localOnly {
            metadata["attache_local_only_derived"] = "true"
        }
        if let personality {
            metadata["companion_personality_id"] = personality.id
            metadata["companion_personality_name"] = personality.name
        }
        if let receipt = inference?.receiptView.encodedMetadataValue() {
            metadata[AttacheContextReceiptView.metadataKey] = receipt
        }
        if let session {
            metadata["attached_codex_session_id"] = session.id
        }

        let event = NormalizedEvent(
            source: session?.sourceKind.rawValue ?? SourceKind.generic.rawValue,
            eventType: "attache.conversation.reply",
            externalSessionID: session?.id,
            projectPath: conversationWorkingDirectory,
            title: session?.displayTitle ?? "Attaché reply",
            text: trimmed,
            metadata: metadata
        )

        do {
            let card = try store.insertEvent(event, status: .heard)
            reloadCards(select: card.id)
            return selectedCard?.id == card.id ? selectedCard : card
        } catch {
            intakeStatus = "Conversation history save failed: \(error.localizedDescription)"
            return nil
        }
    }

    private static func conversationReplySummary(from text: String) -> String {
        let compact = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard compact.count > 96 else { return compact }
        let end = compact.index(compact.startIndex, offsetBy: 96)
        let prefix = compact[..<end]
        if let sentenceEnd = prefix.lastIndex(where: { ".!?".contains($0) }) {
            return String(prefix[...sentenceEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(prefix).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func revealPendingReply() {
        revealTimer?.invalidate(); revealTimer = nil
        guard let reply = pendingAssistantReply else { return }
        pendingAssistantReply = nil
        let inference = pendingAssistantInference
        pendingAssistantInference = nil
        let egress = pendingAssistantReplyEgress
        pendingAssistantReplyEgress = .allowedRemote
        let turnID = appendConversationTurn(role: .assistant, text: reply, egress: egress)
        if let inference {
            Task { @MainActor in
                AttacheContextUIState.shared.publishReceipt(
                    inference.receiptView.bound(to: turnID),
                    responseID: turnID
                )
            }
        }
        conversationStatus = ""
        // If the reply produced no audio, the playback observer won't fire, so make
        // sure hands-free listening still resumes. If audio is still being
        // generated, keep the visible prep state alive until playback starts or
        // fails.
        if !playback.isPlaying {
            if playback.isBusy {
                conversationStatus = "Preparing audio…"
            } else {
                expectingReplyAudio = false
                maybeResumeContinuousListening()
            }
        }
    }

    private func beginConversationWait() {
        conversationWaitTimer?.invalidate()
        conversationWaitStartedAt = Date()
        conversationElapsedSeconds = 0
        conversationStatus = "Thinking…"
        conversationWaitTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.conversationWaitStartedAt else { return }
            self.conversationElapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        }
    }

    private func endConversationWait() {
        conversationWaitTimer?.invalidate()
        conversationWaitTimer = nil
        conversationWaitStartedAt = nil
        conversationElapsedSeconds = 0
    }

    private static func elapsedConversationTime(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }

    // Hands-free: when no new words arrive for a beat, treat the utterance as done.
    private func handleConversationTranscript(_ text: String) {
        guard voiceInputMode == .alwaysOn, conversationActive, micTranscript.isListening else { return }
        silenceTimer?.invalidate()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            self?.endConversationDictationAndSend()
        }
    }

    private func handleReplyPlaybackChange(isPlaying: Bool) {
        if isPlaying, pendingAssistantReply != nil {
            revealPendingReply()
        }
        if !isPlaying, expectingReplyAudio, !isConversing, pendingAssistantReply == nil {
            expectingReplyAudio = false
            maybeResumeContinuousListening()
        }
    }

    /// Resume hands-free listening only once the assistant has finished replying, so
    /// the mic never transcribes the spoken reply back to itself.
    private func maybeResumeContinuousListening() {
        guard voiceInputMode == .alwaysOn, conversationActive,
              !isConversing, !playback.isPlaying, pendingAssistantReply == nil,
              !micTranscript.isListening, !micTranscript.isPreparing else { return }
        beginConversationDictation()
    }

    private static func meaningfulMicStatus(_ status: String) -> String? {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "Voice input off.",
              trimmed != "Requesting microphone and speech access.",
              trimmed != "Transcribing…" else {
            return nil
        }
        return trimmed
    }

    @discardableResult
    private func appendConversationTurn(
        role: ConversationTurn.Role,
        text: String,
        egress: AttacheContextItemEgress = .allowedRemote
    ) -> String {
        let id = UUID().uuidString
        conversationMessages.append(ConversationTurn(
            id: id,
            role: role,
            text: text,
            createdAt: Date(),
            egress: egress
        ))
        return id
    }

    // MARK: - Two-way send-to-agent (INF-173)

    /// Agent sends require a user-focused session. The conversational fallback to
    /// the most recent session remains read-only and never becomes an implicit target.
    private var twoWayTarget: AgentSendTarget? {
        if conversationActive {
            return conversationTargetSnapshot?.agentSendTarget
        }
        guard let session = attachedCodexSession else { return nil }
        return AgentSendTarget(
            sessionID: session.id,
            sourceKind: session.sourceKind.rawValue,
            displayTitle: session.displayTitle,
            workingDirectory: workingDirectory(for: session.id)
        )
    }

    var canSendToAgent: Bool { twoWayTarget != nil }

    private func stageConversationAgentInstruction(
        _ instruction: String,
        target: AgentSendTarget?,
        origin: InstructionOrigin,
        sourceUtterance: String?
    ) -> String {
        guard let target else {
            let message = "Focus an active Codex or Claude Code session before sending to an agent."
            intakeStatus = message
            liveFollowUpStatus = message
            return message
        }

        let sourceKind = SourceKind(rawValue: target.sourceKind) ?? .codex
        requestSendToAgent(
            instruction,
            target: target,
            origin: origin,
            sourceUtterance: sourceUtterance
        )
        let title = target.displayTitle.isEmpty ? sourceKind.displayName : target.displayTitle
        if showTwoWayEnable {
            return "Attaché staged that for \(title). Review the first-use send-to-agent prompt; nothing sends until you enable it and confirm the message."
        }
        if pendingInstruction != nil {
            return "Attaché staged that for \(title). Review and confirm before it sends."
        }
        let status = liveFollowUpStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty { return status }
        let fallback = intakeStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Attaché could not stage that instruction." : fallback
    }

    func isTwoWayEnabledForTarget() -> Bool {
        guard let target = twoWayTarget else { return false }
        return twoWay.isEnabled(sessionID: target.sessionID)
    }

    func enableTwoWayForTarget() {
        guard let target = twoWayTarget else { return }
        twoWay.setEnabled(true, sessionID: target.sessionID)
    }

    /// The name of the session an instruction would target, for the UI copy.
    var twoWayTargetTitle: String? {
        twoWayTarget?.displayTitle
    }

    var twoWayTargetSourceName: String? {
        twoWayTarget?.sourceDisplayName
    }

    var twoWayEnableTargetTitle: String? {
        twoWayEnablePendingSend?.target.displayTitle
    }

    /// Entry point from a "Send to agent" control: enable first-use if needed,
    /// otherwise stage the instruction. The user's send policy decides whether an
    /// enabled-session instruction opens final confirmation or sends directly.
    func requestSendToAgent(_ rawText: String? = nil) {
        let text = (rawText ?? liveFollowUpText).trimmingCharacters(in: .whitespacesAndNewlines)
        requestSendToAgent(
            text,
            target: twoWayTarget,
            origin: .offCallComposer,
            sourceUtterance: text
        )
    }

    private func requestSendToAgent(
        _ text: String,
        target: AgentSendTarget?,
        origin: InstructionOrigin,
        sourceUtterance: String?
    ) {
        guard let target else { intakeStatus = "Focus a Codex or Claude Code session before sending."; return }
        guard !text.isEmpty else { intakeStatus = "Type or dictate an instruction first."; return }
        let pending = PendingAgentSend(
            text: text,
            target: target,
            origin: origin,
            sourceUtterance: sourceUtterance
        )
        if twoWay.isEnabled(sessionID: target.sessionID) {
            stageAndSurface(pending)
        } else {
            twoWayEnablePendingSend = pending
            showTwoWayEnable = true
        }
    }

    /// From the first-use enable sheet: enable two-way for this session and stage
    /// the held instruction.
    func confirmEnableTwoWay() {
        showTwoWayEnable = false
        guard let pending = twoWayEnablePendingSend else { return }
        twoWayEnablePendingSend = nil
        twoWay.setEnabled(true, sessionID: pending.target.sessionID)
        stageAndSurface(pending, allowDirectSend: false)
    }

    func cancelEnableTwoWay() {
        showTwoWayEnable = false
        twoWayEnablePendingSend = nil
    }

    private func stageAndSurface(_ pending: PendingAgentSend, allowDirectSend: Bool = true) {
        if let reason = stageInstruction(pending) {
            intakeStatus = reason   // safety rejection or disabled
            liveFollowUpStatus = reason
            if conversationActive { conversationStatus = reason }
            return
        }
        // Model tool calls can be influenced by untrusted session or file
        // evidence. They may prepare a native confirmation, but can never
        // inherit direct-send. Explicit Tell Agent and the off-call composer
        // keep the user's configured direct-send behavior.
        if allowDirectSend,
           pending.origin != .personalityTool,
           agentInstructionSendPolicy.sendsDirectlyAfterSessionEnable {
            confirmStagedInstruction()
        }
    }

    /// Stage an instruction for confirmation (does not send). Returns the rejection
    /// reason for the UI, or nil on success (the instruction is held in
    /// `pendingInstruction`). Two-way must be enabled for the session first.
    @discardableResult
    private func stageInstruction(_ pending: PendingAgentSend) -> String? {
        do {
            let instruction = try twoWay.prepare(
                text: pending.text,
                sessionID: pending.target.sessionID,
                sourceKind: pending.target.sourceKind,
                origin: pending.origin,
                sourceUtterance: pending.sourceUtterance,
                targetDisplayName: pending.target.displayTitle,
                workingDirectory: pending.target.workingDirectory
            )
            pendingInstruction = instruction
            return nil
        } catch InstructionError.twoWayDisabled {
            return "Turn on send-to-agent for this session first."
        } catch InstructionError.rejected(let reason) {
            return reason
        } catch {
            return error.localizedDescription
        }
    }

    /// Confirm and deliver the staged instruction (delivery still waits for the
    /// session to be idle).
    func confirmStagedInstruction() {
        guard let instruction = pendingInstruction,
              let coordinator = twoWay else { return }
        let target = instruction.targetDisplayName ?? "the focused agent"
        let message = "Sending to \(target) when the session is quiet…"
        do {
            // Confirmation is the irreversible gate. Persist it synchronously
            // before returning or spawning delivery so a second call cannot
            // observe a still-pending instruction and confirm it again.
            _ = try coordinator.confirm(id: instruction.id)
            pendingInstruction = nil
            intakeStatus = message
            liveFollowUpStatus = message
            if conversationActive { conversationStatus = message }
        } catch {
            pendingInstruction = nil
            let failure = "Send failed: \(error.localizedDescription)"
            intakeStatus = failure
            liveFollowUpStatus = failure
            conversationStatus = failure
            return
        }
        Task { @MainActor in
            let changed = await coordinator.pump()
            handleTwoWayDeliveryChanges(changed)
        }
    }

    /// Reacts to every instruction a pump changed (INF-248/B3), not just the
    /// newest: a pump batch can contain both a delivered instruction and an
    /// expired/failed one (e.g. from `TwoWayCoordinator.pump`'s now-surfaced
    /// `expireStale` results), and a failure must never be silently dropped
    /// just because a different instruction happens to sort after it. Applying
    /// every change in ascending `createdAt` order still leaves the newest
    /// instruction's message visible last, preserving today's precedence for
    /// the primary status string, while every failure is at minimum logged so
    /// it is never invisible even when a later success overwrites the display.
    func handleTwoWayDeliveryChanges(_ changed: [Instruction]) {
        for instruction in changed.sorted(by: { $0.createdAt < $1.createdAt }) {
            applyTwoWayDeliveryChange(instruction)
        }
    }

    private func applyTwoWayDeliveryChange(_ instruction: Instruction) {
        switch instruction.state {
        case .delivered:
            let target = instruction.targetDisplayName ?? "agent"
            let message = "Sent to \(target). Watching for the reply…"
            intakeStatus = message
            liveFollowUpStatus = message
            if conversationActive { conversationStatus = message }
        case .failed:
            // Mirrors CallPhase.derive's failed-send formatting (the message is
            // shown verbatim, no generic prefix) so on-call and off-call read
            // the same way, including the expiry message
            // (`InstructionReplyEngine.expireStale`) naming the window and target.
            let reason = instruction.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = reason.isEmpty ? "Send failed." : reason
            intakeStatus = message
            liveFollowUpStatus = message
            if conversationActive { conversationStatus = message }
            AttacheLog.twoWay.warning("""
                Send-to-agent instruction \(instruction.id, privacy: .public) for session \
                \(instruction.sessionID, privacy: .public) failed: \(message, privacy: .public)
                """)
        default:
            break
        }
    }

    func discardStagedInstruction() {
        if let instruction = pendingInstruction { try? twoWay.cancel(id: instruction.id) }
        pendingInstruction = nil
    }

    func cancelInstruction(id: String) {
        try? twoWay.cancel(id: id)
    }

    private func buildConversationMessages(snapshot: AttacheRequestSnapshot) -> [AttacheChatMessage] {
        let focused = snapshot.focusedSession
        let system = AttachePersonality.conversationSystemPrompt(
            profilePrompt: snapshot.profilePrompt,
            memoryContext: nil,
            sessionTitle: nil,
            sessionIsFocused: focused != nil,
            sessionSourceName: nil,
            workingDirectory: nil,
            latestSummary: nil,
            latestAgentReply: nil,
            canStageAgentInstruction: snapshot.isFocused
        )
        var messages = [AttacheChatMessage(role: "system", content: system)]
        messages.append(contentsOf: snapshot.directChatMessages)
        return messages
    }

    private static let maxLoadedCards = 1_000

    private var conversationWorkingDirectory: String? {
        conversationTargetSnapshot?.workingDirectory
    }

    private func workingDirectory(for id: String) -> String? {
        // Use the attached session's own working directory (from its transcript's
        // cwd, held on SessionRecord.project), so a quiet freshly-attached session
        // still resolves and read_file can't wander into another project via some
        // unrelated card's path (INF-165 item 6).
        if let record = sessionRecords.first(where: { $0.id == id }),
           let project = record.project, !project.isEmpty {
            return project
        }
        // Then a card from THIS session; never a cross-project fallback.
        return cards.first(where: { $0.externalSessionID == id && $0.projectPath != nil })?.projectPath
    }

    var conversationLatestSummary: String? {
        conversationLatestAgentCard?.summary
    }

    /// Give the personality enough of the latest real agent reply to answer a
    /// specific follow-up without relying on the deliberately terse card summary.
    /// Earlier turns and longer output still stay behind the bounded read tools.
    var conversationLatestAgentReply: String? {
        guard let raw = conversationLatestAgentCard?.rawText else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let limit = 6_000
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "\n[latest reply truncated; use read_session_transcript for more]"
    }

    /// Conversation replies are filed as cards too, but they are Attaché's own
    /// history, not new evidence from the work agent. Keep the initial agent
    /// context stable across a multi-turn call instead of replacing it with the
    /// personality's previous answer after every turn.
    private var conversationLatestAgentCard: VoicemailCard? {
        guard let id = conversationTargetSnapshot?.target.id else { return nil }
        return cards.first { $0.externalSessionID == id && !isDirectConversationReply($0) }
    }

    /// Apply a `rename_session` tool call on the main thread (it mutates published
    /// state and persists), returning a short confirmation for the assistant to relay.
    func applyRenameTool(
        arguments: String,
        sessionID: String?,
        effectLedger: ConversationTurnEffectLedger?,
        authorization: ConversationRequestAuthorization? = nil
    ) async -> String {
        guard let sessionID else { return "There's no attached session to rename right now." }
        let newName = ((try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any])?["name"] as? String ?? ""
        return await MainActor.run {
            if let authorization, !conversationRequestIsAuthorized(authorization) {
                return "That conversation request ended, so the rename was canceled without any side effect."
            }
            if let effectLedger, !effectLedger.claim(.renameSession) {
                return "This turn already renamed the focused session. The rename was not repeated."
            }
            renameSession(sessionID, to: newName)
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Reset this session's Attaché name back to the Codex default."
                : "Renamed this session to \"\(trimmed)\" in Attaché."
        }
    }

    /// Stage a personality-requested agent instruction. The first-use enable
    /// sheet always gates the session and model-originated handoffs always keep
    /// a final native confirmation regardless of the Tell Agent send policy.
    ///
    /// Not `private` (INF-246): unit tests call this directly to verify a
    /// mismatched `intended_agent` produces no side effect (no
    /// `PendingAgentSend`, no `requestSendToAgent` call, no staged
    /// instruction), not just the returned string.
    func applyStageAgentInstructionTool(
        arguments: String,
        target: AgentSendTarget?,
        sourceUtterance: String,
        effectLedger: ConversationTurnEffectLedger? = nil,
        authorization: ConversationRequestAuthorization? = nil
    ) async -> String {
        guard let decoded = Self.agentInstructionArguments(fromToolArguments: arguments) else {
            return "No instruction was provided to stage for the agent."
        }
        guard let target else {
            return "No agent session was explicitly focused when this conversation turn began."
        }
        // Freeze the complete send before crossing back to the UI actor. The
        // structured tool payload must never be recomputed from mutable call UI.
        let pending = PendingAgentSend(
            text: decoded.instruction,
            target: target,
            origin: .personalityTool,
            sourceUtterance: sourceUtterance
        )
        let intendedAgent = decoded.intendedAgent
        return await MainActor.run { [pending, intendedAgent] in
            if let authorization, !conversationRequestIsAuthorized(authorization) {
                return "That conversation request ended, so the instruction was canceled without staging or sending."
            }
            // Fail-closed mismatch gate (INF-246): compare the model-declared
            // intent against the already-frozen target's source and the
            // currently watched sources. This is a refusal only - it never
            // reroutes to a different target - and it runs before anything is
            // staged, so a mismatch has zero side effects.
            let focusedKind = SourceKind(rawValue: pending.target.sourceKind) ?? .generic
            let watchedSources = Set(attachedTargets.values.map(\.sourceKind))
            if let mismatch = AgentInstructionMismatch.evaluate(
                intendedAgent: intendedAgent,
                focusedSource: focusedKind,
                focusedTitle: pending.target.displayTitle,
                watchedSources: watchedSources
            ) {
                return mismatch.message
            }
            if let effectLedger, !effectLedger.claim(.agentInstruction) {
                return "This turn already staged an instruction for the focused agent. It was not staged, confirmed, or delivered again."
            }
            requestSendToAgent(pending.text, target: pending.target, origin: pending.origin, sourceUtterance: pending.sourceUtterance)
            if showTwoWayEnable {
                return "Attaché opened the first-use send-to-agent enable confirmation. Tell the user to review and confirm before anything is sent."
            }
            if pendingInstruction != nil {
                return "Attaché staged the instruction and opened the final send confirmation. Tell the user to review and confirm before anything is sent."
            }
            let status = intakeStatus.trimmingCharacters(in: .whitespacesAndNewlines)
            return status.isEmpty ? "Attaché could not stage that instruction." : status
        }
    }

    static func agentInstruction(fromToolArguments arguments: String) -> String? {
        agentInstructionArguments(fromToolArguments: arguments)?.instruction
    }

    /// Decodes both the instruction and the optional `intended_agent`
    /// (INF-246) from a `stage_agent_instruction` tool call. `agentInstruction(fromToolArguments:)`
    /// above stays in place, unchanged, for existing callers/tests that only
    /// need the instruction text.
    static func agentInstructionArguments(fromToolArguments arguments: String) -> (instruction: String, intendedAgent: String?)? {
        guard let decoded = try? JSONDecoder().decode(
            AgentInstructionToolArguments.self,
            from: Data(arguments.utf8)
        ) else { return nil }
        let instruction = decoded.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return nil }
        let intendedAgent = decoded.intendedAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (instruction, (intendedAgent?.isEmpty == false) ? intendedAgent : nil)
    }

    /// Applies a model's non-effectful memory proposal through local policy.
    /// The model-provided confirmation and egress wishes are never authority:
    /// Automatic storage is possible only when deterministic local comparison
    /// finds the exact normalized fact in the user's own clause. Tool-originated
    /// memories always start local-only; remote use requires the native per-item
    /// confirmation in Memory settings.
    @MainActor
    func applyMemoryProposalTool(
        arguments: String,
        sourceUtterance: String,
        personalityID: String,
        sourceLocator: String?,
        effectLedger: ConversationTurnEffectLedger? = nil,
        authorization: ConversationRequestAuthorization? = nil
    ) -> String {
        if let authorization, !conversationRequestIsAuthorized(authorization) {
            return "That conversation request ended, so the memory was canceled without being saved."
        }
        guard let decoded = Self.memoryProposalArguments(
            fromToolArguments: arguments,
            personalityID: personalityID
        ) else {
            return "That memory proposal was invalid and was not saved."
        }

        let userSupported = Self.memoryStatement(
            decoded.statement,
            isSupportedBy: sourceUtterance
        )
        let egress = Self.memoryEgressForToolProposal(decoded.egress)
        let mode = AttacheContextUIState.shared.memoryMode
        if let effectLedger, !effectLedger.claim(.memoryProposal) {
            return "This turn already handled a memory proposal. It was not saved or queued again."
        }
        let disposition = memoryRuntime.processProposal(
            statement: decoded.statement,
            type: decoded.type,
            scope: decoded.scope,
            sensitivity: decoded.sensitivity,
            egress: egress,
            sourceLocator: sourceLocator,
            explicitlyUserRequested: userSupported,
            mode: mode
        )
        memoryRuntime.publish(to: .shared)

        switch disposition {
        case .autoStored:
            return "The locally validated memory was saved on this Mac."
        case .queuedForReview:
            return "The memory suggestion is waiting for the user to review in Settings."
        case .rejected(let reason):
            return "Local memory policy rejected that suggestion (\(reason.rawValue))."
        case .ignored:
            return "Remembering is off, so nothing was saved or queued."
        }
    }

    static func memoryProposalArguments(
        fromToolArguments arguments: String,
        personalityID: String
    ) -> (
        statement: String,
        type: AttacheMemoryType,
        scope: AttacheMemoryScope,
        sensitivity: AttacheMemorySensitivity,
        egress: AttacheMemoryEgress
    )? {
        guard let decoded = try? JSONDecoder().decode(
            MemoryProposalToolArguments.self,
            from: Data(arguments.utf8)
        ) else { return nil }
        let statement = decoded.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty,
              statement.count <= 1_000,
              let type = AttacheMemoryType(rawValue: decoded.type),
              let sensitivity = AttacheMemorySensitivity(rawValue: decoded.sensitivity),
              let egress = AttacheMemoryEgress(rawValue: decoded.egress) else { return nil }

        let scope: AttacheMemoryScope
        switch decoded.scope {
        case "global":
            scope = .global
        case "personality":
            scope = .personality(personalityID)
        case "topic":
            guard let topic = decoded.scopeValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !topic.isEmpty,
                  topic.count <= 200 else { return nil }
            scope = .topic(topic)
        default:
            return nil
        }
        return (statement, type, scope, sensitivity, egress)
    }

    /// Conservative local support check used before an Automatic-mode write.
    /// Exact normalized clause matching preserves negation and modality. A
    /// paraphrase can still be queued for review, but it cannot silently gain
    /// user-authored authority from bag-of-words overlap.
    static func memoryStatement(_ statement: String, isSupportedBy userTurn: String) -> Bool {
        let proposed = normalizedMemoryClause(statement)
        guard proposed.count >= 2 else { return false }
        let clauses = userTurn.split { character in
            character == "." || character == "!" || character == "?"
                || character == ";" || character == "\n"
        }
        return clauses.contains { rawClause in
            var clause = normalizedMemoryClause(String(rawClause))
            for prefix in memoryCaptureLeadIns where clause.starts(with: prefix) {
                clause.removeFirst(prefix.count)
                break
            }
            return clause == proposed
        }
    }

    private static func normalizedMemoryClause(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static let memoryCaptureLeadIns: [[String]] = [
        ["please", "remember", "that"],
        ["remember", "that"],
        ["please", "remember"],
        ["remember"],
        ["please", "note", "that"],
        ["note", "that"],
        ["keep", "in", "mind", "that"]
    ]

    static func memoryEgressForToolProposal(
        _ requested: AttacheMemoryEgress
    ) -> AttacheMemoryEgress {
        _ = requested
        return .localOnly
    }

    // MARK: - System media controls

    private func setupConversationObservers() {
        playback.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in self?.handleReplyPlaybackChange(isPlaying: isPlaying) }
            .store(in: &cancellables)
        micTranscript.$transcript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in self?.handleConversationTranscript(text) }
            .store(in: &cancellables)

        // One choke point for everything CallPhase.derive(from:) reads, so
        // callPhase stays current without scattering refresh calls across
        // every mutation site (playback.isPaused/.isBusy in particular only
        // ever change inside SpeechPlaybackController, not here).
        Publishers.MergeMany(
            playback.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            playback.$isPaused.map { _ in () }.eraseToAnyPublisher(),
            playback.$isBusy.map { _ in () }.eraseToAnyPublisher(),
            micTranscript.$isListening.map { _ in () }.eraseToAnyPublisher(),
            micTranscript.$isPreparing.map { _ in () }.eraseToAnyPublisher(),
            $isConversing.map { _ in () }.eraseToAnyPublisher(),
            $conversationRecovery.map { _ in () }.eraseToAnyPublisher(),
            $conversationFallbackAnnouncement.map { _ in () }.eraseToAnyPublisher(),
            $pendingAssistantReply.map { _ in () }.eraseToAnyPublisher(),
            $expectingReplyAudio.map { _ in () }.eraseToAnyPublisher(),
            $composingNarrationTokens.map { _ in () }.eraseToAnyPublisher(),
            $voiceInputMode.map { _ in () }.eraseToAnyPublisher(),
            twoWay.$log.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.refreshCallPhase() }
        .store(in: &cancellables)
    }

    /// Pure-reducer wiring (INF-237): snapshot today's scattered call signals
    /// into `CallSignals` and let `CallPhase.derive(from:)` decide the phase.
    /// No UI reads `callPhase` yet; CallHUD/AttacheRootView still derive
    /// their own status text and error styling exactly as before (A2 wires
    /// the views to this).
    private func refreshCallPhase() {
        callPhase = CallPhase.derive(from: currentCallSignals())
    }

    /// Same choke-point pattern as `refreshCallPhase()` for the attache
    /// contract (INF-268): everything `AttacheActivitySignals` reads funnels
    /// through one subscription, so `attacheActivity` stays current without
    /// refresh calls scattered across mutation sites. Attention transitions
    /// and watcher phrases arrive on their own poll cadence (2s / 1.5s), which
    /// also ages fresh tool signals out of `toolRunning` without a timer.
    private func setupAttacheActivityObservers() {
        typingMonitor.onChange = { [weak self] typing in
            DispatchQueue.main.async { self?.userTyping = typing }
        }
        typingMonitor.start()
        Publishers.MergeMany(
            playback.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            playback.$isPaused.map { _ in () }.eraseToAnyPublisher(),
            playback.$isBusy.map { _ in () }.eraseToAnyPublisher(),
            playback.$currentCardID.map { _ in () }.eraseToAnyPublisher(),
            $isConversing.map { _ in () }.eraseToAnyPublisher(),
            $conversationRecovery.map { _ in () }.eraseToAnyPublisher(),
            $composingNarrationTokens.map { _ in () }.eraseToAnyPublisher(),
            $sessionAttention.map { _ in () }.eraseToAnyPublisher(),
            $activityPhrases.map { _ in () }.eraseToAnyPublisher(),
            $attachedTargets.map { _ in () }.eraseToAnyPublisher(),
            $cards.map { _ in () }.eraseToAnyPublisher(),
            $userTyping.map { _ in () }.eraseToAnyPublisher(),
            $subAgentCounts.map { _ in () }.eraseToAnyPublisher(),
            $attachedCodexSessionID.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.refreshAttacheActivity() }
        .store(in: &cancellables)
    }

    /// The per-session fleet for renderers (INF-275): every watched session,
    /// its mote state from the attention map, the focused flag, and the live
    /// sub-agent count. Sorted stably so mote layouts never shuffle.
    private func currentFleet() -> [AttacheFleetSession] {
        attachedTargets.values
            .sorted { $0.id < $1.id }
            .map { target in
                let state: AttacheFleetSession.State
                switch sessionAttention[target.id] {
                case .active: state = .working
                case .awaitingAnswer, .possiblyWaiting: state = .blocked
                case .turnComplete: state = .finished
                case .erroredRecently, .quiet, nil: state = .quiet
                }
                return AttacheFleetSession(
                    id: target.id,
                    agent: AttacheAgentIdentity(sourceKindRawValue: target.sourceKind.rawValue),
                    state: state,
                    isFocused: target.id == attachedCodexSessionID,
                    activeSubAgents: subAgentCounts[target.id] ?? 0,
                    title: target.displayTitle
                )
            }
    }

    private func refreshAttacheActivity() {
        var next: AttacheActivityState
        if let simulatedActivity {
            next = simulatedActivity
        } else {
            let derived = AttacheActivityState.derive(
                from: currentActivitySignals(),
                audio: playback.clock.renderState
            )
            next = activityDamper.damp(derived, now: Date())
            // Focus-tied compaction: only the session the user is watching
            // drives the squish, so switching focus releases it.
            next.compactingSince = attachedCodexSessionID.flatMap { compactingSince[$0] }
        }
        if next != attacheActivity {
            attacheActivity = next
        }
    }

    /// Debug hook for the activity simulator panel: fires a one-shot moment
    /// through the same publisher real transitions use.
    func triggerMoment(_ kind: AttacheActivityMoment.Kind, agent: AttacheAgentIdentity) {
        attacheMoment = AttacheActivityMoment(kind: kind, agent: agent, at: Date())
    }

    /// Maps a lifecycle-hook event type to the one-shot character moment it plays.
    private static func momentKind(forEventType type: String) -> AttacheActivityMoment.Kind? {
        switch type {
        case "turn_failed": return .errored
        case "session_start": return .greet
        case "session_end": return .farewell
        case "session_setup": return .configuring
        case "permission_ask": return .permissionAsk
        case "permission_denied": return .permissionDenied
        default: return nil
        }
    }

    /// Maps a watched session to the bubble identity its events light up.
    private func agentIdentity(forSessionID sessionID: String) -> AttacheAgentIdentity {
        if let target = attachedTargets[sessionID] {
            return AttacheAgentIdentity(sourceKindRawValue: target.sourceKind.rawValue)
        }
        if let record = sessionRecords.first(where: { $0.id == sessionID }) {
            return AttacheAgentIdentity(sourceKindRawValue: record.sourceKind.rawValue)
        }
        return .none
    }

    private func currentActivitySignals() -> AttacheActivitySignals {
        // Multi-session priority (INF-271): an exact ask beats a soft
        // possibly-waiting, and within a tier the most recent transition
        // wins, so the bubble always shows whose event the character is reacting to.
        var blockedCandidates: [(exact: Bool, when: Date, agent: AttacheAgentIdentity)] = []
        var errored: (when: Date, agent: AttacheAgentIdentity)?
        var working: (when: Date, agent: AttacheAgentIdentity)?
        for (sessionID, state) in sessionAttention {
            let when = attentionChangedAt[sessionID] ?? .distantPast
            switch state {
            case .awaitingAnswer:
                blockedCandidates.append((true, when, agentIdentity(forSessionID: sessionID)))
            case .possiblyWaiting:
                blockedCandidates.append((false, when, agentIdentity(forSessionID: sessionID)))
            case .erroredRecently:
                if (errored?.when ?? .distantPast) < when {
                    errored = (when, agentIdentity(forSessionID: sessionID))
                }
            case .active:
                if (working?.when ?? .distantPast) < when {
                    working = (when, agentIdentity(forSessionID: sessionID))
                }
            case .turnComplete, .quiet:
                break
            }
        }
        let blockedAgent = blockedCandidates
            .sorted { lhs, rhs in
                if lhs.exact != rhs.exact { return lhs.exact }
                return lhs.when > rhs.when
            }
            .first?.agent
        let erroredAgent = errored?.agent
        let workingAgent = working?.agent

        let freshTool = activityPhrases
            .filter { Date().timeIntervalSince($0.lastSeen) <= Self.toolActivityDwell }
            .max { $0.lastSeen < $1.lastSeen }

        let speakingAgent: AttacheAgentIdentity? = playback.currentCardID.flatMap { id in
            cards.first { $0.id == id }.map { AttacheAgentIdentity(sourceKindRawValue: $0.sourceKind) }
        }

        // The "preparing" clock (agentResponding) is driven by composing a
        // recap or synthesizing its audio. Two guards (INF-290): reset the
        // burst clock whenever composing/prep genuinely idles, so its counter
        // reflects the current update rather than accumulating across
        // back-to-back composes on a busy pinned session; and self-heal after
        // a hard cap, so a hung compose (a stalled presentation model that
        // never calls back) can never freeze the crown on a runaway clock.
        let composeSource = composingNarrationTokens.values.first
        let isPreparing = composeSource != nil || playback.isBusy
        if isPreparing {
            if respondingBurstStartedAt == nil { respondingBurstStartedAt = Date() }
        } else {
            respondingBurstStartedAt = nil
        }
        let respondingAgent: AttacheAgentIdentity? = {
            guard isPreparing else { return nil }
            if let started = respondingBurstStartedAt,
               Date().timeIntervalSince(started) > Self.respondingSelfHealSeconds {
                return nil
            }
            if let composeSource { return AttacheAgentIdentity(sourceKindRawValue: composeSource) }
            return speakingAgent ?? AttacheAgentIdentity.none
        }()

        return AttacheActivitySignals(
            hasPinnedSessions: !attachedTargets.isEmpty,
            blockedAgent: blockedAgent,
            erroredAgent: erroredAgent,
            workingAgent: workingAgent,
            respondingAgent: respondingAgent,
            toolAgent: freshTool.map { AttacheAgentIdentity(sourceKindRawValue: $0.agentKind.rawValue) },
            toolKind: freshTool?.toolKind,
            playbackIsPlaying: playback.isPlaying,
            playbackIsPaused: playback.isPaused,
            speakingAgent: speakingAgent,
            isConversing: isConversing,
            hasConversationFailure: conversationRecovery != nil,
            userTyping: userTyping,
            unreadCount: unreadCount,
            hasCards: !cards.isEmpty,
            fleet: currentFleet()
        )
    }

    private func currentCallSignals() -> CallSignals {
        let failure = conversationRecovery.map {
            CallSignals.Failure(category: $0.category, message: $0.errorMessage)
        }
        // The instruction most relevant to the live call composer: the newest
        // one addressed to whatever session Tell Agent would target right
        // now. `twoWay.log` is already newest-first. A failed instruction the
        // user has already moved past (acknowledged at call start) is treated
        // as no instruction at all, not skipped in favor of an older one.
        let newestSend = twoWayTarget.flatMap { target in
            twoWay.log.first { $0.sessionID == target.sessionID }
        }
        let pendingSend = (newestSend.map { $0.state == .failed && acknowledgedFailedSendIDs.contains($0.id) } == true)
            ? nil
            : newestSend
        return CallSignals(
            isConversing: isConversing,
            conversationWaitStartedAt: conversationWaitStartedAt,
            micIsListening: micTranscript.isListening,
            micIsPreparing: micTranscript.isPreparing,
            voiceInputMode: voiceInputMode.rawValue,
            playbackIsPlaying: playback.isPlaying,
            playbackIsPaused: playback.isPaused,
            playbackIsBusy: playback.isBusy,
            isComposingNarration: !composingNarrationTokens.isEmpty,
            pendingAssistantReply: pendingAssistantReply,
            pendingSend: pendingSend,
            failure: failure,
            fallbackAnnouncement: conversationFallbackAnnouncement
        )
    }

    private func setupMediaRemote() {
        mediaRemote.setSkipInterval(seconds: seekStepSeconds)
        mediaRemote.activate(handlers: MediaRemoteController.Handlers(
            togglePlayPause: { [weak self] in self?.remoteTogglePlayPause() },
            play: { [weak self] in self?.remotePlay() },
            pause: { [weak self] in self?.remotePause() },
            skipForward: { [weak self] in self?.remoteSkip(forward: true) },
            skipBackward: { [weak self] in self?.remoteSkip(forward: false) },
            seek: { [weak self] seconds in self?.remoteSeek(toSeconds: seconds) }
        ))

        // Refresh the now-playing widget whenever transport state flips (play,
        // pause, finish). Seeks update it inline since they don't change these.
        Publishers.Merge3(
            playback.$isPlaying.map { _ in () },
            playback.$isPaused.map { _ in () },
            playback.$currentCardID.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.refreshNowPlaying() }
        .store(in: &cancellables)
    }

    private func refreshNowPlaying() {
        guard let cardID = playback.currentCardID else {
            mediaRemote.clear()
            return
        }
        let title = (selectedCard?.id == cardID ? selectedCard?.sessionTitle : nil) ?? "Attaché update"
        let duration = playback.durationMs > 0 ? playback.durationMs : (selectedCard?.durationMs ?? 0)
        mediaRemote.updateNowPlaying(
            title: title,
            artist: AttacheAppSupport.appDisplayName,
            durationMs: duration,
            elapsedMs: playback.clock.currentTimeMs,
            playing: playback.isPlaying && !playback.isPaused
        )
    }

    private func remoteTogglePlayPause() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.playback.isPlaying {
                self.playback.togglePause()
            } else if self.selectedCard != nil {
                self.playSelected()
            }
        }
    }

    private func remotePlay() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.playback.isPaused {
                self.playback.togglePause()
            } else if self.playback.currentCardID == nil, self.selectedCard != nil {
                self.playSelected()
            }
        }
    }

    private func remotePause() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.playback.isPlaying, !self.playback.isPaused else { return }
            self.playback.togglePause()
        }
    }

    private func remoteSkip(forward: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.playback.isPlaying, self.playback.currentCardID == nil {
                self.playback.seek(by: self.seekStepSeconds * 1000 * (forward ? 1 : -1))
            } else {
                forward ? self.skipForward() : self.skipBackward()
            }
        }
    }

    private func remoteSeek(toSeconds seconds: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.playback.isPlaying, self.playback.currentCardID == nil {
                self.playback.seek(to: Int(seconds * 1000))
                return
            }
            guard let card = self.selectedCard, self.playback.currentCardID == card.id else { return }
            self.playback.seek(to: Int(seconds * 1000))
            self.refreshNowPlaying()
        }
    }

    func toggleVoiceInput() {
        micTranscript.toggle()
    }

    func refreshPresentationStatus() {
        guard presentationLLMEnabled else {
            presentationStatus = "Plain readback enabled"
            return
        }
        let provider = presentationProvider
        let model = presentationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasKey = !presentationAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !presentationAPIKeySecretRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let configured = provider.requiresAPIKey ? (hasKey && !model.isEmpty) : !model.isEmpty
        guard configured else {
            presentationStatus = provider.requiresAPIKey
                ? "\(provider.title) presentation LLM needs an API key."
                : "\(provider.title) presentation LLM not configured."
            return
        }
        presentationStatus = "Presentation LLM: \(provider.title) / \(presentationModel)"
    }

    func openAttacheMemoryFile() {
        do {
            let url = try attacheMemoryStore.ensureMemoryFile()
            NSWorkspace.shared.open(url)
            attacheMemoryStatus = "Opened memory."
        } catch {
            attacheMemoryStatus = "Memory unavailable: \(error.localizedDescription)"
        }
    }

    @MainActor
    func exportStructuredMemory() {
        guard let data = memoryRuntime.exportData() else {
            memoryRuntime.publish(to: .shared, status: "Attaché could not prepare the memory export.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Attaché Memory"
        panel.nameFieldStringValue = "Attache-Memory.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: [.atomic])
            memoryRuntime.publish(to: .shared, status: "Memory exported.")
        } catch {
            memoryRuntime.publish(to: .shared, status: "Memory export failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    func importStructuredMemory() {
        let panel = NSOpenPanel()
        panel.title = "Import Attaché Memory"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 10_000_000,
                  let result = memoryRuntime.importData(data) else {
                memoryRuntime.publish(to: .shared, status: "That file is not a valid Attaché memory export.")
                return
            }
            memoryRuntime.publish(
                to: .shared,
                status: "Imported \(result.imported) memories; rejected \(result.rejected)."
            )
        } catch {
            memoryRuntime.publish(to: .shared, status: "Memory import failed: \(error.localizedDescription)")
        }
    }

    // MARK: Cloud consent

    /// Whether choosing this presentation provider will send agent output,
    /// transcripts, and read files off this Mac. CLI providers run a local tool
    /// under your existing login and expose no Attaché-chosen endpoint, so they
    /// don't trip the consent moment; HTTP providers do when their base URL is
    /// non-loopback (so a Custom endpoint pointed at localhost stays local).
    /// Subscription CLIs (Codex, Claude Code) run locally but send prompts to a
    /// remote subscription, so they are disclosed as remote (INF-307).
    func presentationProviderSendsToCloud(_ provider: AttachePresentationProvider) -> Bool {
        provider.dataEgress(endpoint: endpointForIntegration(provider)).isRemoteService
    }

    var presentationSendsToCloud: Bool { presentationProviderSendsToCloud(presentationProvider) }
    var voiceSendsToCloud: Bool { effectiveSpeechProvider.sendsToCloud }

    private var effectiveSpeechProvider: AttacheSpeechProvider {
        selectedSpeechConfiguration.resolvedForPlayback(
            systemVoiceIdentifier: speechVoiceIdentifier
        ).provider
    }

    /// Cloud acknowledgment is scoped to provider, normalized endpoint, and
    /// egress class. Changing a Custom URL or moving Ollama between loopback
    /// and a remote host invalidates the old consent automatically (INF-342).
    func cloudConsentAcknowledged(for provider: AttachePresentationProvider) -> Bool {
        let scope = presentationConsentScope(for: provider)
        return consentedCloudPresentationScopes().contains(scope.storageKey)
    }

    func acknowledgeCloudConsent(for provider: AttachePresentationProvider) {
        var scopes = consentedCloudPresentationScopes()
        guard scopes.insert(presentationConsentScope(for: provider).storageKey).inserted else { return }
        defaults.set(Array(scopes).sorted(), forKey: AttachePreferenceKey.cloudConsentPresentationProviders)
    }

    func presentationConsentScope(for provider: AttachePresentationProvider) -> PresentationConsentScope {
        PresentationConsentScope(provider: provider, endpoint: endpointForIntegration(provider))
    }

    private func consentedCloudPresentationScopes() -> Set<String> {
        Set(defaults.array(forKey: AttachePreferenceKey.cloudConsentPresentationProviders) as? [String] ?? [])
    }

    /// Converts provider-only grants to the endpoint that is configured at
    /// migration time. The old global boolean is consumed only once, while
    /// provider-only array entries are upgraded even on profiles whose older
    /// migration flag was already set.
    private func migrateCloudConsentToPerProvider() {
        let stored = consentedCloudPresentationScopes()
        var scoped = Set(stored.filter(PresentationConsentScope.isScopedStorageKey))
        for raw in stored where !PresentationConsentScope.isScopedStorageKey(raw) {
            guard let provider = AttachePresentationProvider(rawValue: raw) else { continue }
            scoped.insert(presentationConsentScope(for: provider).storageKey)
        }

        if !defaults.bool(forKey: AttachePreferenceKey.cloudConsentPresentationMigrationDone) {
            if defaults.bool(forKey: AttachePreferenceKey.cloudConsentPresentation) {
                scoped.insert(presentationConsentScope(for: presentationProvider).storageKey)
            }
            defaults.set(true, forKey: AttachePreferenceKey.cloudConsentPresentationMigrationDone)
        }
        if scoped != stored {
            defaults.set(Array(scoped).sorted(), forKey: AttachePreferenceKey.cloudConsentPresentationProviders)
        }
    }

    func voiceConsentScope(
        for provider: AttacheSpeechProvider,
        xaiBaseURL requestedXAIBaseURL: String? = nil
    ) -> VoiceConsentScope {
        VoiceConsentScope(
            provider: provider,
            xaiBaseURL: provider == .xai ? (requestedXAIBaseURL ?? xaiBaseURL) : nil
        )
    }

    func cloudVoiceConsentAcknowledged(
        for provider: AttacheSpeechProvider,
        xaiBaseURL requestedXAIBaseURL: String? = nil
    ) -> Bool {
        guard provider.sendsToCloud else { return true }
        return consentedCloudVoiceScopes().contains(
            voiceConsentScope(for: provider, xaiBaseURL: requestedXAIBaseURL).storageKey
        )
    }

    func acknowledgeCloudVoiceConsent(
        for provider: AttacheSpeechProvider,
        xaiBaseURL requestedXAIBaseURL: String? = nil
    ) {
        guard provider.sendsToCloud else { return }
        var scopes = consentedCloudVoiceScopes()
        let key = voiceConsentScope(for: provider, xaiBaseURL: requestedXAIBaseURL).storageKey
        guard scopes.insert(key).inserted else { return }
        defaults.set(Array(scopes).sorted(), forKey: AttachePreferenceKey.cloudConsentVoiceScopes)
        applySpeechConfiguration()
    }

    func voiceConsentDestination(
        for provider: AttacheSpeechProvider,
        xaiBaseURL requestedXAIBaseURL: String? = nil
    ) -> String {
        voiceConsentScope(for: provider, xaiBaseURL: requestedXAIBaseURL).normalizedEndpoint
    }

    private func consentedCloudVoiceScopes() -> Set<String> {
        Set(defaults.array(forKey: AttachePreferenceKey.cloudConsentVoiceScopes) as? [String] ?? [])
    }

    /// The former voice consent was one global boolean. Consume it once and
    /// credit only the provider and endpoint selected at migration time. A later
    /// provider or xAI endpoint change therefore requires a fresh approval.
    private func migrateCloudVoiceConsentToScopes() {
        guard !defaults.bool(forKey: AttachePreferenceKey.cloudConsentVoiceMigrationDone) else { return }
        var scopes = Set(consentedCloudVoiceScopes().filter(VoiceConsentScope.isScopedStorageKey))
        let legacyCanMigrate = speechProvider != .xai
            || voiceConsentScope(for: .xai).normalizedEndpoint == PresentationConsentScope.normalize("https://api.x.ai/v1")
        if defaults.bool(forKey: AttachePreferenceKey.cloudConsentVoice),
           speechProvider.sendsToCloud,
           legacyCanMigrate {
            scopes.insert(voiceConsentScope(for: speechProvider).storageKey)
        }
        defaults.set(Array(scopes).sorted(), forKey: AttachePreferenceKey.cloudConsentVoiceScopes)
        defaults.set(true, forKey: AttachePreferenceKey.cloudConsentVoiceMigrationDone)
    }

    func selectPresentationProvider(_ provider: AttachePresentationProvider) {
        let previousProvider = presentationProvider
        let existingModel = presentationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultModels = AttachePresentationProvider.allCases.map(\.defaultModel)

        presentationProvider = provider
        if provider != previousProvider {
            presentationAPIKeySecretRef = ""
        }
        presentationBaseURL = endpointForIntegration(provider)
        if existingModel.isEmpty ||
            existingModel == previousProvider.defaultModel ||
            defaultModels.contains(existingModel) {
            presentationModel = provider.defaultModel
        }
        if !provider.supportsReasoningEffort {
            presentationReasoningEffort = "none"
        } else if previousProvider != provider || presentationReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            presentationReasoningEffort = provider.defaultReasoningEffort
        }
        presentationServiceTier = provider.supportsServiceTier ? provider.defaultServiceTier : "default"
        presentationAPIKey = readConfiguredSecret(account: provider.developmentSecretAccount) ?? ""
        if provider != previousProvider {
            presentationModelOptions = []
            presentationModelDiscoveryStatus = "Model discovery not checked"
        }
        applyCurrentPresentationModelCapabilities()
        refreshPresentationStatus()
        intakeStatus = "Presentation LLM provider set to \(provider.title)."
    }

    // MARK: Integrations

    func endpointForIntegration(_ provider: AttachePresentationProvider) -> String {
        switch provider {
        case .ollama: return ollamaBaseURL
        case .custom: return customBaseURL
        case .xai, .groq: return provider.defaultBaseURL
        case .claudeCLI, .codexCLI: return ""
        }
    }

    var connectedTextProviders: [AttachePresentationProvider] {
        AttachePresentationProvider.personalityInferenceCases.filter { provider in
            switch provider {
            case .xai: return !xaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .groq: return !groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .custom: return !customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .ollama: return true
            case .claudeCLI: return CLILanguageModel.isLikelyInstalled(.claude)
            case .codexCLI: return false
            }
        }
    }

    var connectedVoiceEngines: [AttacheSpeechProvider] {
        var engines: [AttacheSpeechProvider] = [.system]
        if !elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { engines.append(.elevenLabs) }
        if !xaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { engines.append(.xai) }
        if !effectiveOpenAIVoiceKey.isEmpty { engines.append(.openai) }
        return engines
    }

    /// The OpenAI key to use for voices: the dedicated OpenAI integration key, or, if
    /// that's empty, the key from the OpenAI-compatible row when it points at OpenAI,
    /// so one OpenAI key works whether it was entered in the OpenAI or OpenAI-compatible row.
    var effectiveOpenAIVoiceKey: String {
        let dedicated = openaiVoiceAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dedicated.isEmpty { return dedicated }
        let customKey = customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = customBaseURL.isEmpty
            ? AttachePresentationProvider.custom.defaultBaseURL
            : customBaseURL
        return (!customKey.isEmpty && Self.isOfficialOpenAIEndpoint(base)) ? customKey : ""
    }

    static func isOfficialOpenAIEndpoint(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "api.openai.com",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port == nil || components.port == 443 else {
            return false
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty || path == "v1"
    }

    func saveXAIIntegration() {
        saveXAIKeyAndLoadVoices()
        if presentationProvider == .xai { presentationAPIKey = xaiAPIKey }
        refreshPresentationStatus()
    }

    func saveGroqIntegration() { saveIntegrationTextKey(groqAPIKey, provider: .groq) }
    func saveCustomIntegration() { saveIntegrationTextKey(customAPIKey, provider: .custom) }

    private func saveIntegrationTextKey(_ key: String, provider: AttachePresentationProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try AttacheSecretVault.save(trimmed, account: provider.developmentSecretAccount)
            setSecretAccountConfigured(provider.developmentSecretAccount, configured: !trimmed.isEmpty)
            if presentationProvider == provider {
                presentationAPIKey = trimmed
                loadPresentationModels()
            }
            refreshPresentationStatus()
            intakeStatus = trimmed.isEmpty
                ? "\(provider.title) integration cleared."
                : "\(provider.title) integration saved."
        } catch {
            intakeStatus = "\(provider.title) key save failed: \(error.localizedDescription)"
        }
    }

    private func migrateLegacyPresentationKeys() {
        for provider in AttachePresentationProvider.allCases where provider.requiresAPIKey {
            let newAccount = provider.developmentSecretAccount
            let legacyAccount = "presentation-llm-\(provider.rawValue)-api-key"
            let hasNew = !(readConfiguredSecret(account: newAccount) ?? "").isEmpty
            if !hasNew,
               isSecretAccountConfigured(legacyAccount),
               let legacy = AttacheSecretVault.read(account: legacyAccount),
               !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? AttacheSecretVault.save(legacy, account: newAccount)
                setSecretAccountConfigured(newAccount, configured: true)
            }
        }
    }

    func healthStatus(_ id: String) -> IntegrationHealth {
        integrationHealth[id] ?? .unconfigured
    }

    func checkAllIntegrations() {
        let now = Date()
        for id in ["xai", "elevenlabs", "openai", "groq", "ollama", "custom", "codex", "claude", "ondevice"] {
            if case .checking = healthStatus(id) { continue }
            if case .healthy = healthStatus(id),
               let last = integrationLastChecked[id], now.timeIntervalSince(last) < 60 {
                continue
            }
            checkIntegration(id)
        }
    }

    func checkIntegration(_ id: String) {
        switch id {
        case "ondevice":
            integrationHealth[id] = .healthy
        case "codex":
            integrationHealth[id] = .unhealthy("Unavailable for personality inference until Codex CLI can disable native file-reading tools.")
        case "claude":
            integrationHealth[id] = CLILanguageModel.locate("claude") == nil ? .unconfigured : .healthy
        case "xai":
            runHealthCheck(id, configured: isSet(xaiAPIKey)) {
                _ = try await AttachePresentationModelService.fetchModels(
                    provider: .xai, baseURLText: AttachePresentationProvider.xai.defaultBaseURL, apiKey: self.xaiAPIKey)
            }
        case "groq":
            runHealthCheck(id, configured: isSet(groqAPIKey)) {
                _ = try await AttachePresentationModelService.fetchModels(
                    provider: .groq, baseURLText: AttachePresentationProvider.groq.defaultBaseURL, apiKey: self.groqAPIKey)
            }
        case "custom":
            runHealthCheck(id, configured: isSet(customAPIKey)) {
                _ = try await AttachePresentationModelService.fetchModels(
                    provider: .custom, baseURLText: self.customBaseURL, apiKey: self.customAPIKey)
            }
        case "ollama":
            runHealthCheck(id, configured: true) {
                _ = try await AttachePresentationModelService.fetchModels(
                    provider: .ollama, baseURLText: self.ollamaBaseURL, apiKey: "")
            }
        case "elevenlabs":
            runHealthCheck(id, configured: isSet(elevenLabsAPIKey)) {
                _ = try await AttacheRemoteVoiceService.fetchElevenLabsVoices(apiKey: self.elevenLabsAPIKey)
            }
        case "openai":
            runHealthCheck(id, configured: isSet(effectiveOpenAIVoiceKey)) {
                try await AttacheRemoteVoiceService.verifyOpenAIKey(apiKey: self.effectiveOpenAIVoiceKey)
            }
        default:
            break
        }
    }

    func integrationID(for provider: AttachePresentationProvider) -> String {
        switch provider {
        case .xai: return "xai"
        case .ollama: return "ollama"
        case .groq: return "groq"
        case .custom: return "custom"
        case .codexCLI: return "codex"
        case .claudeCLI: return "claude"
        }
    }

    var healthyModelProviders: [AttachePresentationProvider] {
        AttachePresentationProvider.personalityInferenceCases.filter {
            if case .healthy = healthStatus(integrationID(for: $0)) { return true }
            return false
        }
    }

    var onboardingModelReady: Bool {
        guard healthyModelProviders.contains(presentationProvider) else { return false }
        if presentationProvider.isCLI { return true }
        return !presentationModelOptions.isEmpty
            && presentationModelOptions.contains { $0.id == presentationModel }
    }

    func useHealthyModelProviderForOnboarding(_ provider: AttachePresentationProvider) {
        guard healthyModelProviders.contains(provider) else { return }
        selectPresentationProvider(provider)
        if provider.isCLI {
            selectPresentationModelID(provider.defaultModel)
        } else {
            loadPresentationModels()
        }
    }

    private func isSet(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func configuredSecretAccounts() -> Set<String> {
        Set(defaults.array(forKey: AttachePreferenceKey.configuredSecretAccounts) as? [String] ?? [])
    }

    private func isSecretAccountConfigured(_ account: String) -> Bool {
        configuredSecretAccounts().contains(account)
    }

    private func readConfiguredSecret(account: String) -> String? {
        guard isSecretAccountConfigured(account) else { return nil }
        return AttacheSecretVault.read(account: account)
    }

    private func setSecretAccountConfigured(_ account: String, configured: Bool) {
        var accounts = configuredSecretAccounts()
        if configured {
            accounts.insert(account)
        } else {
            accounts.remove(account)
        }
        defaults.set(Array(accounts).sorted(), forKey: AttachePreferenceKey.configuredSecretAccounts)
    }

    private func runHealthCheck(_ id: String, configured: Bool, _ work: @escaping () async throws -> Void) {
        guard configured else {
            integrationHealth[id] = .unconfigured
            return
        }
        if case .checking = integrationHealth[id] ?? .unconfigured { return }
        integrationLastChecked[id] = Date()
        integrationHealth[id] = .checking
        Task {
            do {
                try await work()
                await MainActor.run { self.integrationHealth[id] = .healthy }
            } catch {
                await MainActor.run { self.integrationHealth[id] = .unhealthy(error.localizedDescription) }
            }
        }
    }

    /// - Parameter completion: always called exactly once, sync or async,
    ///   regardless of which branch below runs. `selectConversationRecoveryProvider`
    ///   relies on this to know when it's safe to stop redirecting
    ///   `presentationModel`/`presentationReasoningEffort`/etc. persistence to
    ///   the `conversation` role's per-role keys (INF-247): the capability
    ///   auto-correction inside the MainActor blocks below can still mutate
    ///   those published vars after the synchronous part of a recovery
    ///   switch returns, and that write must land on the same key the rest
    ///   of the switch did.
    func loadPresentationModels(preserveCurrentSelection: Bool = false, completion: (() -> Void)? = nil) {
        let provider = presentationProvider
        let baseURL = presentationBaseURL
        let apiKey = presentationAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? readConfiguredSecret(account: provider.developmentSecretAccount) ?? ""
            : presentationAPIKey

        if provider.requiresAPIKey,
           apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           presentationAPIKeySecretRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            presentationModelOptions = []
            presentationModelDiscoveryStatus = "Enter or save a \(provider.title) API key to load models."
            completion?()
            return
        }

        presentationModelDiscoveryStatus = "Loading \(provider.title) models..."
        modelDiscoveryTask?.cancel()
        modelDiscoveryTask = Task {
            do {
                let key: String
                if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    key = apiKey
                } else {
                    // This discovers models for the main Settings > Model row,
                    // which is the shared "main model" any role with no
                    // per-role override (see roleModelProvider/D3) falls back
                    // to; .conversation is the reasonable placeholder role for
                    // that row.
                    let settings = AttachePresentationSettings.load(
                        role: .conversation,
                        defaults: self.defaults,
                        environment: self.presentationEnvironment,
                        resolveSecrets: true
                    )
                    key = settings.apiKey
                }
                let models = try await AttachePresentationModelService.fetchModels(
                    provider: provider,
                    baseURLText: baseURL,
                    apiKey: key
                )
                guard !Task.isCancelled else {
                    // Superseded or owner deallocated: fire the completion so
                    // callers waiting on it (recovery switches) still unwind,
                    // but never touch model state from a stale discovery.
                    await MainActor.run { completion?() }
                    return
                }
                await MainActor.run {
                    defer { completion?() }
                    guard self.presentationProvider == provider,
                          self.presentationBaseURL == baseURL else { return }
                    self.presentationModelOptions = models
                    if models.contains(where: { $0.id == self.presentationModel }) {
                        self.applyCurrentPresentationModelCapabilities()
                    } else if !preserveCurrentSelection, let first = models.first {
                        self.selectPresentationModel(first)
                    }
                    self.presentationModelDiscoveryStatus = models.isEmpty
                        ? "\(provider.title) returned no models."
                        : "Loaded \(models.count) \(provider.title) models."
                    self.refreshPresentationStatus()
                }
            } catch {
                guard !Task.isCancelled else {
                    await MainActor.run { completion?() }
                    return
                }
                await MainActor.run {
                    defer { completion?() }
                    guard self.presentationProvider == provider,
                          self.presentationBaseURL == baseURL else { return }
                    self.presentationModelOptions = []
                    self.presentationModelDiscoveryStatus = "\(provider.title) model discovery failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func selectPresentationModel(_ option: AttachePresentationModelOption) {
        presentationModel = option.id
        applyCurrentPresentationModelCapabilities()
        refreshPresentationStatus()
    }

    func selectPresentationModelID(_ id: String) {
        presentationModel = id
        applyCurrentPresentationModelCapabilities()
        refreshPresentationStatus()
    }

    // MARK: Per-role model overrides (Settings > Model > Advanced, INF-253/D3)

    /// Restores whichever per-role overrides were saved previously, so the
    /// Advanced disclosure reflects them on launch. A role with no stored
    /// `.provider` key stays out of every dictionary here, which the UI reads
    /// as "Use main model".
    private func loadRoleModelOverrides() {
        for role in ModelRole.allCases {
            guard let rawProvider = defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .provider)) else { continue }
            let legacyLMStudio = AttachePresentationProvider.isLegacyLMStudio(
                explicitValue: rawProvider,
                baseURLText: defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .baseURL))
            )
            guard let provider = legacyLMStudio ? .ollama : AttachePresentationProvider(rawValue: rawProvider) else { continue }
            roleModelProvider[role] = provider
            roleModelID[role] = legacyLMStudio
                ? provider.defaultModel
                : (defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .model)) ?? provider.defaultModel)
            roleReasoningEffort[role] = defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .reasoningEffort))
                ?? provider.defaultReasoningEffort
            roleServiceTier[role] = defaults.string(forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .serviceTier))
                ?? provider.defaultServiceTier
            if legacyLMStudio {
                defaults.set(provider.rawValue, forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .provider))
                defaults.set(provider.defaultModel, forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .model))
                defaults.removeObject(forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .baseURL))
            }
        }
    }

    /// The reasoning-effort levels available for a role's current override,
    /// from its discovered models when loaded, else the same provider
    /// fallback table the main row uses. Empty means the control is hidden,
    /// same convention as `selectedPresentationReasoningOptions`.
    func roleReasoningOptions(for role: ModelRole) -> [String] {
        guard let provider = roleModelProvider[role] else { return [] }
        let modelID = roleModelID[role] ?? provider.defaultModel
        if let option = (roleModelOptions[role] ?? []).first(where: { $0.id == modelID }) {
            return option.reasoningEfforts
        }
        return AttachePresentationModelService.fallbackReasoningEfforts(provider: provider, modelID: modelID)
    }

    /// Same idea as `selectedPresentationServiceTierOptions`, scoped to one role.
    func roleServiceTierOptions(for role: ModelRole) -> [AttachePresentationServiceTierOption] {
        guard let provider = roleModelProvider[role] else { return [] }
        let modelID = roleModelID[role] ?? provider.defaultModel
        let options: [AttachePresentationServiceTierOption]
        if let option = (roleModelOptions[role] ?? []).first(where: { $0.id == modelID }) {
            options = option.serviceTiers
        } else {
            options = AttachePresentationModelService.fallbackServiceTierOptions(provider: provider, modelID: modelID)
        }
        guard !options.isEmpty else { return [] }
        if options.contains(where: { $0.id == "default" }) { return options }
        return [AttachePresentationServiceTierOption(id: "default", title: "Default", detail: "Use the provider's default tier")] + options
    }

    /// Clamps a role's stored reasoning-effort/service-tier choice to what its
    /// current provider/model actually supports, the same guard the main row
    /// applies in `applyCapabilitiesForSelectedModel`/`applyFallbackCapabilitiesForCurrentModel`.
    private func clampRoleCapabilities(for role: ModelRole) {
        guard let provider = roleModelProvider[role] else { return }
        let reasoningOptions = roleReasoningOptions(for: role)
        let currentReasoning = (roleReasoningEffort[role] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if reasoningOptions.isEmpty {
            roleReasoningEffort[role] = "none"
        } else if !reasoningOptions.contains(currentReasoning) {
            roleReasoningEffort[role] = AttachePresentationModelService.preferredReasoningEffort(
                provider: provider,
                modelID: roleModelID[role] ?? provider.defaultModel,
                supported: reasoningOptions
            )
        }
        defaults.set(roleReasoningEffort[role], forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .reasoningEffort))

        let serviceOptions = roleServiceTierOptions(for: role).map(\.id)
        let currentService = (roleServiceTier[role] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if serviceOptions.isEmpty {
            roleServiceTier[role] = "default"
        } else if currentService.isEmpty || !serviceOptions.contains(currentService) {
            roleServiceTier[role] = "default"
        }
        defaults.set(roleServiceTier[role], forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .serviceTier))
    }

    /// Sets, or clears when `provider` is nil ("Use main model"), the role's
    /// provider override. Clearing removes every per-role key for that role
    /// so `AttachePresentationSettings.load(role:)` falls all the way back
    /// to the global `presentationLLM*` keys instead of leaving a stale but
    /// coincidentally-matching per-role value behind.
    func selectRoleProvider(_ provider: AttachePresentationProvider?, for role: ModelRole) {
        guard let provider else {
            roleModelProvider.removeValue(forKey: role)
            roleModelID.removeValue(forKey: role)
            roleReasoningEffort.removeValue(forKey: role)
            roleServiceTier.removeValue(forKey: role)
            roleModelOptions.removeValue(forKey: role)
            roleModelDiscoveryStatus.removeValue(forKey: role)
            defaults.removeObject(forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .provider))
            defaults.removeObject(forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .model))
            defaults.removeObject(forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .reasoningEffort))
            defaults.removeObject(forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .serviceTier))
            return
        }
        roleModelProvider[role] = provider
        roleModelID[role] = provider.defaultModel
        roleModelOptions[role] = []
        roleModelDiscoveryStatus[role] = "Model discovery not checked"
        defaults.set(provider.rawValue, forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .provider))
        defaults.set(provider.defaultModel, forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .model))
        clampRoleCapabilities(for: role)
    }

    func selectRoleModel(_ option: AttachePresentationModelOption, for role: ModelRole) {
        guard roleModelProvider[role] != nil else { return }
        roleModelID[role] = option.id
        defaults.set(option.id, forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .model))
        clampRoleCapabilities(for: role)
    }

    func selectRoleModelID(_ id: String, for role: ModelRole) {
        guard roleModelProvider[role] != nil else { return }
        roleModelID[role] = id
        defaults.set(id, forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .model))
        clampRoleCapabilities(for: role)
    }

    func setRoleReasoningEffort(_ value: String, for role: ModelRole) {
        guard roleModelProvider[role] != nil else { return }
        roleReasoningEffort[role] = value
        defaults.set(value, forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .reasoningEffort))
    }

    func setRoleServiceTier(_ value: String, for role: ModelRole) {
        guard roleModelProvider[role] != nil else { return }
        roleServiceTier[role] = value
        defaults.set(value, forKey: AttachePreferenceKey.presentationLLMRoleKey(role, .serviceTier))
    }

    /// Model discovery for one role's override, scoped to that role's own
    /// provider. Unlike `loadPresentationModels` (which discovers for the
    /// single main-model row this pane also shows), this fetches for
    /// whichever provider a role currently points at. It reuses the exact
    /// same underlying network call (`AttachePresentationModelService.fetchModels`)
    /// and the same stored Integrations key per provider; no second discovery
    /// mechanism, just a per-role wrapper around the same service.
    func loadRoleModels(for role: ModelRole) {
        guard let provider = roleModelProvider[role] else { return }
        let baseURL = endpointForIntegration(provider)
        let apiKey = readConfiguredSecret(account: provider.developmentSecretAccount) ?? ""
        if provider.requiresAPIKey, apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            roleModelOptions[role] = []
            roleModelDiscoveryStatus[role] = "\(provider.title) needs an API key in Integrations to load models."
            return
        }
        roleModelDiscoveryStatus[role] = "Loading \(provider.title) models..."
        Task {
            do {
                let models = try await AttachePresentationModelService.fetchModels(
                    provider: provider,
                    baseURLText: baseURL,
                    apiKey: apiKey
                )
                await MainActor.run {
                    guard self.roleModelProvider[role] == provider else { return }
                    self.roleModelOptions[role] = models
                    if !models.contains(where: { $0.id == self.roleModelID[role] }), let first = models.first {
                        self.selectRoleModel(first, for: role)
                    } else {
                        self.clampRoleCapabilities(for: role)
                    }
                    self.roleModelDiscoveryStatus[role] = models.isEmpty
                        ? "\(provider.title) returned no models."
                        : "Loaded \(models.count) \(provider.title) models."
                }
            } catch {
                await MainActor.run {
                    guard self.roleModelProvider[role] == provider else { return }
                    self.roleModelOptions[role] = []
                    self.roleModelDiscoveryStatus[role] = "\(provider.title) model discovery failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Jumps Integrations to `provider`'s row, e.g. from the "needs a key"
    /// notice on a per-role Advanced row. Mirrors the
    /// `AttacheSpeechProvider` overload above.
    func focusIntegration(for provider: AttachePresentationProvider) {
        switch provider {
        case .xai: integrationFocusProviderID = "xai"
        case .ollama: integrationFocusProviderID = "ollama"
        case .groq: integrationFocusProviderID = "groq"
        case .custom: integrationFocusProviderID = "custom"
        case .claudeCLI, .codexCLI: integrationFocusProviderID = nil
        }
    }

    // MARK: Personalities

    var activePersonality: Personality? {
        personalities.first { $0.id == activePersonalityID }
    }

    func personalityVoiceName(_ personality: Personality) -> String {
        guard let voice = personality.voiceRef else { return "Voice not set" }
        switch voice.provider {
        case .system:
            if let id = voice.systemVoiceIdentifier,
               let option = speechVoiceOptions.first(where: { $0.id == id }) {
                return option.title
            }
            return "System default"
        case .elevenLabs:
            return voice.elevenLabsVoiceName ?? voice.elevenLabsVoiceID ?? "Voice not set"
        case .xai:
            return voice.xaiVoiceName ?? voice.xaiVoiceID ?? "Voice not set"
        case .openai:
            return voice.openaiVoiceName ?? voice.openaiVoiceID ?? "Voice not set"
        }
    }

    /// Snapshot helpers for the creator. They copy the current configured
    /// choices without changing the live app while someone experiments in the
    /// studio.
    var currentPersonalityVoiceRef: PersonalityVoiceRef {
        PersonalityVoiceRef.capture(from: defaults)
    }

    var currentPersonalityModelRef: PersonalityModelRef {
        PersonalityModelRef(
            provider: presentationProvider,
            model: presentationModel,
            reasoningEffort: presentationReasoningEffort,
            serviceTier: presentationServiceTier,
            fallbackProviders: conversationFallbackChainEnabled ? conversationFallbackChain : []
        )
    }

    func loadPersonalities() {
        let loaded = personalityStore.load()
        personalities = loaded.personalities
        activePersonalityID = loaded.activeID
        writeActivePersonalityToDefaults()
        // Voice and model selections already live in their established defaults
        // at launch (and cloud secrets may still be loading). Presence is cheap
        // and secret-free, so make the active character visually coherent now.
        if let active = activePersonality {
            if let visualMode = active.visualMode { self.visualMode = visualMode }
            character = active.character ?? .robot
            playbackSpeed = active.playbackSpeed ?? 1.0
            conversationFallbackChain = active.modelRef?.fallbackProviders ?? []
            conversationFallbackChainEnabled = !conversationFallbackChain.isEmpty
        }
    }

    func selectPersonality(_ id: String) {
        guard personalities.contains(where: { $0.id == id }) else { return }
        guard id != activePersonalityID else { return }
        cancelPendingReplyForPersonalitySwitch()
        activePersonalityID = id
        personalityStore.save(personalities, activeID: id)
        writeActivePersonalityToDefaults()
        refreshPresentationStatus()
        if let personality = activePersonality {
            let issue = applyPersonalityConfiguration(personality)
            intakeStatus = issue ?? "Personality set to \(personality.name)."
        }
    }

    /// A reply is owned by the personality snapshot that requested it. A
    /// switch invalidates that request and any not-yet-finished narration so
    /// an old brain can never speak through the new character or fallback
    /// chain. The call itself remains connected for the user's next turn.
    private func cancelPendingReplyForPersonalitySwitch() {
        conversationRequestTask?.cancel()
        conversationRequestTask = nil
        conversationCompiledInference = nil
        activeConversationRequestID = nil
        conversationRequestTimeoutTimer?.invalidate()
        conversationRequestTimeoutTimer = nil
        conversationFallbackRetryTimer?.invalidate()
        conversationFallbackRetryTimer = nil
        conversationFallbackAnnouncement = nil
        conversationTurnEffectLedger = nil
        conversationSessionToolRuntime = nil
        sessionContextRuntime.advanceRequestBoundary()
        isConversing = false
        endConversationWait()
        pendingAssistantReply = nil
        pendingAssistantInference = nil
        pendingAssistantReplyEgress = .allowedRemote
        expectingReplyAudio = false
        conversationRecovery = nil
        conversationRecoveryConfirmation = nil
        playback.stop()
        conversationFallbackState.reset()
    }

    /// The welcome flow asks for a voice before it asks for a character. Carry
    /// that deliberate choice, plus the current model, onto the character the
    /// user picks instead of letting a built-in default silently replace it.
    func selectOnboardingPersonality(_ id: String) {
        let chosenVoice = currentPersonalityVoiceRef
        let chosenModel = currentPersonalityModelRef
        let chosenSpeed = playbackSpeed
        guard let index = personalities.firstIndex(where: { $0.id == id }) else { return }
        personalities[index].voiceRef = chosenVoice
        personalities[index].modelRef = chosenModel
        personalities[index].playbackSpeed = chosenSpeed
        personalityStore.save(personalities, activeID: id)
        selectPersonality(id)
    }

    @discardableResult
    func createPersonality(name: String, prompt: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = Personality(
            id: "custom.\(UUID().uuidString)",
            name: trimmedName.isEmpty ? "My Personality" : trimmedName,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            voiceRef: currentPersonalityVoiceRef,
            character: character,
            visualMode: visualMode,
            modelRef: currentPersonalityModelRef,
            playbackSpeed: playbackSpeed
        )
        personalities.append(new)
        selectPersonality(new.id)
        return new.id
    }

    func selectAdjacentPersonality(offset: Int) {
        guard !personalities.isEmpty else { return }
        let currentIndex = personalities.firstIndex { $0.id == activePersonalityID } ?? 0
        let nextIndex = (currentIndex + offset + personalities.count) % personalities.count
        switchPersonalityFromUI(personalities[nextIndex].id)
    }

    /// True while a live voice conversation is in progress (its frozen target is
    /// captured). Used to decide whether a personality switch also clarifies the
    /// last turn (INF-301).
    var isLiveCallActive: Bool { conversationActive && activeConversationID != nil }

    /// The user-facing personality switch from the dock or the ⌘[ / ⌘] shortcut.
    /// Selection is always silent, including during a live call. Model inference
    /// and speech require the separate, explicit Another Take action (INF-336).
    func switchPersonalityFromUI(_ id: String) {
        selectPersonality(id)
    }

    /// Compatibility entry point retained for older internal callers. Clarify no
    /// longer infers from a recent card; callers must invoke `anotherTake` with an
    /// explicitly selected card and its frozen authorization.
    func clarifyWithPersonality(_ id: String) {
        selectPersonality(id)
    }

    func addPersonality() {
        let new = Personality(
            id: "custom.\(UUID().uuidString)",
            name: "New Personality",
            prompt: Personality.newTemplate,
            voiceRef: currentPersonalityVoiceRef,
            character: .robot,
            visualMode: .character,
            modelRef: currentPersonalityModelRef,
            playbackSpeed: playbackSpeed
        )
        personalities.append(new)
        selectPersonality(new.id)
    }

    /// Commit a creator draft in one operation. Built-ins are never overwritten:
    /// choosing Customize for one creates a new owned character. Existing custom
    /// personalities keep their stable id so old voicemail markers still resolve.
    @discardableResult
    func savePersonality(_ draft: Personality, replacingID: String?) -> String {
        var saved = draft
        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if saved.name.isEmpty { saved.name = "My Personality" }
        saved.prompt = saved.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if saved.prompt.isEmpty { saved.prompt = AttachePersonality.defaultProfilePrompt }
        if saved.voiceRef == nil { saved.voiceRef = currentPersonalityVoiceRef }
        if var voice = saved.voiceRef,
           voice.provider == .system,
           voice.systemVoiceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            voice.systemVoiceIdentifier = speechVoiceOptions.first?.id ?? Personality.defaultPreferredVoiceID
            saved.voiceRef = voice
        }
        if saved.modelRef == nil { saved.modelRef = currentPersonalityModelRef }
        if saved.playbackSpeed == nil { saved.playbackSpeed = playbackSpeed }
        saved.isBuiltIn = false

        if let replacingID,
           let index = personalities.firstIndex(where: { $0.id == replacingID }),
           !personalities[index].isBuiltIn {
            saved.id = replacingID
            personalities[index] = saved
        } else {
            saved.id = "custom.\(UUID().uuidString)"
            personalities.append(saved)
        }

        selectPersonality(saved.id)
        return saved.id
    }

    func duplicatePersonality(id: String) {
        guard let source = personalities.first(where: { $0.id == id }) else { return }
        let copy = source.duplicated(
            withID: "custom.\(UUID().uuidString)",
            name: "\(source.name) Copy"
        )
        if let index = personalities.firstIndex(where: { $0.id == id }) {
            personalities.insert(copy, at: index + 1)
        } else {
            personalities.append(copy)
        }
        selectPersonality(copy.id)
    }

    /// Model discovery for the creator without mutating the app's active model.
    /// It shares the same endpoints and credentials as Settings > Model.
    func personalityModelOptions(for provider: AttachePresentationProvider) async throws -> [AttachePresentationModelOption] {
        guard provider.supportsSafePersonalityInference else {
            throw CLILanguageModelError.unsafeToolIsolation(provider.title)
        }
        let baseURL = endpointForIntegration(provider)
        let apiKey = readConfiguredSecret(account: provider.developmentSecretAccount) ?? ""
        if provider.requiresAPIKey, apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AttachePresentationError.notConfigured
        }
        return try await AttachePresentationModelService.fetchModels(
            provider: provider,
            baseURLText: baseURL,
            apiKey: apiKey
        )
    }

    /// Explicit creator audition. The prompt asks for one tiny greeting, then the
    /// draft's own voice configuration speaks it without saving or changing the
    /// live character. If no model is available, the visible fallback still lets
    /// the user audition the voice.
    func previewPersonality(_ personality: Personality, completion: @escaping (String) -> Void = { _ in }) {
        let requestID = UUID()
        personalityPreviewRequestID = requestID
        let fallback = "Hi, I'm \(personality.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Attaché" : personality.name). Ready when you are."
        let system = """
        \(personality.prompt)

        This is a character-creator audition. Say one casual first-person hello in
        this personality, between five and twelve words. Output only the greeting.
        Do not use stage directions, quotation marks, or em dashes.
        """
        let settings = personalityPreviewSettings(for: personality)
        guard let settings else {
            personalityPreviewRequestID = nil
            let voice = speechConfiguration(for: personality.voiceRef)
            voiceProviderStatus = "Previewing \(personality.name) with its configured voice."
            playback.preview(fallback, configuration: voice)
            completion(fallback)
            return
        }
        let snapshot = captureRequestSnapshot(
            role: .preview,
            userInput: "Give me the quick hello now.",
            personalityOverride: personality,
            settingsOverride: settings
        )
        let voice = speechConfiguration(for: personality.voiceRef)
        voiceProviderStatus = "Preparing personality preview."

        Task {
            let generated: String
            do {
                let result = try await presentationService.complete(
                    snapshot: snapshot,
                    system: system,
                    user: "Give me the quick hello now.",
                    settingsOverride: settings
                )
                generated = Self.shortPersonalityGreeting(result.text, fallback: fallback)
                await MainActor.run {
                    AttacheContextUIState.shared.publishReceipt(result.inference.receiptView)
                }
            } catch {
                generated = fallback
            }
            await MainActor.run {
                guard self.personalityPreviewRequestID == requestID else { return }
                self.personalityPreviewRequestID = nil
                self.voiceProviderStatus = "Previewing \(personality.name)."
                self.playback.preview(generated, configuration: voice)
                completion(generated)
            }
        }
    }

    func cancelPersonalityPreview() {
        personalityPreviewRequestID = nil
    }

    private func personalityPreviewSettings(for personality: Personality) -> AttachePresentationSettings? {
        guard let ref = personality.modelRef,
              connectedTextProviders.contains(ref.provider),
              !presentationProviderSendsToCloud(ref.provider) || cloudConsentAcknowledged(for: ref.provider) else {
            return nil
        }
        var settings = AttachePresentationSettings.forFallback(
            provider: ref.provider,
            baseURLText: endpointForIntegration(ref.provider),
            apiKey: readConfiguredSecret(account: ref.provider.developmentSecretAccount) ?? "",
            profilePrompt: personality.prompt
        )
        let model = ref.model.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.model = model.isEmpty ? ref.provider.defaultModel : model
        settings.reasoningEffort = ref.reasoningEffort ?? settings.reasoningEffort
        settings.serviceTier = ref.serviceTier ?? settings.serviceTier
        return settings
    }

    private func speechConfiguration(for ref: PersonalityVoiceRef?) -> AttacheSpeechConfiguration {
        guard let ref = ref?.resolved(availableSystemVoiceIDs: installedSystemVoiceIDs()) else {
            return selectedSpeechConfiguration.resolvedForPlayback(systemVoiceIdentifier: speechVoiceIdentifier)
        }
        var configuration = selectedSpeechConfiguration
        configuration.provider = ref.provider
        configuration.systemVoiceIdentifier = ref.systemVoiceIdentifier
        if let value = ref.elevenLabsVoiceID { configuration.elevenLabsVoiceID = value }
        if let value = ref.elevenLabsModelID { configuration.elevenLabsModelID = value }
        if let value = ref.elevenLabsOutputFormat { configuration.elevenLabsOutputFormat = value }
        if let value = ref.xaiVoiceID { configuration.xaiVoiceID = value }
        if let value = ref.xaiBaseURL { configuration.xaiBaseURL = value }
        if let value = ref.xaiLanguage { configuration.xaiLanguage = value }
        if let value = ref.openaiVoiceID { configuration.openaiVoiceID = value }
        configuration.remoteEgressConsentScope = ref.provider.sendsToCloud
            && cloudVoiceConsentAcknowledged(for: ref.provider, xaiBaseURL: configuration.xaiBaseURL)
            ? voiceConsentScope(for: ref.provider, xaiBaseURL: configuration.xaiBaseURL).storageKey
            : nil
        return configuration.resolvedForPlayback(systemVoiceIdentifier: speechVoiceIdentifier)
    }

    private static func shortPersonalityGreeting(_ text: String?, fallback: String) -> String {
        let cleaned = AttachePersonality.stripDashes(text ?? "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
        guard !cleaned.isEmpty else { return fallback }
        let words = cleaned.split(whereSeparator: \.isWhitespace)
        guard words.count > 12 else { return cleaned }
        return words.prefix(12).joined(separator: " ") + "."
    }

    /// Apply the character as one unit. Persistence migration has already filled
    /// legacy voice/model gaps, so every normal personality switch is explicit.
    private func applyPersonalityConfiguration(_ personality: Personality) -> String? {
        if let visualMode = personality.visualMode {
            self.visualMode = visualMode
        }
        character = personality.character ?? .robot
        playbackSpeed = personality.playbackSpeed ?? 1.0

        let voiceIssue = applyPersonalityVoice(personality)
        let modelIssue = applyPersonalityModel(personality.modelRef)
        return voiceIssue ?? modelIssue
    }

    private func applyPersonalityVoice(_ personality: Personality) -> String? {
        guard let ref = personality.voiceRef?.resolved(availableSystemVoiceIDs: installedSystemVoiceIDs()) else {
            return nil
        }
        let requestedXAIBaseURL = ref.xaiBaseURL ?? xaiBaseURL
        if ref.provider.sendsToCloud,
           !cloudVoiceConsentAcknowledged(for: ref.provider, xaiBaseURL: requestedXAIBaseURL) {
            speechProvider = .system
            return "\(ref.provider.title) needs cloud voice approval, so this personality is using the on-device voice for now."
        }
        switch ref.provider {
        case .system:
            speechProvider = .system
            speechVoiceIdentifier = ref.systemVoiceIdentifier
        case .elevenLabs:
            guard hasSpeechAPIKey(for: .elevenLabs) else { return fallBackToSystemVoice(missing: "ElevenLabs") }
            if let value = ref.elevenLabsVoiceID { elevenLabsVoiceID = value }
            if let value = ref.elevenLabsVoiceName { elevenLabsVoiceName = value }
            if let value = ref.elevenLabsModelID { elevenLabsModelID = value }
            if let value = ref.elevenLabsOutputFormat { elevenLabsOutputFormat = value }
            speechProvider = .elevenLabs
        case .xai:
            guard hasSpeechAPIKey(for: .xai) else { return fallBackToSystemVoice(missing: "xAI") }
            if let value = ref.xaiVoiceID { xaiVoiceID = value }
            if let value = ref.xaiVoiceName { xaiVoiceName = value }
            xaiBaseURL = requestedXAIBaseURL
            if let value = ref.xaiLanguage { xaiLanguage = value }
            speechProvider = .xai
        case .openai:
            guard hasSpeechAPIKey(for: .openai) else { return fallBackToSystemVoice(missing: "OpenAI") }
            if let value = ref.openaiVoiceID { openaiVoiceID = value }
            if let value = ref.openaiVoiceName { openaiVoiceName = value }
            speechProvider = .openai
        }
        return nil
    }

    /// A personality applies its preferred model and ordered recovery providers
    /// together. Advanced per-task overrides remain authoritative for their role.
    private func applyPersonalityModel(_ ref: PersonalityModelRef?) -> String? {
        guard let ref else { return nil }
        conversationFallbackChain = ref.fallbackProviders.filter { $0 != ref.provider }
        conversationFallbackChainEnabled = !conversationFallbackChain.isEmpty
        guard connectedTextProviders.contains(ref.provider) else {
            return "\(ref.provider.title) is not configured, so \(activePersonality?.name ?? "this personality") is using the current app model."
        }
        if presentationProviderSendsToCloud(ref.provider),
           !cloudConsentAcknowledged(for: ref.provider) {
            return "\(ref.provider.title) needs cloud approval, so \(activePersonality?.name ?? "this personality") is using the current app model."
        }

        selectPresentationProvider(ref.provider)
        let model = ref.model.trimmingCharacters(in: .whitespacesAndNewlines)
        presentationModel = model.isEmpty ? ref.provider.defaultModel : model
        if let reasoning = ref.reasoningEffort, !reasoning.isEmpty {
            presentationReasoningEffort = reasoning
        }
        if let tier = ref.serviceTier, !tier.isEmpty {
            presentationServiceTier = tier
        }
        applyCurrentPresentationModelCapabilities()
        refreshPresentationStatus()
        return nil
    }

    private func installedSystemVoiceIDs() -> Set<String> {
        Set(speechVoiceOptions.map { $0.id })
    }

    private func hasSpeechAPIKey(for provider: AttacheSpeechProvider) -> Bool {
        switch provider {
        case .system: return true
        case .elevenLabs: return !elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .xai: return !xaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .openai: return !openaiVoiceAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func fallBackToSystemVoice(missing provider: String) -> String {
        speechProvider = .system
        return "\(provider) needs an API key, so this personality is using the on-device voice for now."
    }

    /// Change the character as a user action, keeping it in sync with the active
    /// personality. Programmatic switches set `character` directly instead.
    func selectCharacter(_ character: AttacheCharacter) {
        self.character = character
        captureCharacterIntoActivePersonality()
    }

    /// Fold the current voice selection onto the active personality, so a voice
    /// edit belongs to the personality rather than an orphan global (INF-296).
    func captureCurrentVoiceIntoActivePersonality() {
        guard let index = personalities.firstIndex(where: { $0.id == activePersonalityID }) else { return }
        personalities[index].voiceRef = PersonalityVoiceRef.capture(from: defaults)
        personalityStore.save(personalities, activeID: activePersonalityID)
    }

    /// Fold the current main model and fallback order onto the active personality.
    /// Per-task Advanced overrides remain app-wide policy.
    func captureCurrentModelIntoActivePersonality() {
        guard let index = personalities.firstIndex(where: { $0.id == activePersonalityID }) else { return }
        personalities[index].modelRef = currentPersonalityModelRef
        personalityStore.save(personalities, activeID: activePersonalityID)
    }

    /// Fold the current character onto the active personality (INF-296).
    func captureCharacterIntoActivePersonality() {
        guard let index = personalities.firstIndex(where: { $0.id == activePersonalityID }) else { return }
        personalities[index].character = character
        personalityStore.save(personalities, activeID: activePersonalityID)
    }

    /// Export a personality as JSON for sharing or backup (INF-295), mirroring
    /// the custom-themes interchange.
    func exportPersonalityData(id: String) -> Data? {
        guard let personality = personalities.first(where: { $0.id == id }) else { return nil }
        return try? PersonalityStore.exportData(personality)
    }

    /// Import a personality from JSON, giving it a fresh identity so it never
    /// clobbers an existing one, then make it active (INF-295).
    func importPersonality(from data: Data) {
        guard var imported = try? PersonalityStore.importPersonality(from: data) else {
            intakeStatus = "Could not import that personality file."
            return
        }
        if imported.voiceRef == nil { imported.voiceRef = currentPersonalityVoiceRef }
        if var voice = imported.voiceRef,
           voice.provider == .system,
           voice.systemVoiceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            voice.systemVoiceIdentifier = speechVoiceOptions.first?.id ?? Personality.defaultPreferredVoiceID
            imported.voiceRef = voice
        }
        if imported.modelRef == nil { imported.modelRef = currentPersonalityModelRef }
        if imported.playbackSpeed == nil { imported.playbackSpeed = playbackSpeed }
        personalities.append(imported)
        selectPersonality(imported.id)
        intakeStatus = "Imported \"\(imported.name)\"."
    }

    func updatePersonality(id: String, name: String, prompt: String) {
        guard let index = personalities.firstIndex(where: { $0.id == id }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            personalities[index].name = trimmedName
        }
        personalities[index].prompt = prompt
        personalityStore.save(personalities, activeID: activePersonalityID)
        if id == activePersonalityID {
            writeActivePersonalityToDefaults()
            refreshPresentationStatus()
        }
        intakeStatus = "Personality \"\(personalities[index].name)\" saved."
    }

    func deletePersonality(id: String) {
        guard let index = personalities.firstIndex(where: { $0.id == id }), !personalities[index].isBuiltIn else { return }
        let wasActive = id == activePersonalityID
        personalities.remove(at: index)
        if wasActive {
            selectPersonality(personalities.first?.id ?? Personality.defaultActiveID)
        } else {
            personalityStore.save(personalities, activeID: activePersonalityID)
        }
    }

    func personalityMarker(for card: VoicemailCard) -> CardPersonalityMarker? {
        let metadata = metadataDictionary(for: card)
        let id = metadata["companion_personality_id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedName = metadata["companion_personality_name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty || !storedName.isEmpty else { return nil }

        if !id.isEmpty, let current = personalities.first(where: { $0.id == id }) {
            return CardPersonalityMarker(
                id: id,
                name: storedName.isEmpty ? current.name : storedName,
                isUnavailable: false
            )
        }

        return CardPersonalityMarker(
            id: id,
            name: storedName.isEmpty ? "Previous personality" : storedName,
            isUnavailable: true
        )
    }

    func metadataDictionary(for card: VoicemailCard) -> [String: String] {
        guard let data = card.metadataJSON.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in raw {
            if let string = value as? String {
                result[key] = string
            } else {
                result[key] = String(describing: value)
            }
        }
        return result
    }

    private func writeActivePersonalityToDefaults() {
        let prompt = activePersonality?.prompt ?? AttachePersonality.defaultProfilePrompt
        defaults.set(prompt, forKey: AttachePreferenceKey.personalityPrompt)
    }

    private func applyCapabilitiesForSelectedModel(_ option: AttachePresentationModelOption) {
        if option.reasoningEfforts.isEmpty {
            presentationReasoningEffort = "none"
        } else {
            let options = option.reasoningEfforts
            let current = presentationReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
            if !options.contains(current) {
                presentationReasoningEffort = AttachePresentationModelService.preferredReasoningEffort(
                    provider: presentationProvider,
                    modelID: option.id,
                    supported: options
                )
            }
        }

        let serviceOptions = selectedPresentationServiceTierOptions.map(\.id)
        if serviceOptions.isEmpty {
            presentationServiceTier = "default"
        } else {
            let current = presentationServiceTier.trimmingCharacters(in: .whitespacesAndNewlines)
            if current.isEmpty || !serviceOptions.contains(current) {
                presentationServiceTier = "default"
            }
        }
    }

    private func applyCurrentPresentationModelCapabilities() {
        if let option = presentationModelOptions.first(where: { $0.id == presentationModel }) {
            applyCapabilitiesForSelectedModel(option)
        } else {
            applyFallbackCapabilitiesForCurrentModel()
        }
    }

    private func applyFallbackCapabilitiesForCurrentModel() {
        let reasoningOptions = selectedPresentationReasoningOptions
        if reasoningOptions.isEmpty {
            presentationReasoningEffort = "none"
        } else {
            let current = presentationReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reasoningOptions.contains(current) {
                presentationReasoningEffort = AttachePresentationModelService.preferredReasoningEffort(
                    provider: presentationProvider,
                    modelID: presentationModel,
                    supported: reasoningOptions
                )
            }
        }

        let serviceOptions = selectedPresentationServiceTierOptions.map(\.id)
        if serviceOptions.isEmpty {
            presentationServiceTier = "default"
        } else {
            let current = presentationServiceTier.trimmingCharacters(in: .whitespacesAndNewlines)
            if current.isEmpty || !serviceOptions.contains(current) {
                presentationServiceTier = "default"
            }
        }
    }

    func selectSpeechVoice(_ option: AttacheVoiceOption?) {
        speechProvider = .system
        speechVoiceIdentifier = option?.id
        intakeStatus = option.map { "Assistant voice set to \($0.title)." } ?? "Assistant voice set to system default."
        captureCurrentVoiceIntoActivePersonality()
    }

    func selectElevenLabsVoice(_ voice: RemoteVoiceOption) {
        speechProvider = .elevenLabs
        elevenLabsVoiceID = voice.id
        elevenLabsVoiceName = voice.name
        intakeStatus = "ElevenLabs voice set to \(voice.name)."
        captureCurrentVoiceIntoActivePersonality()
    }

    func selectXAIVoice(_ voice: RemoteVoiceOption) {
        speechProvider = .xai
        xaiVoiceID = voice.id
        xaiVoiceName = voice.name
        intakeStatus = "xAI voice set to \(voice.name)."
        captureCurrentVoiceIntoActivePersonality()
    }

    func selectOpenAIVoice(_ voice: RemoteVoiceOption) {
        speechProvider = .openai
        openaiVoiceID = voice.id
        openaiVoiceName = voice.name
        intakeStatus = "OpenAI voice set to \(voice.name)."
        captureCurrentVoiceIntoActivePersonality()
    }

    func saveOpenAIVoiceIntegration() {
        let trimmed = openaiVoiceAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try AttacheSecretVault.save(trimmed, account: Self.openaiDevelopmentSecretAccount)
            setSecretAccountConfigured(Self.openaiDevelopmentSecretAccount, configured: !trimmed.isEmpty)
            openaiVoiceAPIKey = trimmed
            if trimmed.isEmpty {
                openaiVoiceOptions = []
                openaiVoiceID = ""
                openaiVoiceName = ""
                voiceProviderStatus = "OpenAI key cleared."
            } else {
                loadOpenAIVoices()
            }
        } catch {
            voiceProviderStatus = "OpenAI key save failed: \(error.localizedDescription)"
        }
    }

    func previewAssistantVoice() {
        applySpeechConfiguration()
        voiceProviderStatus = "Previewing \(currentVoiceSummary)."
        playback.preview("Attaché is ready now.")
    }

    func saveElevenLabsKeyAndLoadVoices() {
        let trimmed = elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try AttacheSecretVault.save(trimmed, account: Self.elevenLabsDevelopmentSecretAccount)
            setSecretAccountConfigured(Self.elevenLabsDevelopmentSecretAccount, configured: !trimmed.isEmpty)
            elevenLabsAPIKey = trimmed
            loadElevenLabsVoices()
        } catch {
            voiceProviderStatus = "ElevenLabs development key save failed: \(error.localizedDescription)"
        }
    }

    func saveXAIKeyAndLoadVoices() {
        let trimmed = xaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try AttacheSecretVault.save(trimmed, account: Self.xaiDevelopmentSecretAccount)
            setSecretAccountConfigured(Self.xaiDevelopmentSecretAccount, configured: !trimmed.isEmpty)
            xaiAPIKey = trimmed
            loadXAIVoices()
        } catch {
            voiceProviderStatus = "xAI development key save failed: \(error.localizedDescription)"
        }
    }

    func loadElevenLabsVoices() {
        let key = elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            voiceProviderStatus = "Enter an ElevenLabs API key to load voices."
            return
        }
        voiceProviderStatus = "Loading ElevenLabs voices..."
        Task {
            do {
                let voices = try await AttacheRemoteVoiceService.fetchElevenLabsVoices(apiKey: key)
                await MainActor.run {
                    self.elevenLabsVoiceOptions = voices
                    self.voiceProviderStatus = "Loaded \(voices.count) ElevenLabs voices."
                    if self.elevenLabsVoiceID.isEmpty, let first = voices.first {
                        self.elevenLabsVoiceID = first.id
                        self.elevenLabsVoiceName = first.name
                    }
                }
            } catch {
                await MainActor.run {
                    self.voiceProviderStatus = "ElevenLabs voice load failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func loadXAIVoices() {
        let key = xaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            xaiVoiceOptions = []
            xaiVoiceID = ""
            xaiVoiceName = ""
            voiceProviderStatus = "Enter an xAI API key to load voices."
            return
        }
        let requestedBaseURL = xaiBaseURL
        guard cloudVoiceConsentAcknowledged(for: .xai, xaiBaseURL: requestedBaseURL) else {
            xaiVoiceOptions = []
            voiceProviderStatus = "Approve the xAI voice destination before loading voices."
            return
        }
        let consentScope = voiceConsentScope(for: .xai, xaiBaseURL: requestedBaseURL).storageKey
        voiceProviderStatus = "Loading xAI voices..."
        Task {
            do {
                let voices = try await AttacheRemoteVoiceService.fetchXAIVoices(
                    apiKey: key,
                    baseURL: requestedBaseURL,
                    remoteEgressConsentScope: consentScope
                )
                await MainActor.run {
                    self.xaiVoiceOptions = voices
                    self.voiceProviderStatus = "Loaded \(self.xaiVoiceOptions.count) xAI voices."
                    if self.xaiVoiceID.isEmpty, let first = voices.first {
                        self.xaiVoiceID = first.id
                        self.xaiVoiceName = first.name
                    }
                }
            } catch {
                await MainActor.run {
                    self.xaiVoiceOptions = []
                    self.voiceProviderStatus = "xAI voice load failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func loadOpenAIVoices() {
        let key = effectiveOpenAIVoiceKey
        guard !key.isEmpty else {
            openaiVoiceOptions = []
            openaiVoiceID = ""
            openaiVoiceName = ""
            voiceProviderStatus = "Enter an OpenAI API key to load voices."
            return
        }
        voiceProviderStatus = "Checking OpenAI key..."
        Task {
            do {
                try await AttacheRemoteVoiceService.verifyOpenAIKey(apiKey: key)
                await MainActor.run {
                    self.openaiVoiceOptions = AttacheRemoteVoiceService.builtInOpenAIVoices
                    self.voiceProviderStatus = "Loaded \(self.openaiVoiceOptions.count) OpenAI voices."
                    if self.openaiVoiceID.isEmpty, let first = self.openaiVoiceOptions.first {
                        self.openaiVoiceID = first.id
                        self.openaiVoiceName = first.name
                    }
                }
            } catch {
                await MainActor.run {
                    self.openaiVoiceOptions = []
                    self.voiceProviderStatus = "OpenAI voice load failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func cleanExpiredAudioCache() {
        playback.cleanExpiredAudioCache(force: true)
        voiceProviderStatus = audioCacheRetentionMinutes == 0
            ? "Replay audio cache is disabled and cached files were removed."
            : "Expired replay audio cache files were removed."
    }

    func refreshCodexSessions(updateStatus: Bool = true) {
        guard !store.isInMemory else { return }
        guard codexSourceEnabled else {
            codexSessions = []
            archivedCodexSessions = []
            codexAutomations = []
            updateCodexWatcher()
            if updateStatus {
                intakeStatus = "Codex is not connected. Enable it in Settings."
            }
            return
        }

        // The catalog reads session_index.jsonl and walks the sessions trees, which
        // blocked the main thread every refresh. Do it on a utility queue and hop
        // the snapshot back to update published state (INF-164). Skip if a refresh
        // is already in flight (the shared date parsers aren't concurrency-safe).
        guard !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        let catalog = codexSessionCatalog
        Task.detached(priority: .utility) {
            let snapshot = catalog.loadSnapshot()
            await MainActor.run { [weak self] in
                self?.isRefreshingCatalog = false
                self?.applyCatalogSnapshot(snapshot, updateStatus: updateStatus)
            }
        }
    }

    private func applyCatalogSnapshot(_ snapshot: CodexSessionCatalogSnapshot, updateStatus: Bool) {
        guard codexSourceEnabled else { return }
        codexSessions = Self.uniqueCodexTargets(snapshot.activeSessions)
        archivedCodexSessions = Self.uniqueCodexTargets(snapshot.archivedSessions)
        codexAutomations = Self.uniqueCodexTargets(snapshot.automations)
        if isIndexingSessions, sessionRecords.isEmpty {
            let quickRecords = (codexSessions + archivedCodexSessions).compactMap {
                Self.quickSessionRecord(from: $0)
            }
            if !quickRecords.isEmpty {
                sessionContextRuntime.publishCatalog(records: quickRecords)
                sessionRecords = quickRecords
                sessionIndexRevision += 1
            }
        }
        let migratedAutomationAttachment = migrateAutomationAttachmentIfNeeded(in: snapshot, updateStatus: updateStatus)
        if attachedCodexSession?.category == .archivedSession {
            attachedCodexSessionID = nil
            synchronizeSessionContextFocus()
        }
        updateCodexWatcher()
        if updateStatus, !migratedAutomationAttachment {
            intakeStatus = codexSessions.isEmpty
                ? "No active Codex sessions found."
                : "Loaded \(codexSessions.count) active Codex sessions."
        }
    }

    private static func quickSessionRecord(from target: CodexSessionTarget) -> SessionRecord? {
        guard let filePath = target.filePath, !filePath.isEmpty else { return nil }
        let modified = ((try? FileManager.default.attributesOfItem(atPath: filePath))?[.modificationDate] as? Date)
            ?? target.updatedAt
        return SessionRecord(
            id: target.id,
            title: target.displayTitle,
            project: nil,
            threadName: target.title,
            updatedAt: target.updatedAt,
            archived: target.category == .archivedSession,
            filePath: filePath,
            fileMtime: modified.timeIntervalSince1970,
            content: "",
            topicTag: nil,
            sourceKind: target.sourceKind
        )
    }

    private func startCodexSessionRefreshTimer() {
        guard !store.isInMemory else { return }
        codexSessionRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: Self.codexSessionRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshCodexSessions(updateStatus: false)
            // Deliver any confirmed instruction whose session has gone quiet.
            // Run on the main actor so the shared store is never touched
            // off-main. Event-driven pumps (INF-255/B4, `scheduleEventDrivenPump`
            // via the watcher's `onEvent`) now cover the common case sooner; this
            // timer stays as a backstop for a session that goes quiet with no
            // further watcher event to trigger that path.
            if let twoWay = self?.twoWay {
                Task { @MainActor in
                    let changed = await twoWay.pump()
                    self?.handleTwoWayDeliveryChanges(changed)
                }
            }
        }
        codexSessionRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func attachCodexSession(_ session: CodexSessionTarget?) {
        let previousSessionID = attachedCodexSessionID
        if let session {
            watchSession(session, focus: true)
        } else {
            if let previousSessionID { attachedTargets.removeValue(forKey: previousSessionID) }
            attachedCodexSessionID = attachedSessionList.first?.id   // refocus another, if any
            synchronizeSessionContextFocus()
        }
        if previousSessionID != attachedCodexSessionID {
            liveFollowUpText = ""
        }
        resetLiveFollowUpAnswerStatus()
        if let session {
            intakeStatus = "Watching and focused on \(session.displayTitle)."
            liveFollowUpStatus = "Ready to ask Attaché about \(session.displayTitle)."
        } else {
            updateCodexWatcher()
            intakeStatus = "Stopped watching session."
            if let session = talkContextSession {
                liveFollowUpStatus = "Ready to ask Attaché about \(session.displayTitle)."
            } else {
                liveFollowUpStatus = "No watched session to talk about yet."
            }
        }
    }

    // MARK: - Session search

    /// Keep the app's one FTS/search authority aligned with the scanner's
    /// current source-of-truth records. A vanished focused log revokes its
    /// authorization and removes that stale watch target before any future
    /// request can reconstruct it from display metadata.
    private func applySessionContextReconciliation(
        _ reconciliation: SessionContextRuntime.Reconciliation
    ) {
        if let invalidated = reconciliation.invalidatedFocusedSessionID {
            attachedTargets.removeValue(forKey: invalidated)
            if attachedCodexSessionID == invalidated {
                let validIDs = Set(sessionRecords.map(\.id))
                attachedCodexSessionID = attachedSessionList.first(where: { validIDs.contains($0.id) })?.id
            }
        }
        synchronizeSessionContextFocus()
    }

    /// Rebuild focus authorization only from a real indexed record. Catalog
    /// rows and persisted labels alone are never enough to authorize evidence.
    private func synchronizeSessionContextFocus() {
        guard sessionContextRuntime != nil else { return }
        guard let target = attachedCodexSession,
              let record = sessionRecords.first(where: {
                  $0.id == target.id && $0.sourceKind == target.sourceKind
              }),
              FileManager.default.fileExists(atPath: record.filePath) else {
            sessionContextRuntime.clearFocus()
            return
        }
        _ = sessionContextRuntime.grantAppOwnedFocus(
            sessionID: record.id,
            sourceKind: record.sourceKind.rawValue,
            displayTitle: displaySessionTitle(record),
            workingDirectory: record.project
        )
    }

    func refreshSessionIndex() {
        guard !store.isInMemory else {
            sessionRecords = []
            isIndexingSessions = false
            return
        }
        guard !isIndexingSessions else { return }
        isIndexingSessions = true
        let enabledSources = enabledAgentSources
        sessionIndexQueue.async { [weak self] in
            guard let self else { return }
            let records = enabledSources.isEmpty ? [] : self.sessionIndexer.refresh()
            let filteredRecords = records.filter { enabledSources.contains($0.sourceKind) }
            let reconciliation = self.sessionContextRuntime.reconcile(records: filteredRecords)
            DispatchQueue.main.async {
                self.sessionRecords = filteredRecords
                self.applySessionContextReconciliation(reconciliation)
                self.sessionIndexRevision += 1
                self.isIndexingSessions = false
                self.tagUntaggedSessions()
                self.syncWatchedTitles()
            }
        }
    }

    /// Local topic tagging for indexed sessions. Background index maintenance
    /// never has authority to send transcript-derived snippets, titles, or
    /// working directories to a model, so labels are derived deterministically
    /// from app-owned title/project metadata and persisted in the local cache.
    func tagUntaggedSessions(maxPerRun: Int = 480, batchSize: Int = 12) {
        guard ProcessInfo.processInfo.environment["ATTACHE_DISABLE_TOPIC_TAGGING"] != "1" else { return }
        guard !isTaggingSessions else { return }
        let pending = Array(sessionIndexer.untaggedRecords()
            .filter { enabledAgentSources.contains($0.sourceKind) }
            .prefix(maxPerRun))
        guard !pending.isEmpty else { return }
        isTaggingSessions = true
        defer { isTaggingSessions = false }
        _ = batchSize // retained for source compatibility with existing callers
        var vocabulary = Set(sessionRecords.compactMap { $0.topicTag }.filter { !$0.isEmpty })
        var tags: [String: String] = [:]
        for record in pending {
            let tag = SessionTagger.localTag(
                for: SessionTagger.Item(
                    id: record.id,
                    title: record.title,
                    snippet: "",
                    project: curatedProjectName(forCWD: record.project)
                ),
                knownTags: Array(vocabulary)
            )
            tags[record.id] = tag
            vocabulary.insert(tag)
        }
        let updated = sessionIndexer.applyTags(tags)
        sessionRecords = filteredEnabledRecords(updated)
        sessionIndexRevision += 1
        refreshSessionIndex()
    }

    var localAgentSourcesEnabled: Bool {
        codexSourceEnabled || claudeCodeSourceEnabled
    }

    func setCodexSourceEnabled(_ enabled: Bool) {
        guard codexSourceEnabled != enabled else { return }
        codexSourceEnabled = enabled
        defaults.set(enabled, forKey: AttachePreferenceKey.codexSourceEnabled)

        if !enabled {
            codexSessions = []
            archivedCodexSessions = []
            codexAutomations = []
            attachedTargets = attachedTargets.filter { $0.value.sourceKind != .codex }
            if attachedCodexSession?.sourceKind == .codex {
                attachedCodexSessionID = attachedSessionList.first?.id
            }
            synchronizeSessionContextFocus()
            updateCodexWatcher()
        }

        rebuildSessionIndexer()
        refreshCodexSessions(updateStatus: false)
        refreshSessionIndex()
    }

    func setClaudeCodeSourceEnabled(_ enabled: Bool) {
        guard claudeCodeSourceEnabled != enabled else { return }
        claudeCodeSourceEnabled = enabled
        defaults.set(enabled, forKey: AttachePreferenceKey.claudeCodeSourceEnabled)
        if !enabled {
            // Mirror the Codex disable path: stop watching Claude sessions now
            // instead of only rebuilding the index (they'd keep producing
            // voicemail until restart otherwise) (INF-168).
            attachedTargets = attachedTargets.filter { $0.value.sourceKind != .claudeCode }
            if attachedCodexSession?.sourceKind == .claudeCode {
                attachedCodexSessionID = attachedSessionList.first?.id
            }
            synchronizeSessionContextFocus()
            updateCodexWatcher()
        }
        rebuildSessionIndexer()
        refreshSessionIndex()
    }

    func focusIntegration(for provider: AttacheSpeechProvider) {
        switch provider {
        case .system:
            integrationFocusProviderID = nil
        case .elevenLabs:
            integrationFocusProviderID = "elevenlabs"
        case .xai:
            integrationFocusProviderID = "xai"
        case .openai:
            integrationFocusProviderID = "openai"
        }
    }

    private var enabledAgentSources: Set<SourceKind> {
        var sources = Set<SourceKind>()
        if codexSourceEnabled { sources.insert(.codex) }
        if claudeCodeSourceEnabled { sources.insert(.claudeCode) }
        return sources
    }

    private func rebuildSessionIndexer() {
        guard !store.isInMemory else { return }
        var scanners: [SessionScanner] = []
        if codexSourceEnabled { scanners.append(CodexSessionScanner()) }
        if claudeCodeSourceEnabled { scanners.append(ClaudeCodeSessionScanner()) }
        sessionIndexer = SessionIndexer(cacheURL: Self.sessionIndexURL, scanners: scanners)
    }

    private func filteredEnabledRecords(_ records: [SessionRecord]) -> [SessionRecord] {
        let sources = enabledAgentSources
        guard !sources.isEmpty else { return [] }
        return records.filter { sources.contains($0.sourceKind) }
    }

    func searchSessions(_ query: String, includeArchived: Bool) -> [SessionSearchHit] {
        sessionContextRuntime.commandKSearch(
            query,
            includeArchived: includeArchived
        )
    }

    /// Production model-assisted discovery uses the exact same ranking
    /// service as Command-K. `result` is safe to expose to a model; rows stay
    /// app-owned until the user makes a native selection.
    func beginModelAssistedSessionDiscovery(
        query: AttacheSessionDiscoveryQuery,
        triggeringUserTurn: String
    ) throws -> SessionContextRuntime.DiscoveryHandle {
        try sessionContextRuntime.beginDiscovery(AttacheSessionDiscoveryRequest(
            query: query,
            triggeringUserTurn: triggeringUserTurn
        ))
    }

    /// Execute the model's narrow, non-effectful discovery request. The return
    /// value is deliberately content-free; all actual rows remain in app-owned
    /// state and are shown in the same native picker as Command-K.
    @MainActor
    private func applySessionDiscoveryTool(
        arguments: String,
        sourceUtterance: String,
        effectLedger: ConversationTurnEffectLedger? = nil,
        authorization: ConversationRequestAuthorization? = nil
    ) -> String {
        if let authorization, !conversationRequestIsAuthorized(authorization) {
            return Self.sessionDiscoveryToolResult(
                matchCount: 0,
                requiresSelection: false,
                noMatches: true,
                guidance: "That conversation request ended, so the session search was canceled."
            )
        }
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawQuery = object["query"] as? String else {
            return Self.sessionDiscoveryToolResult(
                matchCount: 0,
                requiresSelection: false,
                noMatches: true,
                guidance: "The session search request was invalid. Ask the user for a short search phrase."
            )
        }
        if let effectLedger, !effectLedger.claim(.sessionDiscovery) {
            return Self.sessionDiscoveryToolResult(
                matchCount: 0,
                requiresSelection: false,
                noMatches: true,
                guidance: "This turn already requested one session search. Ask the user to refine the topic in a new turn."
            )
        }
        do {
            let handle = try beginModelAssistedSessionDiscovery(
                query: AttacheSessionDiscoveryQuery(text: rawQuery),
                triggeringUserTurn: sourceUtterance
            )
            if handle.result.requiresSelection {
                modelSessionDiscoveryPicker = ModelSessionDiscoveryPickerState(
                    token: handle.token,
                    query: rawQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                    orderedResults: handle.orderedResults
                )
                NotificationCenter.default.post(name: .attacheOpenPalette, object: nil)
            }
            return Self.sessionDiscoveryToolResult(handle.result)
        } catch {
            return Self.sessionDiscoveryToolResult(
                matchCount: 0,
                requiresSelection: false,
                noMatches: true,
                guidance: "The local search could not run. Ask the user to shorten or rephrase the search."
            )
        }
    }

    private static func sessionDiscoveryToolResult(_ result: AttacheSessionDiscoveryResult) -> String {
        sessionDiscoveryToolResult(
            matchCount: result.matchCount,
            requiresSelection: result.requiresSelection,
            noMatches: result.noMatches,
            guidance: result.guidance
        )
    }

    private static func sessionDiscoveryToolResult(
        matchCount: Int,
        requiresSelection: Bool,
        noMatches: Bool,
        guidance: String
    ) -> String {
        let object: [String: Any] = [
            "match_count": matchCount,
            "requires_native_selection": requiresSelection,
            "no_matches": noMatches,
            "guidance": guidance
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return #"{"match_count":0,"requires_native_selection":false,"no_matches":true}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Explicit exhaustive session review

    @MainActor
    private func bindExhaustiveReviewUI(to state: AttacheContextUIState) {
        state.onStartExhaustiveReview = { [weak self] review in
            self?.startExhaustiveReview(review)
        }
        state.onCancelExhaustiveReview = { [weak self] review in
            self?.cancelExhaustiveReview(review)
        }
        state.onResumeExhaustiveReview = { [weak self] review in
            self?.resumeExhaustiveReview(review)
        }
    }

    /// The model may request this preview, but it cannot start provider work.
    /// Freezing, mapping, and estimating happen locally; stage calls begin only
    /// from the native Start review button wired above.
    private func prepareExhaustiveReviewTool(
        snapshot: AttacheRequestSnapshot,
        authorization: ConversationRequestAuthorization
    ) async -> String {
        guard let focusedSession = snapshot.focusedSession,
              snapshot.modelSettings != nil else {
            return Self.exhaustiveReviewToolResult(
                result: "unavailable",
                estimatedCalls: 0,
                eligibleRanges: 0,
                guidance: "A focused session and configured frozen model are required."
            )
        }
        guard await MainActor.run(body: {
            self.conversationRequestIsAuthorized(authorization)
        }) else {
            return Self.exhaustiveReviewToolResult(
                result: "canceled",
                estimatedCalls: 0,
                eligibleRanges: 0,
                guidance: "The conversation request ended before the preview was prepared."
            )
        }

        let source: SessionContextRuntime.FrozenReviewSource
        do {
            source = try sessionContextRuntime.freezeReviewSource(
                focusedSession: focusedSession
            )
        } catch {
            return Self.exhaustiveReviewToolResult(
                result: "unavailable",
                estimatedCalls: 0,
                eligibleRanges: 0,
                guidance: "The focused session could not be frozen. Keep it focused and try again."
            )
        }

        let baseSnapshot = Self.exhaustiveReviewBaseSnapshot(
            from: snapshot,
            focusedSession: source.focusedSession
        )
        let prepared = Self.prepareExhaustiveReview(
            source: source,
            baseSnapshot: baseSnapshot,
            callID: authorization.callID
        )
        let installed = await MainActor.run { [prepared] in
            guard self.conversationRequestIsAuthorized(authorization),
                  self.sessionContextRuntime.reviewSourceIsCurrent(prepared.context.source) else {
                return false
            }
            self.installExhaustiveReviewPreview(
                prepared.context,
                state: prepared.uiState
            )
            return true
        }
        guard installed else {
            return Self.exhaustiveReviewToolResult(
                result: "canceled",
                estimatedCalls: 0,
                eligibleRanges: 0,
                guidance: "The call or focused source changed before the preview was ready."
            )
        }
        return Self.exhaustiveReviewToolResult(
            result: "preview_ready",
            estimatedCalls: prepared.uiState.estimatedCalls,
            eligibleRanges: prepared.uiState.eligibleRanges,
            guidance: "The local preview is open. No review stages have run. The user must press Start review."
        )
    }

    private static func exhaustiveReviewBaseSnapshot(
        from snapshot: AttacheRequestSnapshot,
        focusedSession: AttacheFocusedSession
    ) -> AttacheRequestSnapshot {
        AttacheRequestSnapshot(
            role: .recap,
            personality: snapshot.personality,
            profilePrompt: snapshot.profilePrompt,
            userInput: "Review the entire explicitly focused session.",
            session: .focused(focusedSession),
            modelSettings: snapshot.modelSettings,
            contextItems: [],
            contextStrategy: snapshot.contextStrategy
        )
    }

    private static func prepareExhaustiveReview(
        source: SessionContextRuntime.FrozenReviewSource,
        baseSnapshot: AttacheRequestSnapshot,
        callID: UUID
    ) -> (context: ActiveExhaustiveReviewContext, uiState: AttacheExhaustiveReviewUIState) {
        let settings = baseSnapshot.modelSettings
        let capability = settings.map {
            AttachePresentationModelService.capabilityProfile(
                provider: $0.provider,
                baseURLText: $0.baseURL.absoluteString,
                modelID: $0.model
            )
        } ?? .unknown
        let egress = settings?.provider.dataEgress(
            endpoint: settings?.baseURL.absoluteString,
            enabled: settings?.llmEnabled ?? false
        ) ?? .disabled
        let runtime = AttacheExhaustiveReviewRuntime()
        let prepared = runtime.prepare(
            source: source,
            baseSnapshot: baseSnapshot,
            capability: capability,
            egressClass: egress.rawValue
        )
        let context = ActiveExhaustiveReviewContext(
            callID: callID,
            preparedID: prepared.id,
            runtime: runtime,
            source: source,
            baseSnapshot: baseSnapshot
        )
        let modelLabel = settings.map { "\($0.provider.title) · \($0.model)" }
            ?? "Model unavailable"
        let state = AttacheExhaustiveReviewUIState(
            id: prepared.id,
            sessionTitle: source.focusedSession.displayTitle,
            modelLabel: modelLabel,
            strategyLabel: AttacheContextStrategyDescription.title(
                baseSnapshot.contextStrategy.kind
            ),
            egressLabel: egress.disclosureLabel,
            estimatedCalls: prepared.estimatedCalls,
            estimatedSourceBytes: prepared.estimatedSourceBytes,
            estimatedInputTokens: prepared.estimatedInputTokens,
            eligibleRanges: prepared.eligibleRanges
        )
        return (context, state)
    }

    @MainActor
    private func installExhaustiveReviewPreview(
        _ context: ActiveExhaustiveReviewContext,
        state: AttacheExhaustiveReviewUIState
    ) {
        exhaustiveReviewRefreshTask?.cancel()
        exhaustiveReviewRefreshTask = nil
        exhaustiveReviewRefreshID = nil
        if let prior = activeExhaustiveReview {
            prior.runtime.cancel(id: prior.preparedID)
        }
        exhaustiveReviewTask?.cancel()
        exhaustiveReviewTask = nil
        exhaustiveReviewExecutionID = nil
        exhaustiveReviewProviderExecutionID = nil
        activeExhaustiveReview = context
        AttacheContextUIState.shared.presentExhaustiveReview(state)
    }

    @MainActor
    private func startExhaustiveReview(_ review: AttacheExhaustiveReviewUIState) {
        guard let context = activeExhaustiveReview,
              context.preparedID == review.id,
              conversationActive,
              activeConversationID == context.callID else {
            AttacheContextUIState.shared.updateExhaustiveReview(
                id: review.id,
                phase: .stale,
                coveredRanges: review.coveredRanges,
                eligibleRanges: review.eligibleRanges,
                completedCalls: review.completedCalls,
                omittedRanges: review.omittedRanges
            )
            return
        }
        guard exhaustiveReviewExecutionID == nil,
              exhaustiveReviewProviderExecutionID == nil else { return }
        launchExhaustiveReview(
            context,
            waitingForReviewTask: nil,
            waitingForConversationTask: conversationRequestTask
        )
    }

    @MainActor
    private func cancelExhaustiveReview(_ review: AttacheExhaustiveReviewUIState) {
        guard let context = activeExhaustiveReview,
              context.preparedID == review.id else { return }
        exhaustiveReviewRefreshTask?.cancel()
        exhaustiveReviewRefreshTask = nil
        exhaustiveReviewRefreshID = nil
        context.runtime.cancel(id: context.preparedID)
        exhaustiveReviewTask?.cancel()
        let reviewWasUsingProvider = exhaustiveReviewProviderExecutionID != nil
        exhaustiveReviewExecutionID = nil
        exhaustiveReviewProviderExecutionID = nil
        if reviewWasUsingProvider {
            isConversing = false
            endConversationWait()
        }
        conversationStatus = "Exhaustive review canceled."
        if reviewWasUsingProvider {
            maybeResumeContinuousListening()
        }
    }

    @MainActor
    private func resumeExhaustiveReview(_ review: AttacheExhaustiveReviewUIState) {
        guard let context = activeExhaustiveReview,
              context.preparedID == review.id,
              conversationActive,
              activeConversationID == context.callID,
              exhaustiveReviewExecutionID == nil,
              exhaustiveReviewProviderExecutionID == nil else { return }
        if review.phase == .stale {
            restartStaleExhaustiveReview(context)
            return
        }
        let priorTask = exhaustiveReviewTask
        launchExhaustiveReview(
            context,
            waitingForReviewTask: priorTask,
            waitingForConversationTask: conversationRequestTask
        )
    }

    @MainActor
    private func restartStaleExhaustiveReview(
        _ prior: ActiveExhaustiveReviewContext
    ) {
        guard let current = sessionContextRuntime.authoritySnapshot().session,
              current.sessionID == prior.source.focusedSession.sessionID,
              current.sourceKind == prior.source.focusedSession.sourceKind else {
            conversationStatus = "The focused session changed. Start a new call to review the new session."
            preserveExhaustiveReviewProgress(id: prior.preparedID, phase: .stale)
            return
        }
        exhaustiveReviewRefreshTask?.cancel()
        let refreshID = UUID()
        exhaustiveReviewRefreshID = refreshID
        conversationStatus = "Refreshing the review preview from the current session…"
        exhaustiveReviewRefreshTask = Task { [weak self, prior, current] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard let source = try? self.sessionContextRuntime.freezeReviewSource(
                focusedSession: current
            ) else {
                await MainActor.run {
                    guard self.exhaustiveReviewRefreshID == refreshID,
                          self.conversationActive,
                          self.activeConversationID == prior.callID,
                          self.activeExhaustiveReview?.preparedID == prior.preparedID,
                          AttacheContextUIState.shared.exhaustiveReview?.phase == .running else {
                        return
                    }
                    self.exhaustiveReviewRefreshTask = nil
                    self.exhaustiveReviewRefreshID = nil
                    self.conversationStatus = "The current session could not be frozen for review."
                    self.preserveExhaustiveReviewProgress(
                        id: prior.preparedID,
                        phase: .stale
                    )
                }
                return
            }
            guard !Task.isCancelled else { return }
            let baseSnapshot = AttacheRequestSnapshot(
                role: .recap,
                personality: prior.baseSnapshot.personality,
                profilePrompt: prior.baseSnapshot.profilePrompt,
                userInput: prior.baseSnapshot.userInput,
                session: .focused(current),
                modelSettings: prior.baseSnapshot.modelSettings,
                contextItems: [],
                contextStrategy: prior.baseSnapshot.contextStrategy
            )
            let prepared = Self.prepareExhaustiveReview(
                source: source,
                baseSnapshot: baseSnapshot,
                callID: prior.callID
            )
            await MainActor.run {
                guard self.exhaustiveReviewRefreshID == refreshID,
                      self.conversationActive,
                      self.activeConversationID == prior.callID,
                      self.activeExhaustiveReview?.preparedID == prior.preparedID,
                      AttacheContextUIState.shared.exhaustiveReview?.phase == .running,
                      self.sessionContextRuntime.reviewSourceIsCurrent(source) else { return }
                self.exhaustiveReviewRefreshTask = nil
                self.exhaustiveReviewRefreshID = nil
                self.installExhaustiveReviewPreview(
                    prepared.context,
                    state: prepared.uiState
                )
                self.conversationStatus = "Review the updated cost preview, then press Start review."
            }
        }
    }

    @MainActor
    private func launchExhaustiveReview(
        _ context: ActiveExhaustiveReviewContext,
        waitingForReviewTask: Task<Void, Never>?,
        waitingForConversationTask: Task<Void, Never>?
    ) {
        guard exhaustiveReviewExecutionID == nil,
              exhaustiveReviewProviderExecutionID == nil else {
            preserveExhaustiveReviewProgress(
                id: context.preparedID,
                phase: .incomplete
            )
            return
        }
        let executionID = UUID()
        exhaustiveReviewExecutionID = executionID
        exhaustiveReviewTask = Task { [weak self, context] in
            if let waitingForReviewTask { await waitingForReviewTask.value }
            if let waitingForConversationTask { await waitingForConversationTask.value }
            guard !Task.isCancelled, let self else { return }
            let mayStart = await MainActor.run {
                guard self.exhaustiveReviewIsAuthorized(
                    context: context,
                    executionID: executionID
                ) else { return false }
                guard self.sessionContextRuntime.reviewSourceIsCurrent(context.source) else {
                    self.preserveExhaustiveReviewProgress(
                        id: context.preparedID,
                        phase: .stale
                    )
                    return false
                }
                self.exhaustiveReviewProviderExecutionID = executionID
                self.isConversing = true
                self.beginConversationWait()
                self.conversationStatus = "Reviewing the focused session in bounded stages…"
                return true
            }
            guard mayStart else {
                await MainActor.run {
                    guard self.exhaustiveReviewExecutionID == executionID else { return }
                    self.exhaustiveReviewTask = nil
                    self.exhaustiveReviewExecutionID = nil
                    self.exhaustiveReviewProviderExecutionID = nil
                }
                return
            }
            do {
                let outcome = try await context.runtime.runPreparedReview(
                    id: context.preparedID,
                    sourceIsCurrent: { [weak self, source = context.source] in
                        self?.sessionContextRuntime.reviewSourceIsCurrent(source) == true
                    },
                    runStage: { [weak self, context] snapshot, system, user in
                        guard let self else { throw CancellationError() }
                        guard await MainActor.run(body: {
                            self.exhaustiveReviewMayEgress(
                                context: context,
                                executionID: executionID
                            )
                        }) else { throw CancellationError() }
                        let profile = snapshot.profilePrompt
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let providerSystem = profile.isEmpty
                            ? system
                            : "\(profile)\n\n\(system)"
                        let completion = try await self.presentationService.complete(
                            snapshot: snapshot,
                            system: providerSystem,
                            user: user,
                            settingsOverride: context.baseSnapshot.modelSettings,
                            systemSources: profile.isEmpty
                                ? [.safetyPolicy]
                                : [.activePersonality, .safetyPolicy],
                            userSources: [.currentUserTurn],
                            requestIsActive: { [weak self, context] in
                                guard let self else { return false }
                                return await MainActor.run {
                                    self.exhaustiveReviewMayEgress(
                                        context: context,
                                        executionID: executionID
                                    )
                                }
                            }
                        )
                        guard await MainActor.run(body: {
                            self.exhaustiveReviewMayEgress(
                                context: context,
                                executionID: executionID
                            )
                        }) else { throw CancellationError() }
                        return completion
                    },
                    progress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.exhaustiveReviewIsAuthorized(
                                    context: context,
                                    executionID: executionID
                                  ) else { return }
                            AttacheContextUIState.shared.updateExhaustiveReview(
                                id: context.preparedID,
                                phase: .running,
                                coveredRanges: progress.coveredRanges,
                                eligibleRanges: progress.eligibleRanges,
                                completedCalls: progress.completedCalls,
                                omittedRanges: progress.omittedRanges
                            )
                        }
                    }
                )
                await MainActor.run {
                    self.finishExhaustiveReview(
                        context: context,
                        executionID: executionID,
                        outcome: outcome
                    )
                }
            } catch {
                await MainActor.run {
                    guard self.exhaustiveReviewIsAuthorized(
                        context: context,
                        executionID: executionID
                    ) else { return }
                    self.isConversing = false
                    self.endConversationWait()
                    self.exhaustiveReviewTask = nil
                    self.exhaustiveReviewExecutionID = nil
                    self.exhaustiveReviewProviderExecutionID = nil
                    let sourceIsCurrent = self.sessionContextRuntime
                        .reviewSourceIsCurrent(context.source)
                    self.preserveExhaustiveReviewProgress(
                        id: context.preparedID,
                        phase: sourceIsCurrent
                            ? (Task.isCancelled ? .canceled : .incomplete)
                            : .stale
                    )
                    if !sourceIsCurrent {
                        self.conversationStatus = "The session changed during review. Restart from the updated preview."
                    } else {
                        self.conversationStatus = Task.isCancelled
                            ? "Exhaustive review canceled."
                            : "The exhaustive review stopped before it could prove coverage."
                    }
                }
            }
        }
    }

    @MainActor
    private func preserveExhaustiveReviewProgress(
        id: String,
        phase: AttacheExhaustiveReviewUIState.Phase
    ) {
        guard let review = AttacheContextUIState.shared.exhaustiveReview,
              review.id == id else { return }
        AttacheContextUIState.shared.updateExhaustiveReview(
            id: id,
            phase: phase,
            coveredRanges: review.coveredRanges,
            eligibleRanges: review.eligibleRanges,
            completedCalls: review.completedCalls,
            omittedRanges: review.omittedRanges
        )
    }

    @MainActor
    private func exhaustiveReviewIsAuthorized(
        context: ActiveExhaustiveReviewContext,
        executionID: UUID
    ) -> Bool {
        conversationActive
            && activeConversationID == context.callID
            && activeExhaustiveReview?.preparedID == context.preparedID
            && exhaustiveReviewExecutionID == executionID
    }

    @MainActor
    private func exhaustiveReviewMayEgress(
        context: ActiveExhaustiveReviewContext,
        executionID: UUID
    ) -> Bool {
        exhaustiveReviewIsAuthorized(context: context, executionID: executionID)
            && exhaustiveReviewProviderExecutionID == executionID
            && sessionContextRuntime.reviewSourceIsCurrent(context.source)
    }

    @MainActor
    private func finishExhaustiveReview(
        context: ActiveExhaustiveReviewContext,
        executionID: UUID,
        outcome: AttacheExhaustiveReviewRuntime.Outcome
    ) {
        guard exhaustiveReviewIsAuthorized(
            context: context,
            executionID: executionID
        ) else { return }
        let phase: AttacheExhaustiveReviewUIState.Phase
        switch outcome.result.status {
        case .complete where outcome.progress.coveredRanges == outcome.progress.eligibleRanges:
            phase = .complete
        case .canceled:
            phase = .canceled
        case .stale:
            phase = .stale
        case .complete, .inProgress, .incomplete:
            phase = .incomplete
        }
        AttacheContextUIState.shared.updateExhaustiveReview(
            id: context.preparedID,
            phase: phase,
            coveredRanges: outcome.progress.coveredRanges,
            eligibleRanges: outcome.progress.eligibleRanges,
            completedCalls: outcome.progress.completedCalls,
            omittedRanges: outcome.result.omittedRanges.count
        )
        exhaustiveReviewTask = nil
        exhaustiveReviewExecutionID = nil
        exhaustiveReviewProviderExecutionID = nil
        isConversing = false
        endConversationWait()
        if phase == .complete || phase == .incomplete {
            surfaceConversationReply(
                outcome.responseText,
                inference: outcome.inference
            )
        } else {
            conversationStatus = phase == .stale
                ? "The session changed during review. Restart from the updated preview."
                : "Exhaustive review canceled."
            maybeResumeContinuousListening()
        }
    }

    private static func exhaustiveReviewToolResult(
        result: String,
        estimatedCalls: Int,
        eligibleRanges: Int,
        guidance: String
    ) -> String {
        let object: [String: Any] = [
            "result": result,
            "estimated_model_calls": max(0, estimatedCalls),
            "eligible_ranges": max(0, eligibleRanges),
            "requires_user_start": result == "preview_ready",
            "guidance": guidance
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else {
            return #"{"result":"unavailable","requires_user_start":false}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    func dismissModelSessionDiscoveryPicker() {
        modelSessionDiscoveryPicker = nil
    }

    /// Apply a native row selected from a prior discovery result. The runtime
    /// revalidates every field against its private candidate snapshot before
    /// advancing focus; a model-supplied or stale row is rejected.
    @discardableResult
    func focusDiscoveredSession(token: UUID, row: SessionSearchHit) -> Bool {
        let selection = AttacheSessionDiscoverySelection(
            sessionID: row.record.id,
            sourceKind: row.record.sourceKind.rawValue,
            displayTitle: row.record.title,
            workingDirectory: row.record.project
        )
        do {
            _ = try sessionContextRuntime.grantDiscoverySelection(
                token: token,
                selection: selection
            )
            guard let record = sessionRecords.first(where: { $0.id == row.record.id }) else {
                return false
            }
            watchSession(target(for: record), focus: true, focusAlreadyGranted: true)
            modelSessionDiscoveryPicker = nil
            if conversationActive {
                // The picker selection grants new authority, but the request and
                // call that opened it remain context-free. Start a fresh call
                // boundary so only later user turns can receive session tools.
                endConversation()
                startConversation()
                conversationStatus = "Focused \(displaySessionTitle(record)). Started a fresh call context for this session."
            }
            return true
        } catch {
            intakeStatus = "That session result changed. Search again before focusing it."
            return false
        }
    }

    /// The name Attaché shows for a session: an Attaché-local rename if set,
    /// otherwise the Codex thread name (or derived first-message title).
    func displaySessionTitle(_ record: SessionRecord) -> String {
        sessionRenames[record.id] ?? record.title
    }

    func displaySessionTitle(forID id: String, fallback: String) -> String {
        sessionRenames[id] ?? fallback
    }

    /// Rename a session for Attaché only (does not touch Codex). Empty clears it.
    func renameSession(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            sessionRenames.removeValue(forKey: id)
        } else {
            sessionRenames[id] = trimmed
        }
        defaults.set(sessionRenames, forKey: AttachePreferenceKey.sessionRenames)
    }

    /// The curated Codex project (from .codex-global-state.json `project-order`)
    /// that a session's working directory belongs to, or nil if it's projectless.
    func curatedProjectName(forCWD cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let match = curatedProjectPaths
            .filter { cwd == $0 || cwd.hasPrefix($0 + "/") }
            .max(by: { $0.count < $1.count })
        return match.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    private static func loadCuratedProjectPaths() -> [String] {
        let url = CodexPaths.home()
            .appendingPathComponent(".codex-global-state.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let order = json["project-order"] as? [String] else {
            return []
        }
        return order
    }

    func attachToSearchHit(_ hit: SessionSearchHit) {
        watchSearchHit(hit, focus: true)
    }

    func toggleWatchSearchHit(_ hit: SessionSearchHit) {
        guard let record = try? sessionContextRuntime.resolveCommandKSelection(hit) else {
            intakeStatus = "That search result changed. Search again before watching it."
            return
        }
        if attachedTargets[record.id] != nil { detachCodexSession(record.id) }
        else { watchSession(target(for: record), focus: false) }
    }

    func watchSearchHit(_ hit: SessionSearchHit, focus: Bool) {
        do {
            let record = try sessionContextRuntime.resolveCommandKSelection(hit)
            if focus {
                _ = try sessionContextRuntime.grantCommandKSelection(hit)
            }
            watchSession(
                target(for: record),
                focus: focus,
                focusAlreadyGranted: focus
            )
        } catch {
            intakeStatus = "That search result changed. Search again before focusing it."
        }
    }

    /// Map a session record to a watch target, reusing a live catalog target when
    /// one exists. Source-agnostic, so Claude Code records map too (INF-168).
    private func target(for record: SessionRecord) -> CodexSessionTarget {
        (codexSessions + archivedCodexSessions + codexAutomations).first(where: { $0.id == record.id })
            ?? CodexSessionTarget(
                id: record.id,
                title: record.title,
                updatedAt: record.updatedAt,
                category: record.archived ? .archivedSession : .activeSession,
                status: nil,
                sourceKind: record.sourceKind
            )
    }

    /// Watched targets persist with the title they had when pinned; session
    /// names improve later (the Claude app names them, markup gets cleaned),
    /// so re-sync titles from the live records after every index refresh.
    private func syncWatchedTitles() {
        var changed = false
        for (id, target) in attachedTargets {
            guard let record = sessionRecords.first(where: { $0.id == id }),
                  !record.title.isEmpty,
                  record.title != target.title else { continue }
            var updated = target
            updated.title = record.title
            attachedTargets[id] = updated
            changed = true
        }
        _ = changed   // attachedTargets' didSet persists on mutation
    }

    private func watchSession(
        _ session: CodexSessionTarget,
        focus: Bool,
        focusAlreadyGranted: Bool = false
    ) {
        attachedTargets[session.id] = session
        if focus || attachedCodexSessionID == nil {
            attachedCodexSessionID = session.id
        }
        if (focus || attachedCodexSessionID == session.id), !focusAlreadyGranted {
            synchronizeSessionContextFocus()
        }
        if focus {
            liveFollowUpText = ""
            resetLiveFollowUpAnswerStatus()
        }
        updateCodexWatcher()
        intakeStatus = focus
            ? "Watching and focused on \(session.displayTitle)."
            : "Watching \(session.displayTitle)."
    }

    func markSelectedHeard() {
        guard let card = selectedCard else { return }
        markHeard(cardID: card.id)
    }

    func markAllHeard() {
        do {
            try store.markAllHeard()
            reloadCards()
        } catch {
            intakeStatus = "Mark heard failed: \(error.localizedDescription)"
        }
    }

    func archiveSelected() {
        guard let card = selectedCard else { return }
        do {
            try store.archive(cardID: card.id)
            if playback.currentCardID == card.id {
                playback.stop()
            }
            reloadCards()
        } catch {
            intakeStatus = "Archive failed: \(error.localizedDescription)"
        }
    }

    func archiveAllCards() {
        do {
            playback.stop()
            try store.archiveAll()
            reloadCards()
            intakeStatus = "Cleared voicemail."
        } catch {
            intakeStatus = "Clear voicemail failed: \(error.localizedDescription)"
        }
    }

    func archiveCards(_ cardsToArchive: [VoicemailCard]) {
        let ids = cardsToArchive.map(\.id)
        guard !ids.isEmpty else { return }
        do {
            if let currentCardID = playback.currentCardID, ids.contains(currentCardID) {
                playback.stop()
            }
            for id in ids {
                try store.archive(cardID: id)
            }
            reloadCards()
            pruneResolvedAttention()
            intakeStatus = "Cleared \(ids.count) visible voicemail\(ids.count == 1 ? "" : "s")."
        } catch {
            intakeStatus = "Clear voicemail failed: \(error.localizedDescription)"
        }
    }

    func createFollowUpAnswer() {
        guard let card = selectedCard else { return }
        let trimmed = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            followUpStatus = "Question is empty."
            return
        }
        let target = [
            card.sourceDisplayName,
            card.externalSessionID ?? card.sessionTitle ?? "selected update"
        ].joined(separator: " / ")

        let requestID = UUID()
        followUpAnswerRequestID = requestID
        let receiptResponseID = "follow-up:\(requestID.uuidString)"
        followUpReceiptResponseID = nil
        followUpAnswerText = ""
        isGeneratingFollowUpAnswer = true
        followUpStatus = "Asking Attaché about \(target)."
        // A fresh attempt (typed question or explicit retry) supersedes any
        // stale recovery banner from a previous failure (INF-254).
        followUpRecovery = nil
        let snapshot = captureRequestSnapshot(role: .followUp, userInput: trimmed)

        presentationService.answerFollowUpQuestion(
            card: card,
            danQuestion: trimmed,
            snapshot: snapshot
        ) { [weak self] result in
            guard let self,
                  self.followUpAnswerRequestID == requestID else {
                return
            }
            self.isGeneratingFollowUpAnswer = false
            switch result {
            case .success(let answer):
                self.followUpAnswerText = answer.answerText
                self.followUpReceiptResponseID = receiptResponseID
                Task { @MainActor in
                    AttacheContextUIState.shared.publishReceipt(
                        answer.inference.receiptView.bound(to: receiptResponseID),
                        responseID: receiptResponseID
                    )
                }
                self.followUpStatus = self.followUpAnswerStatusText(
                    target: target,
                    answer: answer
                )
                self.followUpRecovery = self.classifyFollowUpRecovery(answer)
            case .failure(let error):
                self.followUpStatus = "Answer failed for \(target): \(error.localizedDescription)"
            }
        }
    }

    func clearFollowUpAnswer() {
        followUpAnswerRequestID = nil
        if let id = followUpReceiptResponseID {
            Task { @MainActor in AttacheContextUIState.shared.removeReceipt(for: id) }
        }
        followUpReceiptResponseID = nil
        followUpAnswerText = ""
        isGeneratingFollowUpAnswer = false
        followUpRecovery = nil
        resetFollowUpAnswerStatus()
    }

    func copyFollowUpAnswer() {
        let trimmed = followUpAnswerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
        followUpStatus = "Copied answer."
    }

    func useMicTranscriptForLiveFollowUp() {
        let transcript = micTranscript.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if micTranscript.isListening {
            micTranscript.stop(status: transcript.isEmpty ? "Voice input stopped." : "Voice input captured.")
        }
        guard !transcript.isEmpty else {
            liveFollowUpStatus = "No voice transcript captured yet."
            return
        }
        liveFollowUpText = transcript
        micTranscript.clearTranscript()
        liveFollowUpStatus = "Voice transcript copied into the question."
    }

    func createLiveFollowUpAnswer() {
        guard let session = talkContextSession else {
            liveFollowUpStatus = "No Codex session to talk about yet."
            return
        }
        if liveFollowUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !micTranscript.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            useMicTranscriptForLiveFollowUp()
        }
        let trimmed = liveFollowUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            liveFollowUpStatus = "Question is empty."
            return
        }

        let targetSessionID = session.id
        let target = "Codex / \(targetSessionID)"
        let requestID = UUID()
        liveFollowUpAnswerRequestID = requestID
        let receiptResponseID = "live-follow-up:\(requestID.uuidString)"
        liveFollowUpReceiptResponseID = nil
        liveFollowUpAnswerText = ""
        isGeneratingLiveFollowUpAnswer = true
        liveFollowUpStatus = "Asking Attaché about \(session.displayTitle)."
        // A fresh attempt (typed question or explicit retry) supersedes any
        // stale recovery banner from a previous failure (INF-254).
        liveFollowUpRecovery = nil
        let card = followUpContextCard(for: session)
        let snapshot = captureRequestSnapshot(role: .liveFollowUp, userInput: trimmed)
        guard let frozenSession = snapshot.focusedSession,
              frozenSession.sessionID == session.id else {
            isGeneratingLiveFollowUpAnswer = false
            liveFollowUpStatus = "That session is no longer authorized. Focus it again and retry."
            return
        }

        presentationService.answerFollowUpQuestion(
            card: card,
            danQuestion: trimmed,
            snapshot: snapshot,
            requestIsActive: { [weak self] in
                guard let self else { return false }
                return await MainActor.run {
                    guard self.liveFollowUpAnswerRequestID == requestID else { return false }
                    return self.sessionContextRuntime.authoritySnapshot().session?
                        .hasSameAuthorization(as: frozenSession) == true
                }
            }
        ) { [weak self] result in
            guard let self,
                  self.liveFollowUpAnswerRequestID == requestID else {
                return
            }
            self.isGeneratingLiveFollowUpAnswer = false
            switch result {
            case .success(let answer):
                self.liveFollowUpAnswerText = answer.answerText
                self.liveFollowUpReceiptResponseID = receiptResponseID
                Task { @MainActor in
                    AttacheContextUIState.shared.publishReceipt(
                        answer.inference.receiptView.bound(to: receiptResponseID),
                        responseID: receiptResponseID
                    )
                }
                self.liveFollowUpStatus = self.followUpAnswerStatusText(
                    target: target,
                    answer: answer
                )
                self.liveFollowUpRecovery = self.classifyFollowUpRecovery(answer)
            case .failure(let error):
                self.liveFollowUpStatus = "Answer failed for \(target): \(error.localizedDescription)"
            }
        }
    }

    func clearLiveFollowUpAnswer() {
        liveFollowUpAnswerRequestID = nil
        if let id = liveFollowUpReceiptResponseID {
            Task { @MainActor in AttacheContextUIState.shared.removeReceipt(for: id) }
        }
        liveFollowUpReceiptResponseID = nil
        liveFollowUpAnswerText = ""
        isGeneratingLiveFollowUpAnswer = false
        liveFollowUpRecovery = nil
        resetLiveFollowUpAnswerStatus()
    }

    func copyLiveFollowUpAnswer() {
        let trimmed = liveFollowUpAnswerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
        liveFollowUpStatus = "Copied answer."
    }

    private func followUpAnswerStatusText(
        target: String,
        answer: AttacheFollowUpAnswerResult
    ) -> String {
        let holdText = "Answered from observed context for \(target). Nothing was sent to Codex."
        var notes: [String] = [holdText]
        if answer.strategy == "deterministic-follow-up-fallback" {
            notes.append("Personality LLM was not configured, so fallback context was used.")
        } else if answer.strategy == "deterministic-follow-up-fallback-after-llm-error" {
            let error = answer.errorDescription.map { " \($0)" } ?? ""
            notes.append("Personality LLM failed, so fallback context was used.\(error)")
        }
        if answer.truncatedContext {
            notes.append("Context was truncated before answering.")
        }
        return notes.joined(separator: " ")
    }

    private func resetFollowUpAnswerStatus() {
        followUpAnswerRequestID = nil
        if let id = followUpReceiptResponseID {
            Task { @MainActor in AttacheContextUIState.shared.removeReceipt(for: id) }
        }
        followUpReceiptResponseID = nil
        followUpAnswerText = ""
        isGeneratingFollowUpAnswer = false
        followUpStatus = "Ask Attaché about this update."
    }

    private func resetLiveFollowUpAnswerStatus() {
        liveFollowUpAnswerRequestID = nil
        if let id = liveFollowUpReceiptResponseID {
            Task { @MainActor in AttacheContextUIState.shared.removeReceipt(for: id) }
        }
        liveFollowUpReceiptResponseID = nil
        liveFollowUpAnswerText = ""
        isGeneratingLiveFollowUpAnswer = false
        if let session = talkContextSession {
            liveFollowUpStatus = "Ready to ask Attaché about \(session.displayTitle)."
        } else {
            liveFollowUpStatus = "No Codex session to talk about yet."
        }
    }

    private func followUpContextCard(for session: CodexSessionTarget) -> VoicemailCard {
        let selectedContextCard: VoicemailCard?
        if let selectedCard,
           SourceKind.liveAgentRawValues.contains(selectedCard.sourceKind),
           selectedCard.externalSessionID == session.id {
            selectedContextCard = selectedCard
        } else {
            selectedContextCard = nil
        }

        var contextCards: [VoicemailCard] = []
        if let selectedContextCard {
            contextCards.append(selectedContextCard)
        }
        contextCards.append(contentsOf: attachedSessionHistory
            .filter { card in
                SourceKind.liveAgentRawValues.contains(card.sourceKind)
                    && card.externalSessionID == session.id
                    && card.id != selectedContextCard?.id
            }
            .prefix(5))

        return VoicemailCard(
            id: "direct-\(session.id)",
            sourceID: SourceKind.codex.rawValue,
            sourceKind: SourceKind.codex.rawValue,
            sourceDisplayName: "Codex",
            sessionID: nil,
            externalSessionID: session.id,
            projectPath: contextCards.first?.projectPath,
            sessionTitle: session.displayTitle,
            kind: .update,
            rawText: Self.followUpRawHistory(from: contextCards),
            summary: selectedContextCard?.summary ?? "Question about \(session.displayTitle)",
            spokenText: Self.followUpSpokenHistory(from: contextCards),
            status: .heard,
            createdAt: Date(),
            heardAt: nil,
            metadataJSON: #"{"synthetic":"attache_follow_up_context"}"#,
            durationMs: 0,
            alignment: nil
        )
    }

    private static func followUpSpokenHistory(from cards: [VoicemailCard]) -> String {
        guard !cards.isEmpty else { return "" }
        let lines = cards.prefix(5).enumerated().compactMap { index, card -> String? in
            let text = firstNonEmpty(card.spokenText, card.summary, card.rawText)
            guard !text.isEmpty else { return nil }
            let title = card.sessionTitle ?? card.summary
            return "\(index + 1). \(title): \(clipped(text, limit: 700))"
        }
        guard !lines.isEmpty else { return "" }
        return "Recent history for this attached Codex session, newest first:\n"
            + lines.joined(separator: "\n")
    }

    private static func followUpRawHistory(from cards: [VoicemailCard]) -> String {
        guard !cards.isEmpty else { return "" }
        let lines = cards.prefix(3).enumerated().compactMap { index, card -> String? in
            let text = firstNonEmpty(card.rawText, card.spokenText, card.summary)
            guard !text.isEmpty else { return nil }
            let title = card.sessionTitle ?? card.summary
            return "Recent agent output \(index + 1) for \(title):\n\(clipped(text, limit: 2_000))"
        }
        return lines.joined(separator: "\n\n")
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func clipped(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<end]) + "..."
    }

    private func canHandle(_ command: LocalCardCommand) -> Bool {
        switch command {
        case .play(let cardID), .markHeard(let cardID):
            return cards.contains { $0.id == cardID }
        }
    }

    private func handle(_ command: LocalCardCommand) {
        switch command {
        case .play(let cardID):
            guard let card = cards.first(where: { $0.id == cardID }) else { return }
            selectedCardID = card.id
            playCardRespectingEgress(card)
        case .markHeard(let cardID):
            markHeard(cardID: cardID)
        }
    }

    private func markHeard(cardID: String) {
        do {
            try store.markHeard(cardID: cardID)
            reloadCards(select: cardID)
        } catch {
            intakeStatus = "Mark heard failed: \(error.localizedDescription)"
        }
    }

    private func finishPlayback(cardID: String, success: Bool) {
        selectedStartProgress = 0
        let finishedCard = cards.first { $0.id == cardID }
        if success {
            markHeard(cardID: cardID)
            if let card = finishedCard,
               let key = card.externalSessionID {
                let previous = lastSpokenSourceTime[key]
                if previous == nil || card.createdAt > previous! {
                    lastSpokenSourceTime[key] = card.createdAt
                }
            }
        } else {
            // Keep the update visible and unread so it isn't lost, and record why
            // it didn't speak. The queue still advances so one failure doesn't
            // stall the drain.
            reloadCards()
            intakeStatus = "Voice playback failed for an update; it stays unread to replay."
        }
        // A spoken conversation reply is not part of the update backlog: it
        // preempted the live queue, so resume that queue and go back to
        // listening instead of advancing drains.
        if let card = finishedCard, isDirectConversationReply(card) {
            if pendingAssistantReply != nil {
                revealPendingReply()
            }
            expectingReplyAudio = false
            if !success {
                conversationStatus = "Voice playback failed. Reply was filed."
            }
            resumeLiveQueueAfterReply()
            maybeResumeContinuousListening()
            return
        }
        // Catch-me-up advances first: it is an explicit user action walking
        // the backlog (INF-169), distinct from the gated live queue below.
        if advanceCatchUpQueueIfNeeded() { return }
        // Only auto-advance the live queue while on a call and not in voicemail
        // mode; a manual replay off-call must never chain into the backlog (INF-163).
        let next = livePlaybackQueue.finished()
        if onCall, !voicemailMode, let next {
            playCardLive(cardID: next)
        }
    }

    private func isDirectConversationReply(_ card: VoicemailCard) -> Bool {
        let metadata = metadataDictionary(for: card)
        return metadata["companion_history_kind"] == "direct_reply"
            || metadata["companion_direct_reply"] == "true"
    }

    /// Resume the live queue after a conversation reply (a preview) finished.
    private func resumeLiveQueueAfterReply() {
        guard onCall else {
            livePlaybackQueue.reset()
            return
        }
        if let next = livePlaybackQueue.replyFinished() {
            playCardLive(cardID: next)
        }
    }

    /// Play a queued live update by id without marking it heard first; heard state
    /// is set in `finishPlayback` only after it actually plays.
    private func playCardLive(cardID: String) {
        guard onCall else {
            livePlaybackQueue.reset()
            return
        }
        reloadCards(select: cardID)
        guard let card = cards.first(where: { $0.id == cardID }) else {
            // The card vanished (archived/deleted); free the slot and move on.
            if let next = livePlaybackQueue.finished() { playCardLive(cardID: next) }
            return
        }
        playCardRespectingEgress(card)
        intakeStatus = "Playing attached \(card.sourceDisplayName) update live."
    }

    // MARK: Custom themes

    func selectCustomTheme(_ id: String) {
        guard let spec = customThemes.first(where: { $0.id == id }) else { return }
        activeCustomThemeID = id
        CustomThemeStore.activeSpec = spec
        theme = .custom
    }

    /// Live-applies an edited spec (memory and views immediately, disk after a
    /// short debounce so a color-wheel drag does not write per tick). Accents
    /// are clamped to the contrast floor before anything is shown or saved.
    func applyCustomThemeEdit(_ spec: AttacheThemeSpec) {
        let enforced = spec.enforcingContrastFloor()
        if let index = customThemes.firstIndex(where: { $0.id == enforced.id }) {
            customThemes[index] = enforced
        } else {
            customThemes.append(enforced)
        }
        if activeCustomThemeID == enforced.id {
            CustomThemeStore.activeSpec = enforced
            if theme == .custom { theme = .custom }
        }
        customThemePersistWork?.cancel()
        let work = DispatchWorkItem { CustomThemeStore.save(enforced) }
        customThemePersistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Starts a new custom theme seeded from whatever theme is active, so the
    /// editor opens with something recognizable instead of gray.
    @discardableResult
    func createCustomTheme() -> AttacheThemeSpec {
        let base = theme
        let spec = AttacheThemeSpec(
            name: "My Theme",
            stops: base.stops,
            accentDark: base.accentStop(darkScheme: true),
            accentLight: base.accentStop(darkScheme: false),
            wantsSolidPlates: base.wantsSolidPlates
        )
        CustomThemeStore.save(spec)
        customThemes = CustomThemeStore.load()
        selectCustomTheme(spec.id)
        return spec
    }

    func deleteCustomTheme(_ id: String) {
        CustomThemeStore.delete(id)
        customThemes = CustomThemeStore.load()
        if activeCustomThemeID == id {
            activeCustomThemeID = nil
            CustomThemeStore.activeSpec = nil
            if theme == .custom { theme = .macOS }
        }
    }

    /// Applies the chosen light/dark appearance to the whole app. `.system`
    /// clears the override so the app follows the macOS appearance.
    func applyAppearance() {
        NSApp.appearance = appearanceMode.nsAppearance
    }

    @discardableResult
    func importCustomTheme(from url: URL) throws -> AttacheThemeSpec {
        let data = try Data(contentsOf: url)
        var spec = try CustomThemeStore.decode(data).enforcingContrastFloor()
        // A fresh identity on import so a shared file never collides with or
        // silently overwrites an existing theme.
        if customThemes.contains(where: { $0.id == spec.id }) {
            spec.id = UUID().uuidString
        }
        CustomThemeStore.save(spec)
        customThemes = CustomThemeStore.load()
        selectCustomTheme(spec.id)
        return spec
    }

    func exportCustomTheme(_ id: String, to url: URL) throws {
        guard let spec = customThemes.first(where: { $0.id == id }) else { return }
        try CustomThemeStore.encode(spec).write(to: url, options: .atomic)
    }

    private func loadPreferences() {
        if let value = defaults.string(forKey: AttachePreferenceKey.visualMode),
           let mode = AttacheVisualMode(persistedRawValue: value) {
            visualMode = mode
            if value != mode.rawValue {
                defaults.set(mode.rawValue, forKey: AttachePreferenceKey.visualMode)
            }
        }
        miniAttacheEnabled = defaults.bool(forKey: AttachePreferenceKey.miniAttache)
        miniAttacheClickThrough = defaults.bool(forKey: AttachePreferenceKey.miniAttacheClickThrough)
        if defaults.object(forKey: AttachePreferenceKey.characterFocusAngle) != nil {
            characterFocusAngle = defaults.double(forKey: AttachePreferenceKey.characterFocusAngle)
        }
        if let value = defaults.string(forKey: AttachePreferenceKey.character),
           let characterChoice = AttacheCharacter(rawValue: value) {
            character = characterChoice
        }
        // Custom themes load before the theme selection so a persisted
        // "custom" choice resolves its colors instead of the fallback.
        customThemes = CustomThemeStore.load()
        if let storedID = defaults.string(forKey: AttachePreferenceKey.customThemeID) {
            activeCustomThemeID = storedID
            CustomThemeStore.activeSpec = customThemes.first { $0.id == storedID }
        }
        if let value = defaults.string(forKey: AttachePreferenceKey.theme),
           let loadedTheme = AttacheTheme(rawValue: value) {
            theme = loadedTheme
        }
        if let value = defaults.string(forKey: AttachePreferenceKey.appearanceMode),
           let loadedMode = AttacheAppearanceMode(rawValue: value) {
            appearanceMode = loadedMode
        } else {
            applyAppearance()
        }
        if defaults.object(forKey: AttachePreferenceKey.surfaceOpacity) != nil {
            surfaceOpacity = min(1.0, max(0.35, defaults.double(forKey: AttachePreferenceKey.surfaceOpacity)))
        }
        if defaults.object(forKey: AttachePreferenceKey.seekStepSeconds) != nil {
            seekStepSeconds = min(30, max(2, defaults.integer(forKey: AttachePreferenceKey.seekStepSeconds)))
        }
        if defaults.object(forKey: AttachePreferenceKey.captionFontSize) != nil {
            captionFontSize = defaults.double(forKey: AttachePreferenceKey.captionFontSize)
        }
        if defaults.object(forKey: AttachePreferenceKey.captionLineCount) != nil {
            captionLineCount = defaults.integer(forKey: AttachePreferenceKey.captionLineCount)
        }
        if defaults.object(forKey: AttachePreferenceKey.audioCacheRetentionMinutes) != nil {
            audioCacheRetentionMinutes = defaults.integer(forKey: AttachePreferenceKey.audioCacheRetentionMinutes)
        } else {
            playback.setAudioCacheRetention(minutes: audioCacheRetentionMinutes)
        }
        if let voiceModeRaw = defaults.string(forKey: AttachePreferenceKey.voiceInputMode),
           let voiceMode = AttacheVoiceInputMode(rawValue: voiceModeRaw) {
            voiceInputMode = voiceMode
        }
        if let narrationRaw = defaults.string(forKey: AttachePreferenceKey.narrationDetail),
           let narration = AttacheNarrationDetail(rawValue: narrationRaw) {
            narrationDetail = narration
        }
        if let value = defaults.string(forKey: AttachePreferenceKey.microphoneDeviceID) {
            microphoneDeviceID = value
        }
        if let renames = defaults.dictionary(forKey: AttachePreferenceKey.sessionRenames) as? [String: String] {
            sessionRenames = renames
        }
        if defaults.object(forKey: AttachePreferenceKey.codexSourceEnabled) != nil {
            codexSourceEnabled = defaults.bool(forKey: AttachePreferenceKey.codexSourceEnabled)
        }
        if defaults.object(forKey: AttachePreferenceKey.claudeCodeSourceEnabled) != nil {
            claudeCodeSourceEnabled = defaults.bool(forKey: AttachePreferenceKey.claudeCodeSourceEnabled)
        }
        if let raw = defaults.string(forKey: AttachePreferenceKey.agentInstructionSendPolicy),
           let policy = AgentInstructionSendPolicy(rawValue: raw) {
            agentInstructionSendPolicy = policy
        }
        loadWatchedSessions()
        if defaults.object(forKey: AttachePreferenceKey.captionsEnabled) != nil {
            captionsEnabled = defaults.bool(forKey: AttachePreferenceKey.captionsEnabled)
        }
        if defaults.object(forKey: AttachePreferenceKey.uiTextScale) != nil {
            uiTextScale = AttacheTypeScale.clamp(defaults.double(forKey: AttachePreferenceKey.uiTextScale))
        }
        // A pending resume step (set by the mid-onboarding voice relaunch)
        // reopens the sheet even when a previous run was completed, so the
        // Help-menu re-run path resumes too.
        showOnboarding = !defaults.bool(forKey: AttachePreferenceKey.onboardingCompleted)
            || defaults.object(forKey: AttachePreferenceKey.onboardingResumeStep) != nil
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.detectNewlyDownloadedVoice()
        }
        if let value = defaults.string(forKey: AttachePreferenceKey.spokenLanguage) {
            spokenLanguage = AttacheCaptionLanguage.named(value).id
        }
        if defaults.object(forKey: AttachePreferenceKey.voicemailMode) != nil {
            voicemailMode = defaults.bool(forKey: AttachePreferenceKey.voicemailMode)
        }
        if defaults.object(forKey: AttachePreferenceKey.autoHideControls) != nil {
            autoHideControls = defaults.bool(forKey: AttachePreferenceKey.autoHideControls)
        }
        if defaults.object(forKey: AttachePreferenceKey.autoHideDelaySeconds) != nil {
            let value = defaults.double(forKey: AttachePreferenceKey.autoHideDelaySeconds)
            if value >= 1, value <= 8 { autoHideDelaySeconds = value }
        }
        if defaults.object(forKey: AttachePreferenceKey.showPersonalityNameInDock) != nil {
            showPersonalityNameInDock = defaults.bool(forKey: AttachePreferenceKey.showPersonalityNameInDock)
        }
        if let value = defaults.string(forKey: AttachePreferenceKey.notifyScope),
           let scope = AttacheNotifyScope(rawValue: value) {
            notifyScope = scope
        }
        if defaults.object(forKey: AttachePreferenceKey.showInMenuBar) != nil {
            showInMenuBar = defaults.bool(forKey: AttachePreferenceKey.showInMenuBar)
        }
        if defaults.object(forKey: AttachePreferenceKey.playbackSpeed) != nil {
            playbackSpeed = min(1.6, max(0.8, defaults.double(forKey: AttachePreferenceKey.playbackSpeed)))
        }
        if defaults.object(forKey: AttachePreferenceKey.showTips) != nil {
            showTips = defaults.bool(forKey: AttachePreferenceKey.showTips)
        }
        if defaults.object(forKey: AttachePreferenceKey.installClaudeHooks) != nil {
            installClaudeHooks = defaults.bool(forKey: AttachePreferenceKey.installClaudeHooks)
        }
        if defaults.object(forKey: AttachePreferenceKey.showPersonalitySwitcher) != nil {
            showPersonalitySwitcher = defaults.bool(forKey: AttachePreferenceKey.showPersonalitySwitcher)
        }
        if defaults.object(forKey: AttachePreferenceKey.showActivityInsights) != nil {
            showActivityInsights = defaults.bool(forKey: AttachePreferenceKey.showActivityInsights)
        }
        if defaults.object(forKey: AttachePreferenceKey.captionSyncOffsetMs) != nil {
            captionSyncOffsetMs = min(10_000, max(-2_000, defaults.integer(forKey: AttachePreferenceKey.captionSyncOffsetMs)))
        }
        // The migration reads the keychain, and a keychain read can block on a
        // SecurityAgent authorization (first launch after the app bundle is
        // replaced). Running it inline here left the app alive with no window
        // until the dialog was answered, so it runs once, off the launch path.
        if !defaults.bool(forKey: AttachePreferenceKey.legacyKeyMigrationDone) {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.migrateLegacyPresentationKeys()
                DispatchQueue.main.async {
                    self?.defaults.set(true, forKey: AttachePreferenceKey.legacyKeyMigrationDone)
                }
            }
        }
        // Loads the main Settings > Model row state, which is the shared
        // "main model" any role with no per-role override falls back to;
        // .conversation is the reasonable placeholder role for that row (see
        // the same call in loadPresentationModels, and roleModelProvider/D3
        // for the per-role overrides loaded just below).
        let presentationSettings = AttachePresentationSettings.load(
            role: .conversation,
            defaults: defaults,
            environment: presentationEnvironment,
            resolveSecrets: false
        )
        presentationLLMEnabled = presentationSettings.llmEnabled
        presentationProvider = presentationSettings.provider
        presentationBaseURL = presentationSettings.baseURL.absoluteString
        presentationModel = presentationSettings.model
        presentationReasoningEffort = presentationSettings.reasoningEffort ?? presentationSettings.provider.defaultReasoningEffort
        presentationServiceTier = presentationSettings.serviceTier ?? presentationSettings.provider.defaultServiceTier
        presentationAPIKeySecretRef = presentationSettings.apiKeySecretRef
        applyFallbackCapabilitiesForCurrentModel()
        loadRoleModelOverrides()
        if defaults.object(forKey: AttachePreferenceKey.conversationFallbackChainEnabled) != nil {
            conversationFallbackChainEnabled = defaults.bool(forKey: AttachePreferenceKey.conversationFallbackChainEnabled)
        }
        conversationFallbackChain = ((defaults.array(forKey: AttachePreferenceKey.conversationFallbackChainProviders) as? [String]) ?? [])
            .reduce(into: [AttachePresentationProvider]()) { result, raw in
                let provider = AttachePresentationProvider.isLegacyLMStudio(explicitValue: raw, baseURLText: nil)
                    ? .ollama
                    : AttachePresentationProvider(rawValue: raw)
                if let provider, !result.contains(provider) { result.append(provider) }
            }
        // Endpoint-bound consent migration must see the persisted integration
        // URLs, not the property defaults.
        if let value = defaults.string(forKey: AttachePreferenceKey.ollamaBaseURL), !value.isEmpty { ollamaBaseURL = value }
        if let value = defaults.string(forKey: AttachePreferenceKey.customBaseURL), !value.isEmpty { customBaseURL = value }
        // Needs presentationProvider and integration endpoints loaded above;
        // pure defaults read/write, so unlike key migration it is safe inline.
        migrateCloudConsentToPerProvider()
        if let value = defaults.string(forKey: AttachePreferenceKey.speechProvider),
           let provider = AttacheSpeechProvider(rawValue: value) {
            speechProvider = provider
        }
        if let value = defaults.string(forKey: AttachePreferenceKey.elevenLabsModelID),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            elevenLabsModelID = value
        }
        if let value = defaults.string(forKey: AttachePreferenceKey.elevenLabsOutputFormat),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            elevenLabsOutputFormat = value
        }
        if let value = defaults.string(forKey: AttachePreferenceKey.xaiBaseURL),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            xaiBaseURL = value
        }
        if let value = defaults.string(forKey: AttachePreferenceKey.xaiLanguage),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            xaiLanguage = value
        }
        // Voice approval is provider and endpoint scoped. Migration must run
        // after both the saved provider and saved xAI endpoint are loaded.
        migrateCloudVoiceConsentToScopes()
        loadStoredSecretsAsync(presentationAccount: presentationSettings.provider.developmentSecretAccount)
        speechVoiceOptions = AttacheVoiceCatalog.options()
        if let savedVoice = defaults.string(forKey: AttachePreferenceKey.speechVoiceIdentifier) {
            let trimmed = savedVoice.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == Self.systemVoicePreference || trimmed.isEmpty {
                speechVoiceIdentifier = nil
            } else if trimmed == Self.legacyAutoSelectedSamanthaVoiceID,
                      !defaults.bool(forKey: AttachePreferenceKey.legacySamanthaDefaultMigrated) {
                defaults.set(true, forKey: AttachePreferenceKey.legacySamanthaDefaultMigrated)
                speechVoiceIdentifier = nil
            } else if speechVoiceOptions.contains(where: { $0.id == trimmed }) {
                speechVoiceIdentifier = trimmed
            } else {
                speechVoiceIdentifier = nil
            }
        } else {
            speechVoiceIdentifier = nil
        }
        applySpeechConfiguration()
        if let savedFocus = defaults.string(forKey: AttachePreferenceKey.attachedCodexSessionID),
           attachedTargets[savedFocus] != nil || codexSourceEnabled {
            attachedCodexSessionID = savedFocus
        } else {
            attachedCodexSessionID = attachedSessionList.first?.id
        }
    }

    /// Loads every stored API key off the launch path. A keychain read can
    /// block on a SecurityAgent authorization (first launch after the bundle
    /// is replaced), and doing that inline left the app running with no
    /// window. Keys land on main a beat later; their didSets re-apply the
    /// speech configuration, and the key-gated voice preferences follow.
    private func loadStoredSecretsAsync(presentationAccount: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let presentation = self.readConfiguredSecret(account: presentationAccount) ?? ""
            let elevenLabs = self.readConfiguredSecret(account: Self.elevenLabsDevelopmentSecretAccount)
                ?? self.environmentValue("COMPANION_ELEVENLABS_API_KEY", "ELEVENLABS_API_KEY")
                ?? ""
            let xai = self.readConfiguredSecret(account: Self.xaiDevelopmentSecretAccount) ?? ""
            let groq = self.readConfiguredSecret(account: AttachePresentationProvider.groq.developmentSecretAccount) ?? ""
            let custom = self.readConfiguredSecret(account: AttachePresentationProvider.custom.developmentSecretAccount) ?? ""
            let openai = self.readConfiguredSecret(account: Self.openaiDevelopmentSecretAccount) ?? ""
            DispatchQueue.main.async {
                self.presentationAPIKey = presentation
                self.elevenLabsAPIKey = elevenLabs
                self.xaiAPIKey = xai
                self.groqAPIKey = groq
                self.customAPIKey = custom
                self.openaiVoiceAPIKey = openai
                self.applyStoredCloudVoicePreferences()
                if !self.store.isInMemory {
                    // Populate or refresh the exact active model's capability
                    // lineage after secrets arrive, off the launch path. Until
                    // this finishes, the compiler safely uses its unknown-model
                    // envelope or the persisted last-known record.
                    self.loadPresentationModels(preserveCurrentSelection: true)
                }
            }
        }
    }

    /// Voice preferences that only make sense once the matching cloud key is
    /// present, applied after the stored secrets finish loading.
    private func applyStoredCloudVoicePreferences() {
        let hasElevenLabsKey = !elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasXAIKey = !xaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasOpenAIKey = !effectiveOpenAIVoiceKey.isEmpty

        if hasElevenLabsKey, let value = defaults.string(forKey: AttachePreferenceKey.elevenLabsVoiceID) {
            elevenLabsVoiceID = value
        }
        if hasElevenLabsKey, let value = defaults.string(forKey: AttachePreferenceKey.elevenLabsVoiceName) {
            elevenLabsVoiceName = value
        }
        if hasXAIKey, let value = defaults.string(forKey: AttachePreferenceKey.xaiVoiceID),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            xaiVoiceID = value
        }
        if hasXAIKey, let value = defaults.string(forKey: AttachePreferenceKey.xaiVoiceName),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            xaiVoiceName = value
        }
        if hasOpenAIKey, let value = defaults.string(forKey: AttachePreferenceKey.openaiVoiceID),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            openaiVoiceID = value
        }
        if hasOpenAIKey, let value = defaults.string(forKey: AttachePreferenceKey.openaiVoiceName),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            openaiVoiceName = value
        }
    }

    private func environmentValue(_ names: String...) -> String? {
        for name in names {
            if let value = presentationEnvironment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func applyMicConfiguration() {
        micTranscript.configure(
            languageID: spokenLanguage,
            onDeviceOnly: false,
            lowLatency: true,
            preferredDeviceID: microphoneDeviceID
        )
    }

    func refreshMicrophoneDevices() {
        microphoneDevices = MicTranscriptController.inputDevices()
        if !microphoneDeviceID.isEmpty,
           !microphoneDevices.contains(where: { $0.id == microphoneDeviceID }) {
            microphoneDeviceID = ""
        } else {
            applyMicConfiguration()
        }
    }

    func startMicrophoneTest() {
        refreshMicrophoneDevices()
        applyMicConfiguration()
        micTranscript.startMicTest()
    }

    func stopMicrophoneTest() {
        micTranscript.stopMicTest()
    }

    private var selectedSpeechConfiguration: AttacheSpeechConfiguration {
        AttacheSpeechConfiguration(
            provider: speechProvider,
            remoteEgressConsentScope: speechProvider.sendsToCloud && cloudVoiceConsentAcknowledged(
                for: speechProvider,
                xaiBaseURL: xaiBaseURL
            ) ? voiceConsentScope(for: speechProvider, xaiBaseURL: xaiBaseURL).storageKey : nil,
            systemVoiceIdentifier: speechVoiceIdentifier,
            elevenLabsAPIKey: elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : elevenLabsAPIKey,
            elevenLabsVoiceID: elevenLabsVoiceID,
            elevenLabsModelID: elevenLabsModelID,
            elevenLabsOutputFormat: elevenLabsOutputFormat,
            xaiAPIKey: xaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : xaiAPIKey,
            xaiBaseURL: xaiBaseURL,
            xaiVoiceID: xaiVoiceID,
            xaiLanguage: xaiLanguage,
            openaiAPIKey: effectiveOpenAIVoiceKey.isEmpty ? nil : effectiveOpenAIVoiceKey,
            openaiVoiceID: openaiVoiceID,
            openaiModel: "gpt-4o-mini-tts",
            openaiInstructions: ""
        )
    }

    /// Local-only model output must stay on this Mac even when the active
    /// personality normally speaks through a cloud voice.
    private var localOnlySpeechConfiguration: AttacheSpeechConfiguration {
        var configuration = selectedSpeechConfiguration
        configuration.provider = .system
        configuration.remoteEgressConsentScope = nil
        configuration.systemVoiceIdentifier = speechVoiceIdentifier
        return configuration
    }

    private func applySpeechConfiguration() {
        playback.configureVoice(
            configuration: selectedSpeechConfiguration.resolvedForPlayback(
                systemVoiceIdentifier: speechVoiceIdentifier
            )
        )
    }

    private func seekRelative(milliseconds: Int) {
        guard let card = selectedCard else { return }
        if playback.currentCardID == card.id, playback.isPlaying, playback.durationMs > 0 {
            playback.seek(by: milliseconds)
            refreshNowPlaying()
            return
        }

        let duration = max(1, card.durationMs)
        let delta = Double(milliseconds) / Double(duration)
        selectedStartProgress = min(1, max(0, selectedStartProgress + delta))
    }

    private func shouldPlayLive(_ event: NormalizedEvent) -> Bool {
        // On a call = the conversation is open. Then the focused session's updates
        // speak live; off a call, everything (including focused) collects as voicemail.
        guard onCall,
              SourceKind.liveAgentRawValues.contains(event.source),
              let callTarget = conversationTargetSnapshot?.target,
              callTarget.category == .activeSession,
              event.externalSessionID == callTarget.id else {
            return false
        }
        return true
    }

    /// Whether you're on a call with the focused session (live two-way). This is the
    /// conversation being active; off-call, updates wait quietly in the inbox.
    var onCall: Bool { conversationActive }

    /// Start a call with the focused session (or the best talk target): live narration
    /// plus two-way conversation.
    func startCall() {
        // A new call is a clean slate for two-way status: any instruction
        // that already failed before this call (e.g. the fail-closed marker
        // written after a crash or restart) stays in the Sent log, but must
        // not greet the user as a red error in the fresh call's composer.
        // Failures that happen DURING this call still surface.
        acknowledgedFailedSendIDs.formUnion(twoWay.log.filter { $0.state == .failed }.map(\.id))
        refreshCallPhase()
        startConversation()
        if let session = conversationTargetSnapshot?.target {
            intakeStatus = "On a call with \(session.displayTitle)."
        }
    }

    func endCall() {
        endConversation()
        intakeStatus = "Call ended. Updates will wait in your inbox."
    }

    private func updateCodexWatcher() {
        guard !store.isInMemory else {
            codexSessionWatcher.stop()
            sessionActivityWatcher.stop()
            return
        }
        // Watch every attached active session; their updates become voicemails, and the
        // focused one additionally speaks live while on a call.
        var targets = Array(attachedTargets.values)
        // Include the focused session restored from defaults even before it lands in the
        // in-memory watch list (resolved via the catalog).
        if let focused = attachedCodexSession, attachedTargets[focused.id] == nil {
            targets.append(focused)
        }
        let enabledTargets = targets.filter {
            $0.category == .activeSession
                && (($0.sourceKind == .codex && codexSourceEnabled)
                    || ($0.sourceKind == .claudeCode && claudeCodeSourceEnabled))
        }
        codexSessionWatcher.watch(enabledTargets)
        // Ambient verbs cover every watched session, not just the focused
        // one: the corner-glance experience ("oh, it's committing something")
        // has to work while a background worker is the only thing running,
        // which is exactly when nothing is focused.
        if showActivityInsights, !enabledTargets.isEmpty {
            sessionActivityWatcher.watch(enabledTargets)
        } else {
            sessionActivityWatcher.stop()
        }
    }

    /// Switch which attached session is focused, without changing the watch list.
    func focusCodexSession(_ id: String) {
        guard attachedTargets[id] != nil else {
            // Fabricated sessions from the activity simulator are not in the
            // watch list; route their focus clicks to the panel so QA can
            // exercise focus changes on the ring (INF-284).
            if simulatedActivity != nil {
                simulatedFleetFocusID = id
            }
            return
        }
        guard id != attachedCodexSessionID else { return }
        attachedCodexSessionID = id
        synchronizeSessionContextFocus()
        liveFollowUpText = ""
        resetLiveFollowUpAnswerStatus()
        updateCodexWatcher()
    }

    /// The simulator's focus override (INF-284): which fabricated session the
    /// user last clicked on the ring. Consumed by ActivitySimulatorPanel.
    @Published var simulatedFleetFocusID: String?

    /// Mini Window size requests from its context menu (INF-286); the
    /// window controller applies them, keeping frame persistence intact.
    let miniAttacheResize = PassthroughSubject<NSSize, Never>()

    /// Remove a session from the watch list (stop collecting its voicemail).
    func detachCodexSession(_ id: String) {
        attachedTargets.removeValue(forKey: id)
        if attachedCodexSessionID == id { attachedCodexSessionID = attachedSessionList.first?.id }
        synchronizeSessionContextFocus()
        updateCodexWatcher()
    }

    private func persistWatchedSessions() {
        let sessions = attachedSessionList
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        defaults.set(data, forKey: AttachePreferenceKey.watchedSessions)
    }

    private func loadWatchedSessions() {
        guard let data = defaults.data(forKey: AttachePreferenceKey.watchedSessions),
              let sessions = try? JSONDecoder().decode([CodexSessionTarget].self, from: data) else {
            return
        }
        let enabledSessions = sessions.filter {
            ($0.sourceKind == .codex && codexSourceEnabled)
                || ($0.sourceKind == .claudeCode && claudeCodeSourceEnabled)
        }
        attachedTargets = Dictionary(uniqueKeysWithValues: enabledSessions.map { ($0.id, $0) })
    }

    private func loadAttachedSessionHistory() {
        guard let externalSessionID = attachedCodexSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !externalSessionID.isEmpty else {
            attachedSessionHistory = []
            return
        }

        do {
            attachedSessionHistory = try store
                .recentCards(forExternalSessionID: externalSessionID, limit: 15)
                .filter { $0.status == .heard }
        } catch {
            attachedSessionHistory = []
            intakeStatus = "Session history load failed: \(error.localizedDescription)"
        }
    }

    private func migrateAutomationAttachmentIfNeeded(in snapshot: CodexSessionCatalogSnapshot, updateStatus: Bool) -> Bool {
        guard let attachedCodexSessionID,
              let automation = snapshot.automations.first(where: { $0.id == attachedCodexSessionID }) else {
            return false
        }

        if let activeRun = latestActiveSession(matching: automation, in: snapshot.activeSessions) {
            self.attachedCodexSessionID = activeRun.id
            synchronizeSessionContextFocus()
            if updateStatus {
                intakeStatus = "Moved automation focus to active Codex session \(activeRun.displayTitle)."
            }
        } else {
            self.attachedCodexSessionID = nil
            synchronizeSessionContextFocus()
            if updateStatus {
                intakeStatus = "\(automation.displayTitle) is a schedule, not a live session. Open its Codex run to attach."
            }
        }
        return true
    }

    private func latestActiveSession(matching automation: CodexSessionTarget, in sessions: [CodexSessionTarget]) -> CodexSessionTarget? {
        sessions.first {
            $0.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(automation.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
    }

    private static func uniqueCodexTargets(_ targets: [CodexSessionTarget]) -> [CodexSessionTarget] {
        var seen = Set<String>()
        return targets.filter { target in
            seen.insert(target.id).inserted
        }
    }
}
