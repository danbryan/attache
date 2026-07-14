import AppKit
import Combine
import AttacheCore
import Foundation

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
    let isExplicitlyFocused: Bool

    var agentSendTarget: AgentSendTarget? {
        guard isExplicitlyFocused else { return nil }
        return AgentSendTarget(
            sessionID: target.id,
            sourceKind: target.sourceKind.rawValue,
            displayTitle: target.displayTitle,
            workingDirectory: workingDirectory
        )
    }
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

enum CompanionHistoryScope: String, CaseIterable, Identifiable {
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
    @Published private(set) var isGeneratingFollowUpAnswer: Bool = false
    @Published var liveFollowUpText: String = ""
    @Published var liveFollowUpStatus: String = "Ask Attaché about the current session."
    @Published var liveFollowUpAnswerText: String = ""
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
            defaults.set(conversationFallbackChainEnabled, forKey: CompanionPreferenceKey.conversationFallbackChainEnabled)
        }
    }
    @Published var conversationFallbackChain: [CompanionPresentationProvider] = [] {
        didSet {
            defaults.set(
                conversationFallbackChain.map(\.rawValue),
                forKey: CompanionPreferenceKey.conversationFallbackChainProviders
            )
        }
    }
    private var conversationFallbackState = ConversationFallbackState()
    private var conversationFallbackRetryTimer: Timer?
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

    @Published var voiceInputMode: CompanionVoiceInputMode = .pushToTalk {
        didSet {
            guard voiceInputMode != oldValue else { return }
            defaults.set(voiceInputMode.rawValue, forKey: CompanionPreferenceKey.voiceInputMode)
            applyVoiceInputMode()
        }
    }
    @Published var narrationDetail: CompanionNarrationDetail = .milestones {
        didSet {
            guard narrationDetail != oldValue else { return }
            defaults.set(narrationDetail.rawValue, forKey: CompanionPreferenceKey.narrationDetail)
            codexSessionWatcher.quietPolls = narrationDetail.coalescerQuietPolls
        }
    }
    @Published var microphoneDeviceID: String = "" {
        didSet {
            guard microphoneDeviceID != oldValue else { return }
            defaults.set(microphoneDeviceID, forKey: CompanionPreferenceKey.microphoneDeviceID)
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
                defaults.set(attachedCodexSessionID, forKey: CompanionPreferenceKey.attachedCodexSessionID)
            } else {
                defaults.removeObject(forKey: CompanionPreferenceKey.attachedCodexSessionID)
            }
            // Drop any queued live updates from the previous focus so they don't
            // play against the newly attached session.
            livePlaybackQueue.reset()
            loadAttachedSessionHistory()
        }
    }
    @Published private(set) var attachedSessionHistory: [VoicemailCard] = []
    @Published private(set) var selectedStartProgress: Double = 0
    @Published var visualMode: CompanionVisualMode = .combined {
        didSet { defaults.set(visualMode.rawValue, forKey: CompanionPreferenceKey.visualMode) }
    }
    /// The desktop mini companion window (INF-272).
    @Published var miniCompanionEnabled: Bool = false {
        didSet { defaults.set(miniCompanionEnabled, forKey: CompanionPreferenceKey.miniCompanion) }
    }
    @Published var miniCompanionClickThrough: Bool = false {
        didSet { defaults.set(miniCompanionClickThrough, forKey: CompanionPreferenceKey.miniCompanionClickThrough) }
    }
    /// Install Claude Code's Notification and Stop hooks so the pet's status is
    /// exact (needs-you and done come from Claude Code itself, not a transcript
    /// guess). On by default; toggling off removes only Attaché's hook entries.
    @Published var installClaudeHooks: Bool = true {
        didSet {
            defaults.set(installClaudeHooks, forKey: CompanionPreferenceKey.installClaudeHooks)
            applyClaudeHooks()
        }
    }
    /// Pet delights (INF-273): types-along ships on, the rest are opt-in.
    @Published var petTypesAlong: Bool = true {
        didSet { defaults.set(petTypesAlong, forKey: CompanionPreferenceKey.petTypesAlong) }
    }
    @Published var petRareIdles: Bool = false {
        didSet { defaults.set(petRareIdles, forKey: CompanionPreferenceKey.petRareIdles) }
    }
    @Published var petHoverReaction: Bool = false {
        didSet { defaults.set(petHoverReaction, forKey: CompanionPreferenceKey.petHoverReaction) }
    }
    /// Where the user last parked the focused mote on the session ring
    /// (INF-280); only dragging it writes a new angle.
    @Published var petFocusAngle: Double = BubblesPetChoreography.defaultFocusAngle {
        didSet { defaults.set(petFocusAngle, forKey: CompanionPreferenceKey.petFocusAngle) }
    }
    /// The character in the middle of the ring (INF-283). Volt is the
    /// default (INF-286): it pairs with the robotic default system voice a
    /// fresh install speaks with.
    @Published var petCharacter: BubblesPetCharacter = .robot {
        didSet { defaults.set(petCharacter.rawValue, forKey: CompanionPreferenceKey.petCharacter) }
    }
    /// The shiny easter egg (INF-273): a one-time random roll persisted per
    /// profile, so roughly 1 in 20 installs gets a golden-arc Bubbles. Zero
    /// configuration on purpose; discovery is the point.
    lazy var petShiny: Bool = {
        if defaults.object(forKey: CompanionPreferenceKey.petShinySeed) == nil {
            defaults.set(Int.random(in: 0..<20), forKey: CompanionPreferenceKey.petShinySeed)
        }
        return defaults.integer(forKey: CompanionPreferenceKey.petShinySeed) == 0
    }()
    @Published var visualSymmetry: CompanionVisualSymmetry = .mirrored {
        didSet { defaults.set(visualSymmetry.rawValue, forKey: CompanionPreferenceKey.visualSymmetry) }
    }
    @Published var idleBrand: CompanionIdleBrand = .monogram {
        didSet { defaults.set(idleBrand.rawValue, forKey: CompanionPreferenceKey.idleBrand) }
    }
    @Published var idleCustomText: String = "" {
        didSet { defaults.set(idleCustomText, forKey: CompanionPreferenceKey.idleCustomText) }
    }
    @Published var idleImage: NSImage?

    private static var idleImageURL: URL {
        CompanionAppSupport.supportDirectory().appendingPathComponent("idle-image")
    }

    /// Copies the picked image into app support so the idle screen survives
    /// the original file moving, then loads it.
    func setIdleImage(from url: URL) {
        guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return }
        try? data.write(to: Self.idleImageURL, options: .atomic)
        idleImage = NSImage(data: data)
        idleBrand = .customImage
    }

    func loadIdleImageIfNeeded() {
        guard idleImage == nil,
              let data = try? Data(contentsOf: Self.idleImageURL) else { return }
        idleImage = NSImage(data: data)
    }
    @Published var theme: CompanionTheme = .macOS {
        didSet { defaults.set(theme.rawValue, forKey: CompanionPreferenceKey.theme) }
    }
    @Published var appearanceMode: CompanionAppearanceMode = .system {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: CompanionPreferenceKey.appearanceMode)
            applyAppearance()
        }
    }
    @Published var customThemes: [CompanionThemeSpec] = []
    @Published var activeCustomThemeID: String? {
        didSet { defaults.set(activeCustomThemeID, forKey: CompanionPreferenceKey.customThemeID) }
    }
    private var customThemePersistWork: DispatchWorkItem?
    @Published var surfaceOpacity: Double = 1.0 {
        didSet {
            let clamped = min(1.0, max(0.35, surfaceOpacity))
            if surfaceOpacity != clamped {
                surfaceOpacity = clamped
                return
            }
            defaults.set(surfaceOpacity, forKey: CompanionPreferenceKey.surfaceOpacity)
        }
    }
    @Published var brightnessLevel: Int = 1 {
        didSet { defaults.set(brightnessLevel, forKey: CompanionPreferenceKey.brightnessLevel) }
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
            defaults.set(uiTextScale, forKey: CompanionPreferenceKey.uiTextScale)
        }
    }
    @Published var visualIntensity: Double = 1.0 {
        didSet { defaults.set(visualIntensity, forKey: CompanionPreferenceKey.visualIntensity) }
    }
    @Published var seekStepSeconds: Int = 5 {
        didSet {
            let clamped = min(30, max(2, seekStepSeconds))
            if seekStepSeconds != clamped {
                seekStepSeconds = clamped
                return
            }
            defaults.set(seekStepSeconds, forKey: CompanionPreferenceKey.seekStepSeconds)
            mediaRemote.setSkipInterval(seconds: seekStepSeconds)
        }
    }
    @Published var captionsEnabled: Bool = true {
        didSet { defaults.set(captionsEnabled, forKey: CompanionPreferenceKey.captionsEnabled) }
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
            defaults.set(captionFontSize, forKey: CompanionPreferenceKey.captionFontSize)
        }
    }
    @Published var captionLineCount: Int = 2 {
        didSet {
            let clamped = min(Self.captionLineRange.upperBound, max(Self.captionLineRange.lowerBound, captionLineCount))
            if captionLineCount != clamped {
                captionLineCount = clamped
                return
            }
            defaults.set(captionLineCount, forKey: CompanionPreferenceKey.captionLineCount)
        }
    }
    @Published var audioCacheRetentionMinutes: Int = 24 * 60 {
        didSet {
            let preset = Self.nearestAudioCacheRetentionOption(to: audioCacheRetentionMinutes).minutes
            if audioCacheRetentionMinutes != preset {
                audioCacheRetentionMinutes = preset
                return
            }
            defaults.set(audioCacheRetentionMinutes, forKey: CompanionPreferenceKey.audioCacheRetentionMinutes)
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
    @Published var lowLatencyCaptions: Bool = true {
        didSet {
            defaults.set(lowLatencyCaptions, forKey: CompanionPreferenceKey.lowLatencyCaptions)
            applyMicConfiguration()
        }
    }
    @Published var spokenLanguage: String = "en" {
        didSet {
            defaults.set(spokenLanguage, forKey: CompanionPreferenceKey.spokenLanguage)
            applyMicConfiguration()
        }
    }
    @Published var onDeviceOnly: Bool = false {
        didSet {
            defaults.set(onDeviceOnly, forKey: CompanionPreferenceKey.onDeviceOnly)
            applyMicConfiguration()
        }
    }
    /// When on (Voicemail mode), nothing auto-speaks: every update queues silently
    /// as an unread voicemail and posts a notification so you can play it later.
    @Published var voicemailMode: Bool = true {
        didSet {
            guard voicemailMode != oldValue else { return }
            defaults.set(voicemailMode, forKey: CompanionPreferenceKey.voicemailMode)
            if voicemailMode {
                CompanionNotifier.shared.requestAuthorizationIfUndetermined()
            }
        }
    }
    /// Ambient home: when on, the chrome (dock, banner, history) fades while the
    /// pointer is still and wakes on movement. Off keeps everything always visible.
    @Published var autoHideControls: Bool = true {
        didSet { defaults.set(autoHideControls, forKey: CompanionPreferenceKey.autoHideControls) }
    }
    @Published var autoHideDelaySeconds: Double = 2.5 {
        didSet { defaults.set(autoHideDelaySeconds, forKey: CompanionPreferenceKey.autoHideDelaySeconds) }
    }
    @Published var showPersonalitySwitcher: Bool = true {
        didSet { defaults.set(showPersonalitySwitcher, forKey: CompanionPreferenceKey.showPersonalitySwitcher) }
    }
    @Published var showPersonalityNameInDock: Bool = false {
        didSet { defaults.set(showPersonalityNameInDock, forKey: CompanionPreferenceKey.showPersonalityNameInDock) }
    }
    /// Attention state per watched session (INF-179). Only sessions with
    /// something notable appear; quiet sessions are absent.
    @Published var sessionAttention: [String: SessionAttentionState] = [:]
    @Published var notifyScope: CompanionNotifyScope = .allUpdates {
        didSet { defaults.set(notifyScope.rawValue, forKey: CompanionPreferenceKey.notifyScope) }
    }
    @Published var showInMenuBar: Bool = true {
        didSet { defaults.set(showInMenuBar, forKey: CompanionPreferenceKey.showInMenuBar) }
    }
    @Published var showTips: Bool = true {
        didSet { defaults.set(showTips, forKey: CompanionPreferenceKey.showTips) }
    }
    private let tipEngine = CompanionTipEngine()
    @Published var playbackSpeed: Double = 1.0 {
        didSet {
            let clamped = min(1.6, max(0.8, playbackSpeed))
            if clamped != playbackSpeed { playbackSpeed = clamped; return }
            defaults.set(clamped, forKey: CompanionPreferenceKey.playbackSpeed)
            playback.playbackRate = Float(clamped)
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
            defaults.set(showActivityInsights, forKey: CompanionPreferenceKey.showActivityInsights)
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
        didSet { defaults.set(captionSyncOffsetMs, forKey: CompanionPreferenceKey.captionSyncOffsetMs) }
    }
    @Published var presentationLLMEnabled: Bool = true {
        didSet {
            defaults.set(presentationLLMEnabled, forKey: CompanionPreferenceKey.presentationLLMEnabled)
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
    @Published var presentationProvider: CompanionPresentationProvider = .ollama {
        didSet {
            let key = isApplyingConversationRecoveryOverride
                ? CompanionPreferenceKey.presentationLLMRoleKey(.conversation, .provider)
                : CompanionPreferenceKey.presentationLLMProvider
            defaults.set(presentationProvider.rawValue, forKey: key)
            refreshPresentationStatus()
        }
    }
    @Published var presentationBaseURL: String = CompanionPresentationProvider.ollama.defaultBaseURL {
        didSet {
            let key = isApplyingConversationRecoveryOverride
                ? CompanionPreferenceKey.presentationLLMRoleKey(.conversation, .baseURL)
                : CompanionPreferenceKey.presentationLLMBaseURL
            defaults.set(presentationBaseURL, forKey: key)
            refreshPresentationStatus()
        }
    }
    @Published var presentationModel: String = CompanionPresentationProvider.ollama.defaultModel {
        didSet {
            let key = isApplyingConversationRecoveryOverride
                ? CompanionPreferenceKey.presentationLLMRoleKey(.conversation, .model)
                : CompanionPreferenceKey.presentationLLMModel
            defaults.set(presentationModel, forKey: key)
            refreshPresentationStatus()
        }
    }
    @Published var presentationReasoningEffort: String = CompanionPresentationProvider.ollama.defaultReasoningEffort {
        didSet {
            let key = isApplyingConversationRecoveryOverride
                ? CompanionPreferenceKey.presentationLLMRoleKey(.conversation, .reasoningEffort)
                : CompanionPreferenceKey.presentationReasoningEffort
            defaults.set(presentationReasoningEffort, forKey: key)
            refreshPresentationStatus()
        }
    }
    @Published var presentationServiceTier: String = "default" {
        didSet {
            let key = isApplyingConversationRecoveryOverride
                ? CompanionPreferenceKey.presentationLLMRoleKey(.conversation, .serviceTier)
                : CompanionPreferenceKey.presentationServiceTier
            defaults.set(presentationServiceTier, forKey: key)
            refreshPresentationStatus()
        }
    }
    @Published var presentationAPIKey: String = ""
    @Published var presentationAPIKeySecretRef: String = "" {
        didSet {
            let key = isApplyingConversationRecoveryOverride
                ? CompanionPreferenceKey.presentationLLMRoleKey(.conversation, .apiKeySecretRef)
                : CompanionPreferenceKey.presentationLLMAPIKeySecretRef
            defaults.set(presentationAPIKeySecretRef, forKey: key)
            refreshPresentationStatus()
        }
    }
    @Published private(set) var presentationModelOptions: [CompanionPresentationModelOption] = []
    @Published private(set) var presentationModelDiscoveryStatus: String = "Model discovery not checked"
    @Published private(set) var presentationStatus: String = "Presentation LLM not checked"
    // MARK: Per-role model overrides (Settings > Model > Advanced disclosure, INF-253/D3)
    //
    // A role missing from `roleModelProvider` means "Use main model": it falls
    // back to the main provider/model above, exactly like
    // `CompanionPresentationSettings.load(role:)` already resolves an unset
    // per-role key (D2/INF-247). Populated once at launch by
    // `loadRoleModelOverrides()` and mutated only through `selectRoleProvider`,
    // `selectRoleModel`/`selectRoleModelID`, and `setRoleReasoningEffort`/
    // `setRoleServiceTier` below, which keep these dictionaries and the
    // matching `presentationLLMRoleKey` defaults entries in sync.
    @Published private(set) var roleModelProvider: [ModelRole: CompanionPresentationProvider] = [:]
    @Published private(set) var roleModelID: [ModelRole: String] = [:]
    @Published private(set) var roleReasoningEffort: [ModelRole: String] = [:]
    @Published private(set) var roleServiceTier: [ModelRole: String] = [:]
    @Published private(set) var roleModelOptions: [ModelRole: [CompanionPresentationModelOption]] = [:]
    @Published private(set) var roleModelDiscoveryStatus: [ModelRole: String] = [:]
    @Published private(set) var companionMemoryStatus: String = "Memory not checked"
    @Published private(set) var speechVoiceOptions: [CompanionVoiceOption] = []
    @Published private(set) var elevenLabsVoiceOptions: [RemoteVoiceOption] = []
    @Published private(set) var xaiVoiceOptions: [RemoteVoiceOption] = []
    @Published private(set) var openaiVoiceOptions: [RemoteVoiceOption] = []
    @Published private(set) var voiceProviderStatus: String = "Voice provider not checked"
    @Published var speechProvider: CompanionSpeechProvider = .system {
        didSet {
            defaults.set(speechProvider.rawValue, forKey: CompanionPreferenceKey.speechProvider)
            applySpeechConfiguration()
        }
    }
    @Published var speechVoiceIdentifier: String? {
        didSet {
            if let speechVoiceIdentifier {
                defaults.set(speechVoiceIdentifier, forKey: CompanionPreferenceKey.speechVoiceIdentifier)
            } else {
                defaults.set(Self.systemVoicePreference, forKey: CompanionPreferenceKey.speechVoiceIdentifier)
            }
            applySpeechConfiguration()
        }
    }
    @Published var elevenLabsAPIKey: String = "" {
        didSet { applySpeechConfiguration() }
    }
    @Published var elevenLabsVoiceID: String = "" {
        didSet {
            defaults.set(elevenLabsVoiceID, forKey: CompanionPreferenceKey.elevenLabsVoiceID)
            applySpeechConfiguration()
        }
    }
    @Published var elevenLabsVoiceName: String = "" {
        didSet { defaults.set(elevenLabsVoiceName, forKey: CompanionPreferenceKey.elevenLabsVoiceName) }
    }
    @Published var elevenLabsModelID: String = "eleven_flash_v2_5" {
        didSet {
            defaults.set(elevenLabsModelID, forKey: CompanionPreferenceKey.elevenLabsModelID)
            applySpeechConfiguration()
        }
    }
    @Published var elevenLabsOutputFormat: String = "mp3_44100_128" {
        didSet {
            defaults.set(elevenLabsOutputFormat, forKey: CompanionPreferenceKey.elevenLabsOutputFormat)
            applySpeechConfiguration()
        }
    }
    @Published var xaiAPIKey: String = "" {
        didSet { applySpeechConfiguration() }
    }
    @Published var xaiVoiceID: String = "" {
        didSet {
            defaults.set(xaiVoiceID, forKey: CompanionPreferenceKey.xaiVoiceID)
            applySpeechConfiguration()
        }
    }
    @Published var xaiVoiceName: String = "" {
        didSet { defaults.set(xaiVoiceName, forKey: CompanionPreferenceKey.xaiVoiceName) }
    }
    @Published var xaiBaseURL: String = "https://api.x.ai/v1" {
        didSet {
            defaults.set(xaiBaseURL, forKey: CompanionPreferenceKey.xaiBaseURL)
            applySpeechConfiguration()
        }
    }
    @Published var xaiLanguage: String = "en" {
        didSet {
            defaults.set(xaiLanguage, forKey: CompanionPreferenceKey.xaiLanguage)
            applySpeechConfiguration()
        }
    }
    @Published var openaiVoiceAPIKey: String = "" {
        didSet { applySpeechConfiguration() }
    }
    @Published var openaiVoiceID: String = "" {
        didSet {
            defaults.set(openaiVoiceID, forKey: CompanionPreferenceKey.openaiVoiceID)
            applySpeechConfiguration()
        }
    }
    @Published var openaiVoiceName: String = "" {
        didSet { defaults.set(openaiVoiceName, forKey: CompanionPreferenceKey.openaiVoiceName) }
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
    // @Published (rather than a plain var) so refreshCallPhase()'s Combine
    // subscription (setupConversationObservers()) picks up every transition,
    // including the ones driven from playback callbacks in init rather than
    // from a mutating method here.
    @Published private var expectingReplyAudio = false
    /// Tokens for in-flight narration composition (INF-264 follow-up): the
    /// LLM call that writes a watched session's spoken recap
    /// (`prepareAndPersist`, `CompanionPresentationService.prepare`) runs
    /// entirely before `playback.isBusy` ever goes true, so without a signal
    /// of its own, a Tell Agent reply's recap-composing window had nothing
    /// to show once `.sendDelivered` moved past its own emphasis window.
    /// Keyed tokens rather than a plain counter or a single session ID so
    /// overlapping compositions across different watched sessions can't
    /// clobber each other's start/end bookkeeping; the value is the event's
    /// source raw value so `companionActivity` can attribute the responding
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
    /// The one semantic state every companion renderer consumes (INF-268).
    /// Refreshed at semantic rate through `refreshCompanionActivity()`'s
    /// choke point; renderers compose live audio per frame via
    /// `with(audio:)` from the `PlaybackTimeline` they already observe.
    @Published private(set) var companionActivity: CompanionActivityState = .initial
    /// Debug override driven by the activity simulator panel
    /// (`ATTACHE_ACTIVITY_SIMULATOR=1`); nil means live derivation.
    @Published var simulatedActivity: CompanionActivityState? {
        didSet { refreshCompanionActivity() }
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
    private let activityDamper = CompanionActivityDamper()
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
    /// PostCompact. Only the focused session's value drives the pet's squish.
    private var compactingSince: [String: Date] = [:]
    /// Live sub-agent counts per watched session (INF-275), from the
    /// watcher's transcript assessment.
    @Published private var subAgentCounts: [String: Int] = [:]
    /// The latest one-shot beat for renderers (celebrate, card pop, drowsy).
    /// Renderers queue and play these; publishing the next one never cancels
    /// an animation already running.
    @Published private(set) var companionMoment: CompanionActivityMoment?
    /// How long a watcher phrase stays "fresh" enough to read as live tool
    /// activity. Tighter than the phrase's own 36s display lifetime so the
    /// pet stops miming tools soon after the burst ends; INF-271 tunes this.
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
    private static let sessionIndexURL = CompanionAppSupport.supportDirectory().appendingPathComponent("SessionIndex.json")
    private var sessionIndexer = SessionIndexer(cacheURL: AppModel.sessionIndexURL, scanners: [])
    private let sessionIndexQueue = DispatchQueue(label: "com.bryanlabs.attache.sessionindex")
    @Published private(set) var sessionRecords: [SessionRecord] = []
    @Published private(set) var sessionIndexRevision = 0   // bumps on any record change, incl. new tags
    @Published private(set) var isIndexingSessions = false
    @Published private(set) var isTaggingSessions = false
    @Published private(set) var sessionRenames: [String: String] = [:]
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
        didSet { defaults.set(agentInstructionSendPolicy.rawValue, forKey: CompanionPreferenceKey.agentInstructionSendPolicy) }
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
    private let presentationService: CompanionPresentationService
    private let companionPersonaStore: CompanionPersonaStore
    private let companionMemoryStore: CompanionMemoryStore
    private var codexSessionRefreshTimer: Timer?
    private var followUpAnswerRequestID: UUID?
    private var liveFollowUpAnswerRequestID: UUID?
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
    @Published var ollamaBaseURL: String = CompanionPresentationProvider.ollama.defaultBaseURL {
        didSet { defaults.set(ollamaBaseURL, forKey: CompanionPreferenceKey.ollamaBaseURL) }
    }
    @Published var lmStudioBaseURL: String = CompanionPresentationProvider.lmStudio.defaultBaseURL {
        didSet { defaults.set(lmStudioBaseURL, forKey: CompanionPreferenceKey.lmStudioBaseURL) }
    }
    @Published var customBaseURL: String = CompanionPresentationProvider.custom.defaultBaseURL {
        didSet {
            defaults.set(customBaseURL, forKey: CompanionPreferenceKey.customBaseURL)
            applySpeechConfiguration()
        }
    }

    init(store: CardStore? = nil) {
        let environment = ProcessInfo.processInfo.environment
        presentationEnvironment = environment
        presentationService = CompanionPresentationService(environment: environment)
        companionPersonaStore = CompanionPersonaStore(environment: environment)
        companionMemoryStore = CompanionMemoryStore(environment: environment)

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
            loadPreferences()
            refreshMicrophoneDevices()
            loadPersonalities()
            refreshPresentationStatus()
            refreshCodexSessions(updateStatus: false)
            resetLiveFollowUpAnswerStatus()
            _ = try? self.store.pruneArchivedCards()   // bound growth on launch (INF-170)
            reloadCards()
        } catch {
            fatalError("Unable to open \(CompanionAppSupport.appDisplayName) store: \(error.localizedDescription)")
        }

        twoWay = TwoWayCoordinator(
            store: self.store,
            locateSessionFile: { CompanionSessionReader.sessionFileURL(forSessionID: $0) },
            expiryWindow: InstructionReplyEngine.expiryWindow(fromEnvironment: environment)
        )
        if let recoveryMessage = twoWay.startupRecoveryMessage {
            intakeStatus = recoveryMessage
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
        setupCompanionActivityObservers()
        // Screenshot-matrix pose support (INF-244): inert unless
        // ATTACHE_UI_TEST_FORCE_LISTENING=1 rides alongside ATTACHE_UI_TEST=1
        // (see MicTranscriptController.shouldForceListeningForPose). Applied
        // right after setupConversationObservers() subscribes to
        // micTranscript.$isListening so the pose still reaches the first
        // callPhase refresh.
        micTranscript.applyForcedListeningPoseIfRequested(environment: environment)
        rebuildSessionIndexer()
        sessionRecords = filteredEnabledRecords(sessionIndexer.allRecords)
        refreshSessionIndex()
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
        updateCodexWatcher()
        startCodexSessionRefreshTimer()
    }

    deinit {
        codexSessionRefreshTimer?.invalidate()
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

    /// The session a free-form "Talk" conversation is about: the locked session
    /// if any, otherwise the most recent active session. Lets you talk to the
    /// companion any time, not only when locked on.
    var talkContextSession: CodexSessionTarget? {
        if let attached = attachedCodexSession { return attached }
        if let codex = codexSessions.first { return codex }
        // Fall back to the most recent enabled session across sources, so a
        // Claude-only user with nothing attached can still talk (INF-168).
        if let record = sessionRecords.filter({ !$0.archived }).max(by: { $0.updatedAt < $1.updatedAt }) {
            return target(for: record)
        }
        return nil
    }

    /// The call's immutable context while live. It may be a read-only recent
    /// session when nothing was focused, but only an explicitly focused snapshot
    /// can produce an agent-send target.
    var conversationContextSession: CodexSessionTarget? {
        if conversationActive || isConversing || pendingAssistantReply != nil {
            return conversationTargetSnapshot?.target
        }
        return talkContextSession
    }

    private func captureConversationTargetSnapshot() -> ConversationTargetSnapshot? {
        if let focused = attachedCodexSession {
            return ConversationTargetSnapshot(
                target: focused,
                workingDirectory: workingDirectory(for: focused.id),
                isExplicitlyFocused: true
            )
        }
        guard let fallback = talkContextSession else { return nil }
        return ConversationTargetSnapshot(
            target: fallback,
            workingDirectory: workingDirectory(for: fallback.id),
            isExplicitlyFocused: false
        )
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
            if let fallbackIdentifier = CompanionVoiceCatalog.fileExportFallbackVoiceID(),
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
        return CompanionPresentationModelService.fallbackReasoningEfforts(
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

    var selectedPresentationServiceTierOptions: [CompanionPresentationServiceTierOption] {
        let options: [CompanionPresentationServiceTierOption]
        if let option = presentationModelOptions.first(where: { $0.id == presentationModel }) {
            options = option.serviceTiers
        } else {
            options = CompanionPresentationModelService.fallbackServiceTierOptions(
                provider: presentationProvider,
                modelID: presentationModel
            )
        }
        guard !options.isEmpty else { return [] }
        if options.contains(where: { $0.id == "default" }) {
            return options
        }
        return [CompanionPresentationServiceTierOption(
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
            if let cardID {
                selectedCardID = cardID
            } else if selectedCardID == nil || !cards.contains(where: { $0.id == selectedCardID }) {
                selectedCardID = cards.first?.id
            }
            loadAttachedSessionHistory()
            prepareUnreadVoicemailAudio()
        } catch {
            intakeStatus = "Storage read failed: \(error.localizedDescription)"
        }
    }

    @Published var newlyDownloadedVoice: CompanionVoiceOption?

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
                  let fresh = CompanionVoiceCatalog.freshOptions() else { return }
            DispatchQueue.main.async {
                self.newlyDownloadedVoice = CompanionVoiceCatalog.newlyAvailableVoice(
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
        defaults.set(resumeStep, forKey: CompanionPreferenceKey.onboardingResumeStep)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// The persisted resume step, cleared on read.
    func takeOnboardingResumeStep() -> Int? {
        guard defaults.object(forKey: CompanionPreferenceKey.onboardingResumeStep) != nil else { return nil }
        let step = defaults.integer(forKey: CompanionPreferenceKey.onboardingResumeStep)
        defaults.removeObject(forKey: CompanionPreferenceKey.onboardingResumeStep)
        return step
    }

    func completeOnboarding() {
        defaults.set(true, forKey: CompanionPreferenceKey.onboardingCompleted)
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
                    companionMoment = CompanionActivityMoment(
                        kind: .needsYou, agent: agentIdentity(forSessionID: sessionID), at: Date()
                    )
                }
            }
            persistNeedsYouNotice(event: notice, line: event.text)
            return
        }
        // Exact turn completion from Claude Code's Stop hook. The pet's finished
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
                refreshCompanionActivity()
            }
            return
        }
        if event.eventType == "compact_end" {
            if let sid = event.externalSessionID {
                compactingSince.removeValue(forKey: sid)
                refreshCompanionActivity()
            }
            return
        }
        // One-shot pet moments from the other lifecycle hooks (errored, greet,
        // farewell, configuring).
        if let momentKind = Self.momentKind(forEventType: event.eventType) {
            let agent = event.externalSessionID.map { agentIdentity(forSessionID: $0) } ?? .none
            companionMoment = CompanionActivityMoment(kind: momentKind, agent: agent, at: Date())
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
            companionMoment = CompanionActivityMoment(
                kind: .needsYou, agent: agentIdentity(forSessionID: sessionID), at: Date()
            )
        } else if !state.needsUser, wasNeeding {
            resolveNeedsYouNotices(sessionID: sessionID)
        }
        // One-shot beats for the pet (INF-271): a finished turn celebrates,
        // a still-pinned session going stale yawns. Transitions only, so a
        // first classification after attach never fires a stale celebration.
        if previous == .active, state == .turnComplete {
            companionMoment = CompanionActivityMoment(
                kind: .celebrate, agent: agentIdentity(forSessionID: sessionID), at: Date()
            )
        } else if state == .quiet, previous != nil, attachedTargets[sessionID] != nil {
            companionMoment = CompanionActivityMoment(
                kind: .drowsy, agent: agentIdentity(forSessionID: sessionID), at: Date()
            )
        }
        if let moment = companionMoment, moment.at.timeIntervalSinceNow > -1 {
            AttacheLog.watcher.info("companion moment \(moment.kind.rawValue, privacy: .public) for \(moment.agent.rawValue, privacy: .public) (attention \(String(describing: previous), privacy: .public) -> \(String(describing: state), privacy: .public))")
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
                CompanionNotifier.shared.post(card: card, kind: .needsYou)
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
              defaults.bool(forKey: CompanionPreferenceKey.onboardingCompleted),
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
        let presented: NormalizedEvent = await withCheckedContinuation { continuation in
            presentationService.prepare(event, personality: personality) { presentedEvent in
                continuation.resume(returning: presentedEvent)
            }
        }
        // persist() mutates observed @Published state (the card list, playback
        // queue, intake status). It runs from a background Task here, so it must
        // hop to the main actor: mutating @Published off-main makes SwiftUI flush
        // a transaction synchronously and re-enter body, overflowing the stack.
        await MainActor.run {
            composingNarrationTokens.removeValue(forKey: token)
            persist(presented)
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
                companionMoment = CompanionActivityMoment(
                    kind: .cardArrived,
                    agent: CompanionAgentIdentity(sourceKindRawValue: card.sourceKind),
                    at: Date()
                )
                if voicemailMode, notifyScope.allowsRecaps {
                    CompanionNotifier.shared.post(card: card, kind: .recap)
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

    /// Right-click affordance on the mini companion (INF-272): replay the
    /// newest update without opening the main window.
    func replayLastUpdate() {
        guard let card = cards.max(by: { $0.createdAt < $1.createdAt }) else { return }
        playInboxCard(card)
    }

    /// Hear an "another take" of a card in a different personality's voice
    /// (INF-299). Switches to the target personality (its voice and pet, with a
    /// greeting), asks the model for its own spin on the original, then files and
    /// plays a new card linked back to the original.
    func anotherTake(card: VoicemailCard, targetPersonalityID: String) {
        guard let target = personalities.first(where: { $0.id == targetPersonalityID }) else { return }
        let priorName = card.producedByPersonalityName ?? activePersonality?.name ?? "Attaché"
        selectPersonality(targetPersonalityID)
        intakeStatus = "Getting another take from \(target.name)…"
        presentationService.prepareAnotherTake(
            original: card,
            targetPersonality: target,
            priorPersonalityName: priorName
        ) { [weak self] presented in
            guard let self else { return }
            guard let presented else {
                self.intakeStatus = "Another take needs a presentation model. Set one up in Settings."
                return
            }
            do {
                let takeCard = try self.store.insertEvent(presented)
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
        playback.play(card, startTimeMs: startTimeMs)
    }

    func replaySelected() {
        guard let card = selectedCard else { return }
        selectedStartProgress = 0
        playback.replay(card)
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

    func historyCards(for scope: CompanionHistoryScope) -> [VoicemailCard] {
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

    func historyCount(for scope: CompanionHistoryScope) -> Int {
        historyCards(for: scope).count
    }

    /// Everything sent to an agent, newest first, for the History palette's
    /// Sent tab. Backed by `TwoWayCoordinator.log`, which already mirrors
    /// `InstructionReplyEngine`'s persisted audit log after every state
    /// transition, so no separate storage or refresh path is needed here.
    func sentInstructions(for scope: CompanionHistoryScope) -> [Instruction] {
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

    func sentInstructionsCount(for scope: CompanionHistoryScope) -> Int {
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

    func playHistoryCard(_ card: VoicemailCard) {
        selectedCardID = card.id
        selectedStartProgress = 0
        playback.replay(card)
        intakeStatus = "Replaying history for \(card.sessionTitle ?? card.externalSessionID ?? "attached session")."
    }

    func playInboxCard(_ card: VoicemailCard, fromCatchUp: Bool = false) {
        if !fromCatchUp {
            inboxCatchUpQueue.removeAll()
        }
        selectedCardID = card.id
        selectedStartProgress = 0
        playback.replay(card)
        intakeStatus = "Playing voicemail for \(card.sessionTitle ?? card.externalSessionID ?? "General")."
    }

    private func prepareUnreadVoicemailAudio() {
        guard audioCacheRetentionMinutes > 0 else { return }
        for card in unreadCards.prefix(20) {
            playback.prepareAudioCache(for: card)
        }
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
        let profilePrompt = firstNonEmptyPrompt(
            personality?.prompt,
            companionPersonaStore.loadSnapshot().prompt,
            CompanionPersonality.defaultProfilePrompt
        )
        let memoryContext = companionMemoryStore.loadSnapshot().context
        let spokenLanguageName = CompanionPresentationService.spokenLanguageName(defaults: defaults)
        let prompt = CompanionPersonality.recapPrompt(
            items: summarized.map { recapItem(for: $0) },
            profilePrompt: profilePrompt,
            memoryContext: memoryContext,
            spokenLanguageName: spokenLanguageName
        )
        let system = prompt.messages.first(where: { $0.role == "system" })?.content ?? ""
        let user = prompt.messages.first(where: { $0.role == "user" })?.content ?? ""

        intakeStatus = "Writing your recap…"

        Task { [weak self] in
            guard let self else { return }
            do {
                let recapText = try await self.presentationService.complete(system: system, user: user, role: .recap)
                // persist/play mutate @Published state and the store, so hop back
                // to the main actor before touching either (mutating observed
                // state off-main re-enters SwiftUI's body and overflows the stack).
                await MainActor.run {
                    let trimmed = CompanionPersonality.stripDashes(recapText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                    guard !trimmed.isEmpty else {
                        // The LLM was configured but returned nothing usable: fall
                        // back to the deterministic digest and leave the inbox as
                        // is. Not a classified failure (no thrown error), so no
                        // recovery is offered, matching prior behavior exactly.
                        self.playback.preview(self.inboxDigestText(for: summarized))
                        self.intakeStatus = "Recap unavailable; played the quick digest instead."
                        return
                    }
                    self.deliverRecap(trimmed, summarizing: summarized, personality: personality)
                }
            } catch {
                // The deterministic fallback itself is unchanged (INF-254): still
                // play the digest. This only ADDS a recovery affordance alongside
                // it when the failure is structurally recoverable.
                await MainActor.run {
                    self.playback.preview(self.inboxDigestText(for: summarized))
                    self.intakeStatus = "Recap unavailable; played the quick digest instead."
                    let presentationError = error as? CompanionPresentationError
                    let recovery = ConversationRecovery.classify(
                        errorMessage: error.localizedDescription,
                        failedPrompt: "",
                        httpStatus: presentationError?.httpStatus,
                        urlErrorCode: presentationError?.urlErrorCode ?? (error as? URLError)?.code,
                        isCLIProvider: self.recapEffectiveProvider.isCLI
                    )
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
        personality: Personality?
    ) {
        var metadata: [String: String] = [
            "attache_recap": "1",
            "companion_history_kind": "recap",
            "companion_summary": Self.conversationReplySummary(from: recapText),
            "companion_spoken_text": recapText,
            "companion_presentation_strategy": "companion-inbox-recap"
        ]
        if let personality {
            metadata["companion_personality_id"] = personality.id
            metadata["companion_personality_name"] = personality.name
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
            eventType: "companion.inbox.recap",
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
            playback.play(recapCard)
            intakeStatus = "Playing your recap of \(cards.count) update\(cards.count == 1 ? "" : "s")."
        } catch {
            // Persisting failed: still give the user something by speaking the
            // recap text, and leave the inbox untouched.
            playback.preview(recapText)
            intakeStatus = "Played the recap but could not save it: \(error.localizedDescription)"
        }
    }

    private func recapItem(for card: VoicemailCard) -> CompanionPersonality.RecapItem {
        CompanionPersonality.RecapItem(
            sessionTitle: displaySessionTitle(forCard: card) ?? card.sourceDisplayName,
            summary: card.summary,
            spokenText: card.spokenText,
            needsDecision: card.needsDecision
        )
    }

    private func firstNonEmptyPrompt(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return CompanionPersonality.defaultProfilePrompt
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
            conversationDestination = .attache
            conversationTargetSnapshot = captureConversationTargetSnapshot()
            // The auto-fallback chain is sticky for a call, never across
            // calls (INF-258/D5 spec item 3): a fresh call always starts back
            // on the primary/configured provider.
            conversationFallbackState.reset()
        }
        conversationActive = true
        if conversationStatus.isEmpty {
            conversationStatus = conversationTargetSnapshot == nil
                ? "No session attached — I can still chat."
                : "Talking about \(conversationTargetSnapshot?.target.displayTitle ?? "this session")."
        }
        if voiceInputMode == .alwaysOn {
            beginConversationDictation()
        }
    }

    func endConversation() {
        conversationActive = false
        silenceTimer?.invalidate(); silenceTimer = nil
        endConversationWait()
        conversationFallbackRetryTimer?.invalidate()
        conversationFallbackRetryTimer = nil
        conversationFallbackAnnouncement = nil
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
        guard !trimmed.isEmpty, !isAwaitingReply else { return }

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
    private func performConversationRequest(_ trimmed: String) {
        let context = conversationTargetSnapshot
        let messages = buildConversationMessages(context: context)
        let sessionID = context?.target.id
        let workingDirectory = context?.workingDirectory
        let agentTarget = context?.agentSendTarget
        let allowAgentInstructionTool = agentTarget != nil
        // Sticky for the rest of the call (INF-258/D5): once a fallback is
        // active, every subsequent turn in this call keeps using it, not just
        // the one retry that triggered it.
        let fallbackProvider = conversationFallbackState.activeProvider
        let attemptedProvider = fallbackProvider ?? effectiveRecoveryProvider(for: .conversation)
        let settingsOverride = fallbackProvider.map(conversationFallbackSettings(for:))

        presentationService.converse(
            messages: messages,
            allowAgentInstructionTool: allowAgentInstructionTool,
            settingsOverride: settingsOverride,
            executeTool: { [weak self] name, arguments in
                if name == "rename_session" {
                    return await self?.applyRenameTool(arguments: arguments, sessionID: sessionID)
                        ?? "There's no attached session to rename."
                }
                if name == "stage_agent_instruction" {
                    return await self?.applyStageAgentInstructionTool(
                        arguments: arguments,
                        target: agentTarget,
                        sourceUtterance: trimmed
                    )
                        ?? "There's no attached session to send to."
                }
                return Self.executeConversationTool(
                    name: name,
                    arguments: arguments,
                    sessionID: sessionID,
                    workingDirectory: workingDirectory
                )
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.isConversing = false
                self.endConversationWait()
                switch result {
                case .success(let reply):
                    self.surfaceConversationReply(reply.text, toolCallLost: reply.toolCallLost)
                case .failure(let error):
                    self.handleConversationFailure(error, failedPrompt: trimmed, attemptedProvider: attemptedProvider)
                }
            }
        )
    }

    /// Classifies a failed conversation attempt and either (a) transparently
    /// retries on the next configured-and-consented fallback provider
    /// (INF-258/D5, only while the toggle is on and no fallback is active yet
    /// this call), or (b) falls through to the existing manual Switch model /
    /// Retry recovery, unchanged from before this feature existed.
    private func handleConversationFailure(
        _ error: Error,
        failedPrompt: String,
        attemptedProvider: CompanionPresentationProvider
    ) {
        let errorMessage = error.localizedDescription
        let presentationError = error as? CompanionPresentationError
        let httpStatus = presentationError?.httpStatus
        let urlErrorCode = presentationError?.urlErrorCode ?? (error as? URLError)?.code
        let recovery = ConversationRecovery.classify(
            errorMessage: errorMessage,
            failedPrompt: failedPrompt,
            httpStatus: httpStatus,
            urlErrorCode: urlErrorCode,
            isCLIProvider: attemptedProvider.isCLI
        )

        if let fallback = conversationFallbackState.advance(
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
                retryPrompt: failedPrompt
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

    /// Surfaces the fallback hop in the status line and as one spoken
    /// sentence (spec item 3), then retries `retryPrompt` against `fallback`
    /// once the announcement has had roughly enough time to play, so the
    /// retry's own reply audio doesn't immediately cut it off.
    private func announceConversationFallback(
        category: ConversationFailureCategory,
        from failedProvider: CompanionPresentationProvider,
        to fallback: CompanionPresentationProvider,
        retryPrompt: String
    ) {
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

        let delaySeconds = Double(CaptionAlignmentBuilder.estimatedDurationMs(for: announcement)) / 1000.0 + 0.2
        conversationFallbackRetryTimer?.invalidate()
        conversationFallbackRetryTimer = Timer.scheduledTimer(withTimeInterval: delaySeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.conversationFallbackRetryTimer = nil
            self.conversationFallbackAnnouncement = nil
            self.isConversing = true
            self.beginConversationWait()
            self.performConversationRequest(retryPrompt)
        }
    }

    /// Builds full call settings for `provider` directly (INF-258/D5),
    /// bypassing every per-role persisted override: the auto-fallback chain
    /// must not touch Settings, only this call. Reuses the exact helpers
    /// Settings itself uses to resolve a provider's endpoint and credentials.
    private func conversationFallbackSettings(for provider: CompanionPresentationProvider) -> CompanionPresentationSettings {
        CompanionPresentationSettings.forFallback(
            provider: provider,
            baseURLText: endpointForIntegration(provider),
            apiKey: readConfiguredSecret(account: provider.developmentSecretAccount) ?? "",
            profilePrompt: defaults.string(forKey: CompanionPreferenceKey.personalityPrompt) ?? ""
        )
    }

    // MARK: Fallback chain settings (Model pane, INF-258/D5)

    func addConversationFallbackChainProvider(_ provider: CompanionPresentationProvider) {
        guard !conversationFallbackChain.contains(provider) else { return }
        conversationFallbackChain.append(provider)
    }

    func removeConversationFallbackChainProvider(_ provider: CompanionPresentationProvider) {
        conversationFallbackChain.removeAll { $0 == provider }
    }

    func moveConversationFallbackChainProvider(at index: Int, up: Bool) {
        let targetIndex = up ? index - 1 : index + 1
        guard conversationFallbackChain.indices.contains(index),
              conversationFallbackChain.indices.contains(targetIndex) else { return }
        conversationFallbackChain.swapAt(index, targetIndex)
    }

    var conversationRecoveryProviders: [CompanionPresentationProvider] {
        connectedTextProviders.filter { $0 != presentationProvider }
    }

    var conversationRecoveryModels: [CompanionPresentationModelOption] {
        var options = presentationModelOptions.filter { $0.id != presentationModel }
        if presentationModel != "default", !options.contains(where: { $0.id == "default" }) {
            options.insert(CompanionPresentationModelOption(
                id: "default",
                detail: "use \(presentationProvider.title)'s configured model",
                reasoningEfforts: CompanionPresentationModelService.fallbackReasoningEfforts(
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

    func selectConversationRecoveryModel(_ option: CompanionPresentationModelOption) {
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

    func selectConversationRecoveryProvider(_ provider: CompanionPresentationProvider) {
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
    /// `CompanionPresentationSettings.load(role:)`'s own fallback.
    private func effectiveRecoveryProvider(for role: ModelRole) -> CompanionPresentationProvider {
        roleModelProvider[role] ?? presentationProvider
    }

    private func effectiveRecoveryModelID(for role: ModelRole) -> String {
        roleModelID[role] ?? presentationModel
    }

    private func recoveryProviders(for role: ModelRole) -> [CompanionPresentationProvider] {
        connectedTextProviders.filter { $0 != effectiveRecoveryProvider(for: role) }
    }

    private func recoveryModelOptions(for role: ModelRole) -> [CompanionPresentationModelOption] {
        let currentModelID = effectiveRecoveryModelID(for: role)
        // No override yet: the role is using the main row, so its discovered
        // models are the main row's (`presentationModelOptions`), exactly what
        // the live call's own `conversationRecoveryModels` reads.
        let source = roleModelProvider[role] != nil ? (roleModelOptions[role] ?? []) : presentationModelOptions
        var options = source.filter { $0.id != currentModelID }
        if currentModelID != "default", !options.contains(where: { $0.id == "default" }) {
            let provider = effectiveRecoveryProvider(for: role)
            options.insert(CompanionPresentationModelOption(
                id: "default",
                detail: "use \(provider.title)'s configured model",
                reasoningEfforts: CompanionPresentationModelService.fallbackReasoningEfforts(provider: provider, modelID: "default")
            ), at: 0)
        }
        return options
    }

    /// Switches one role's override to a new provider (never the global
    /// fallback other roles read) and starts model discovery for it.
    private func selectRoleRecoveryProvider(_ provider: CompanionPresentationProvider, for role: ModelRole) {
        selectRoleProvider(provider, for: role)
        loadRoleModels(for: role)
    }

    /// Picks a model within a role's current effective provider. Seeds an
    /// explicit override for that provider first if the role was still on
    /// "Use main model" (a mere failure never seeds one on its own; only this
    /// explicit user action does).
    private func selectRoleRecoveryModel(_ option: CompanionPresentationModelOption, for role: ModelRole) {
        if roleModelProvider[role] == nil {
            selectRoleProvider(effectiveRecoveryProvider(for: role), for: role)
        }
        selectRoleModel(option, for: role)
    }

    var recapEffectiveProvider: CompanionPresentationProvider { effectiveRecoveryProvider(for: .recap) }
    /// Both follow-up surfaces (card-based and live/session-based) ride the
    /// `.conversation` role (see `ModelRole`'s doc), so they share this one
    /// "which provider is follow-up currently using" reading.
    var followUpEffectiveProvider: CompanionPresentationProvider { effectiveRecoveryProvider(for: .conversation) }
    var recapRecoveryProviders: [CompanionPresentationProvider] { recoveryProviders(for: .recap) }
    var recapRecoveryModels: [CompanionPresentationModelOption] { recoveryModelOptions(for: .recap) }

    var canRetryRecapFailure: Bool {
        recapRecovery?.offersModelSwitch == true && !recapRetryCards.isEmpty
    }

    func selectRecapRecoveryProvider(_ provider: CompanionPresentationProvider) {
        selectRoleRecoveryProvider(provider, for: .recap)
        recapRecoveryConfirmation = "Switched recap to \(provider.title). Retry the recap when ready."
    }

    func selectRecapRecoveryModel(_ option: CompanionPresentationModelOption) {
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

    var followUpRecoveryProviders: [CompanionPresentationProvider] { recoveryProviders(for: .conversation) }
    var followUpRecoveryModels: [CompanionPresentationModelOption] { recoveryModelOptions(for: .conversation) }

    var canRetryFollowUpFailure: Bool {
        followUpRecovery?.offersModelSwitch == true
            && !isGeneratingFollowUpAnswer
            && !followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func selectFollowUpRecoveryProvider(_ provider: CompanionPresentationProvider) {
        selectRoleRecoveryProvider(provider, for: .conversation)
        followUpStatus = "Switched to \(provider.title). Ask Attaché again to retry."
    }

    func selectFollowUpRecoveryModel(_ option: CompanionPresentationModelOption) {
        selectRoleRecoveryModel(option, for: .conversation)
        followUpStatus = "Switched to \(effectiveRecoveryProvider(for: .conversation).title) \(option.id). Ask Attaché again to retry."
    }

    /// Re-asks the same question, exactly like pressing "Ask Again".
    func retryFollowUpAfterFailure() {
        guard canRetryFollowUpFailure else { return }
        createFollowUpAnswer()
    }

    var liveFollowUpRecoveryProviders: [CompanionPresentationProvider] { recoveryProviders(for: .conversation) }
    var liveFollowUpRecoveryModels: [CompanionPresentationModelOption] { recoveryModelOptions(for: .conversation) }

    var canRetryLiveFollowUpFailure: Bool {
        liveFollowUpRecovery?.offersModelSwitch == true
            && !isGeneratingLiveFollowUpAnswer
            && !liveFollowUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func selectLiveFollowUpRecoveryProvider(_ provider: CompanionPresentationProvider) {
        selectRoleRecoveryProvider(provider, for: .conversation)
        liveFollowUpStatus = "Switched to \(provider.title). Ask Attaché again to retry."
    }

    func selectLiveFollowUpRecoveryModel(_ option: CompanionPresentationModelOption) {
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
    private func classifyFollowUpRecovery(_ answer: CompanionFollowUpAnswerResult) -> ConversationRecovery? {
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

    private func surfaceConversationReply(_ reply: String, toolCallLost: Bool = false) {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Keep the HUD in an audio-prep state until the normal delivery path,
        // captions and a replayable card, is ready.
        conversationStatus = "Preparing audio…"
        pendingAssistantReply = trimmed
        expectingReplyAudio = true
        // The reply preempts any live update mid-flight; requeue it so it resumes
        // after the reply instead of being lost. The reply is filed as a
        // replayable history card, while live delivery uses the same preview
        // playback/caption path as other immediate voice responses.
        livePlaybackQueue.replyStarted()
        _ = persistConversationReply(trimmed, toolCallLost: toolCallLost)
        playback.preview(trimmed)
        revealTimer?.invalidate()
        revealTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            self?.revealPendingReply()
        }
    }

    private func persistConversationReply(_ reply: String, toolCallLost: Bool = false) -> VoicemailCard? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let session = conversationTargetSnapshot?.target
        let personality = activePersonality
        var metadata: [String: String] = [
            "companion_history_kind": "direct_reply",
            "companion_summary": Self.conversationReplySummary(from: trimmed),
            "companion_spoken_text": trimmed,
            "companion_presentation_strategy": "companion-direct-chat",
            "companion_direct_reply": "true"
        ]
        // INF-243: a CLI personality attempted a tool call that never
        // recovered into a valid directive, even after the one corrective
        // retry. The card still carries the spoken degrade above; this only
        // flags that a tool call was attempted and lost.
        if toolCallLost {
            metadata["companion_tool_call_lost"] = "true"
        }
        if let personality {
            metadata["companion_personality_id"] = personality.id
            metadata["companion_personality_name"] = personality.name
        }
        if let session {
            metadata["attached_codex_session_id"] = session.id
        }

        let event = NormalizedEvent(
            source: session?.sourceKind.rawValue ?? SourceKind.generic.rawValue,
            eventType: "companion.conversation.reply",
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
        appendConversationTurn(role: .assistant, text: reply)
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

    private func appendConversationTurn(role: ConversationTurn.Role, text: String) {
        conversationMessages.append(ConversationTurn(id: UUID().uuidString, role: role, text: text, createdAt: Date()))
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
        if allowDirectSend && agentInstructionSendPolicy.sendsDirectlyAfterSessionEnable {
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
        guard let instruction = pendingInstruction else { return }
        pendingInstruction = nil
        let target = instruction.targetDisplayName ?? "the focused agent"
        let message = "Sending to \(target) when the session is quiet…"
        intakeStatus = message
        liveFollowUpStatus = message
        if conversationActive { conversationStatus = message }
        let coordinator = twoWay
        Task { @MainActor in
            do {
                let changed = try await coordinator?.confirmAndDeliver(id: instruction.id) ?? []
                handleTwoWayDeliveryChanges(changed)
            } catch {
                let message = "Send failed: \(error.localizedDescription)"
                intakeStatus = message
                liveFollowUpStatus = message
                conversationStatus = message
            }
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

    private func buildConversationMessages(context: ConversationTargetSnapshot?) -> [CompanionChatMessage] {
        let memorySnapshot = companionMemoryStore.loadSnapshot()
        let personaSnapshot = companionPersonaStore.loadSnapshot()
        let profilePrompt = personaSnapshot.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? CompanionPersonality.defaultProfilePrompt
            : personaSnapshot.prompt
        let system = CompanionPersonality.conversationSystemPrompt(
            profilePrompt: profilePrompt,
            memoryContext: memorySnapshot.context,
            sessionTitle: context?.target.displayTitle,
            sessionSourceName: context?.target.sourceKind.displayName,
            workingDirectory: context?.workingDirectory,
            latestSummary: conversationLatestSummary,
            latestAgentReply: conversationLatestAgentReply,
            canStageAgentInstruction: context?.agentSendTarget != nil,
            watchedSessions: watchedSessionSummaries(context: context)
        )
        var messages = [CompanionChatMessage(role: "system", content: system)]
        // Cap the in-RAM transcript sent per turn so a long multi-call conversation
        // doesn't grow the request unbounded; durable memory is the persistence
        // surface, not this transcript (INF-170).
        for turn in conversationMessages.suffix(Self.maxConversationTurnsPerRequest) {
            messages.append(CompanionChatMessage(role: turn.role == .user ? "user" : "assistant", content: turn.text))
        }
        return messages
    }

    /// Rebuilds the "Watched sessions" inventory fresh on every turn (INF-239)
    /// so "active Nm ago" stays honest. Sourced from the same watch list the
    /// UI shows (`attachedTargets`); two-way enablement is reported only for
    /// the explicitly focused session, never for the rest. This is prompt
    /// context for the model to read and mention, not a routing input, per
    /// AGENTS.md's "no hidden phrase routing" decision: the frozen send
    /// destination is unaffected by anything built here.
    private func watchedSessionSummaries(context: ConversationTargetSnapshot?) -> [CompanionPersonality.WatchedSessionSummary] {
        let focusedSessionID = (context?.isExplicitlyFocused == true) ? context?.target.id : nil
        var summaries = attachedTargets.values.map { target -> CompanionPersonality.WatchedSessionSummary in
            let isFocused = focusedSessionID != nil && target.id == focusedSessionID
            return CompanionPersonality.WatchedSessionSummary(
                sourceName: target.sourceKind.displayName,
                title: target.displayTitle,
                updatedAt: target.updatedAt,
                isFocused: isFocused,
                isTwoWayEnabled: isFocused && twoWay.isEnabled(sessionID: target.id)
            )
        }
        // Safety net: if the focused session hasn't landed in attachedTargets
        // yet (e.g. mid-restore), still surface it so the block never omits
        // the one session the model is otherwise told is focused.
        if let focusedSessionID, let context, !summaries.contains(where: { $0.isFocused }) {
            summaries.append(CompanionPersonality.WatchedSessionSummary(
                sourceName: context.target.sourceKind.displayName,
                title: context.target.displayTitle,
                updatedAt: context.target.updatedAt,
                isFocused: true,
                isTwoWayEnabled: twoWay.isEnabled(sessionID: focusedSessionID)
            ))
        }
        return summaries
    }

    private static let maxConversationTurnsPerRequest = 24
    private static let maxLoadedCards = 1_000

    private var conversationWorkingDirectory: String? {
        if let snapshot = conversationTargetSnapshot { return snapshot.workingDirectory }
        guard let id = talkContextSession?.id else { return nil }
        return workingDirectory(for: id)
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
        let id = conversationTargetSnapshot?.target.id
            ?? talkContextSession?.id
            ?? selectedCard?.externalSessionID
        if let id {
            return cards.first { $0.externalSessionID == id && !isDirectConversationReply($0) }
        }
        guard let selectedCard, !isDirectConversationReply(selectedCard) else { return nil }
        return selectedCard
    }

    private static func executeConversationTool(
        name: String,
        arguments: String,
        sessionID: String?,
        workingDirectory: String?
    ) -> String {
        switch name {
        case "read_session_transcript":
            guard let sessionID else { return "No earlier transcript is available for this session." }
            let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
            if let startTurn = (args?["start_turn"] as? Int) ?? (args?["start_turn"] as? NSNumber)?.intValue {
                let maxChars = (args?["max_chars"] as? Int) ?? (args?["max_chars"] as? NSNumber)?.intValue ?? 12_000
                guard let page = CompanionSessionReader.transcriptPage(forSessionID: sessionID, startTurn: startTurn, maxChars: maxChars) else {
                    return "No earlier transcript is available for this session."
                }
                return page
            }
            guard let transcript = CompanionSessionReader.transcript(forSessionID: sessionID) else {
                return "No earlier transcript is available for this session."
            }
            return transcript
        case "search_session_transcript":
            guard let sessionID else { return "No transcript is available for this session." }
            let query = ((try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any])?["query"] as? String ?? ""
            guard let result = CompanionSessionReader.searchTranscript(forSessionID: sessionID, query: query) else {
                return "No transcript is available for this session."
            }
            return result
        case "list_working_directory":
            guard let workingDirectory,
                  let listing = CompanionSessionReader.workingDirectoryListing(path: workingDirectory) else {
                return "No working directory is available for this session."
            }
            return listing
        case "read_file":
            guard let workingDirectory else { return "No working directory is available for this session." }
            let path = ((try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any])?["path"] as? String ?? ""
            guard !path.isEmpty,
                  let content = CompanionSessionReader.readFile(path: path, within: workingDirectory) else {
                return "Could not read that file. It may be outside the project, missing, or not text."
            }
            return content
        default:
            return "Unknown tool: \(name)."
        }
    }

    /// Apply a `rename_session` tool call on the main thread (it mutates published
    /// state and persists), returning a short confirmation for the assistant to relay.
    private func applyRenameTool(arguments: String, sessionID: String?) async -> String {
        guard let sessionID else { return "There's no attached session to rename right now." }
        let newName = ((try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any])?["name"] as? String ?? ""
        return await MainActor.run {
            renameSession(sessionID, to: newName)
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Reset this session's Attaché name back to the Codex default."
                : "Renamed this session to \"\(trimmed)\" in Attaché."
        }
    }

    /// Stage or send a personality-requested agent instruction. The first-use
    /// enable sheet always gates the session; the user's send policy decides
    /// whether enabled-session instructions need a final confirmation sheet.
    ///
    /// Not `private` (INF-246): unit tests call this directly to verify a
    /// mismatched `intended_agent` produces no side effect (no
    /// `PendingAgentSend`, no `requestSendToAgent` call, no staged
    /// instruction), not just the returned string.
    func applyStageAgentInstructionTool(
        arguments: String,
        target: AgentSendTarget?,
        sourceUtterance: String
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
    /// No UI reads `callPhase` yet; CallHUD/CompanionRootView still derive
    /// their own status text and error styling exactly as before (A2 wires
    /// the views to this).
    private func refreshCallPhase() {
        callPhase = CallPhase.derive(from: currentCallSignals())
    }

    /// Same choke-point pattern as `refreshCallPhase()` for the companion
    /// contract (INF-268): everything `CompanionActivitySignals` reads funnels
    /// through one subscription, so `companionActivity` stays current without
    /// refresh calls scattered across mutation sites. Attention transitions
    /// and watcher phrases arrive on their own poll cadence (2s / 1.5s), which
    /// also ages fresh tool signals out of `toolRunning` without a timer.
    private func setupCompanionActivityObservers() {
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
        .sink { [weak self] in self?.refreshCompanionActivity() }
        .store(in: &cancellables)
    }

    /// The per-session fleet for renderers (INF-275): every watched session,
    /// its mote state from the attention map, the focused flag, and the live
    /// sub-agent count. Sorted stably so mote layouts never shuffle.
    private func currentFleet() -> [CompanionFleetSession] {
        attachedTargets.values
            .sorted { $0.id < $1.id }
            .map { target in
                let state: CompanionFleetSession.State
                switch sessionAttention[target.id] {
                case .active: state = .working
                case .awaitingAnswer, .possiblyWaiting: state = .blocked
                case .turnComplete: state = .finished
                case .erroredRecently, .quiet, nil: state = .quiet
                }
                return CompanionFleetSession(
                    id: target.id,
                    agent: CompanionAgentIdentity(sourceKindRawValue: target.sourceKind.rawValue),
                    state: state,
                    isFocused: target.id == attachedCodexSessionID,
                    activeSubAgents: subAgentCounts[target.id] ?? 0,
                    title: target.displayTitle
                )
            }
    }

    private func refreshCompanionActivity() {
        var next: CompanionActivityState
        if let simulatedActivity {
            next = simulatedActivity
        } else {
            let derived = CompanionActivityState.derive(
                from: currentActivitySignals(),
                audio: playback.clock.renderState
            )
            next = activityDamper.damp(derived, now: Date())
            // Focus-tied compaction: only the session the user is watching
            // drives the squish, so switching focus releases it.
            next.compactingSince = attachedCodexSessionID.flatMap { compactingSince[$0] }
        }
        if next != companionActivity {
            companionActivity = next
        }
    }

    /// Debug hook for the activity simulator panel: fires a one-shot moment
    /// through the same publisher real transitions use.
    func triggerMoment(_ kind: CompanionActivityMoment.Kind, agent: CompanionAgentIdentity) {
        companionMoment = CompanionActivityMoment(kind: kind, agent: agent, at: Date())
    }

    /// Maps a lifecycle-hook event type to the one-shot pet moment it plays.
    private static func momentKind(forEventType type: String) -> CompanionActivityMoment.Kind? {
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
    private func agentIdentity(forSessionID sessionID: String) -> CompanionAgentIdentity {
        if let target = attachedTargets[sessionID] {
            return CompanionAgentIdentity(sourceKindRawValue: target.sourceKind.rawValue)
        }
        if let record = sessionRecords.first(where: { $0.id == sessionID }) {
            return CompanionAgentIdentity(sourceKindRawValue: record.sourceKind.rawValue)
        }
        return .none
    }

    private func currentActivitySignals() -> CompanionActivitySignals {
        // Multi-session priority (INF-271): an exact ask beats a soft
        // possibly-waiting, and within a tier the most recent transition
        // wins, so the bubble always shows whose event the pet is reacting to.
        var blockedCandidates: [(exact: Bool, when: Date, agent: CompanionAgentIdentity)] = []
        var errored: (when: Date, agent: CompanionAgentIdentity)?
        var working: (when: Date, agent: CompanionAgentIdentity)?
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

        let speakingAgent: CompanionAgentIdentity? = playback.currentCardID.flatMap { id in
            cards.first { $0.id == id }.map { CompanionAgentIdentity(sourceKindRawValue: $0.sourceKind) }
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
        let respondingAgent: CompanionAgentIdentity? = {
            guard isPreparing else { return nil }
            if let started = respondingBurstStartedAt,
               Date().timeIntervalSince(started) > Self.respondingSelfHealSeconds {
                return nil
            }
            if let composeSource { return CompanionAgentIdentity(sourceKindRawValue: composeSource) }
            return speakingAgent ?? .none
        }()

        return CompanionActivitySignals(
            hasPinnedSessions: !attachedTargets.isEmpty,
            blockedAgent: blockedAgent,
            erroredAgent: erroredAgent,
            workingAgent: workingAgent,
            respondingAgent: respondingAgent,
            toolAgent: freshTool.map { CompanionAgentIdentity(sourceKindRawValue: $0.agentKind.rawValue) },
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
            artist: CompanionAppSupport.appDisplayName,
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

    func openCompanionMemoryFile() {
        do {
            let url = try companionMemoryStore.ensureMemoryFile()
            NSWorkspace.shared.open(url)
            companionMemoryStatus = "Opened memory."
        } catch {
            companionMemoryStatus = "Memory unavailable: \(error.localizedDescription)"
        }
    }

    // MARK: Cloud consent

    /// Whether choosing this presentation provider will send agent output,
    /// transcripts, and read files off this Mac. CLI providers run a local tool
    /// under your existing login and expose no Attaché-chosen endpoint, so they
    /// don't trip the consent moment; HTTP providers do when their base URL is
    /// non-loopback (so a Custom endpoint pointed at localhost stays local).
    func presentationProviderSendsToCloud(_ provider: CompanionPresentationProvider) -> Bool {
        if provider.isCLI { return false }
        return NetworkSecurity.isCloudEndpoint(endpointForIntegration(provider))
    }

    var presentationSendsToCloud: Bool { presentationProviderSendsToCloud(presentationProvider) }
    var voiceSendsToCloud: Bool { effectiveSpeechProvider.sendsToCloud }

    private var effectiveSpeechProvider: CompanionSpeechProvider {
        selectedSpeechConfiguration.resolvedForPlayback(
            systemVoiceIdentifier: speechVoiceIdentifier
        ).provider
    }

    /// One-time acknowledgment that a cloud presentation provider sends data
    /// off the Mac. Tracked per provider (INF-247), not as a single flag: a
    /// user who consented to one cloud provider for one role should still be
    /// asked before a different role starts sending data to a different
    /// cloud provider. Migrated once from the legacy single
    /// `cloudConsentPresentation` flag; see `migrateCloudConsentToPerProvider`.
    func cloudConsentAcknowledged(for provider: CompanionPresentationProvider) -> Bool {
        consentedCloudPresentationProviders().contains(provider.rawValue)
    }

    func acknowledgeCloudConsent(for provider: CompanionPresentationProvider) {
        var providers = consentedCloudPresentationProviders()
        guard providers.insert(provider.rawValue).inserted else { return }
        defaults.set(Array(providers).sorted(), forKey: CompanionPreferenceKey.cloudConsentPresentationProviders)
    }

    private func consentedCloudPresentationProviders() -> Set<String> {
        Set(defaults.array(forKey: CompanionPreferenceKey.cloudConsentPresentationProviders) as? [String] ?? [])
    }

    /// Runs once, gated by `cloudConsentPresentationMigrationDone`: if the
    /// legacy single-flag consent was already given, credits whatever
    /// provider is configured right now (the provider that flag's consent
    /// actually applied to) so existing users aren't re-prompted for a
    /// provider they already agreed to send data to. Pure defaults
    /// read/write, no keychain, so it's safe to run inline on the launch
    /// path (unlike `migrateLegacyPresentationKeys`). Idempotent: once the
    /// migration flag is set, this is a no-op forever after, so a later
    /// per-provider revocation is never re-populated from the stale legacy flag.
    private func migrateCloudConsentToPerProvider() {
        guard !defaults.bool(forKey: CompanionPreferenceKey.cloudConsentPresentationMigrationDone) else { return }
        if defaults.bool(forKey: CompanionPreferenceKey.cloudConsentPresentation) {
            acknowledgeCloudConsent(for: presentationProvider)
        }
        defaults.set(true, forKey: CompanionPreferenceKey.cloudConsentPresentationMigrationDone)
    }

    var cloudConsentVoiceAcknowledged: Bool {
        get { defaults.bool(forKey: CompanionPreferenceKey.cloudConsentVoice) }
        set { defaults.set(newValue, forKey: CompanionPreferenceKey.cloudConsentVoice) }
    }

    func selectPresentationProvider(_ provider: CompanionPresentationProvider) {
        let previousProvider = presentationProvider
        let existingModel = presentationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultModels = CompanionPresentationProvider.allCases.map(\.defaultModel)

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
        presentationModelOptions = []
        applyFallbackCapabilitiesForCurrentModel()
        presentationModelDiscoveryStatus = "Model discovery not checked"
        refreshPresentationStatus()
        intakeStatus = "Presentation LLM provider set to \(provider.title)."
    }

    // MARK: Integrations

    func endpointForIntegration(_ provider: CompanionPresentationProvider) -> String {
        switch provider {
        case .ollama: return ollamaBaseURL
        case .lmStudio: return lmStudioBaseURL
        case .custom: return customBaseURL
        case .xai, .groq: return provider.defaultBaseURL
        case .claudeCLI, .codexCLI: return ""
        }
    }

    var connectedTextProviders: [CompanionPresentationProvider] {
        CompanionPresentationProvider.allCases.filter { provider in
            switch provider {
            case .xai: return !xaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .groq: return !groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .custom: return !customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .ollama, .lmStudio: return true
            case .claudeCLI: return CLILanguageModel.isLikelyInstalled(.claude)
            case .codexCLI: return CLILanguageModel.isLikelyInstalled(.codex)
            }
        }
    }

    var connectedVoiceEngines: [CompanionSpeechProvider] {
        var engines: [CompanionSpeechProvider] = [.system]
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
        let base = (customBaseURL.isEmpty ? CompanionPresentationProvider.custom.defaultBaseURL : customBaseURL).lowercased()
        return (!customKey.isEmpty && base.contains("api.openai.com")) ? customKey : ""
    }

    func saveXAIIntegration() {
        saveXAIKeyAndLoadVoices()
        if presentationProvider == .xai { presentationAPIKey = xaiAPIKey }
        refreshPresentationStatus()
    }

    func saveGroqIntegration() { saveIntegrationTextKey(groqAPIKey, provider: .groq) }
    func saveCustomIntegration() { saveIntegrationTextKey(customAPIKey, provider: .custom) }

    private func saveIntegrationTextKey(_ key: String, provider: CompanionPresentationProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try CompanionSecretVault.save(trimmed, account: provider.developmentSecretAccount)
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
        for provider in CompanionPresentationProvider.allCases where provider.requiresAPIKey {
            let newAccount = provider.developmentSecretAccount
            let legacyAccount = "presentation-llm-\(provider.rawValue)-api-key"
            let hasNew = !(readConfiguredSecret(account: newAccount) ?? "").isEmpty
            if !hasNew,
               isSecretAccountConfigured(legacyAccount),
               let legacy = CompanionSecretVault.read(account: legacyAccount),
               !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? CompanionSecretVault.save(legacy, account: newAccount)
                setSecretAccountConfigured(newAccount, configured: true)
            }
        }
    }

    func healthStatus(_ id: String) -> IntegrationHealth {
        integrationHealth[id] ?? .unconfigured
    }

    func checkAllIntegrations() {
        let now = Date()
        for id in ["xai", "elevenlabs", "openai", "groq", "ollama", "lmstudio", "custom", "ondevice"] {
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
        case "xai":
            runHealthCheck(id, configured: isSet(xaiAPIKey)) {
                _ = try await CompanionPresentationModelService.fetchModels(
                    provider: .xai, baseURLText: CompanionPresentationProvider.xai.defaultBaseURL, apiKey: self.xaiAPIKey)
            }
        case "groq":
            runHealthCheck(id, configured: isSet(groqAPIKey)) {
                _ = try await CompanionPresentationModelService.fetchModels(
                    provider: .groq, baseURLText: CompanionPresentationProvider.groq.defaultBaseURL, apiKey: self.groqAPIKey)
            }
        case "custom":
            runHealthCheck(id, configured: isSet(customAPIKey)) {
                _ = try await CompanionPresentationModelService.fetchModels(
                    provider: .custom, baseURLText: self.customBaseURL, apiKey: self.customAPIKey)
            }
        case "ollama":
            runHealthCheck(id, configured: true) {
                _ = try await CompanionPresentationModelService.fetchModels(
                    provider: .ollama, baseURLText: self.ollamaBaseURL, apiKey: "")
            }
        case "lmstudio":
            runHealthCheck(id, configured: true) {
                _ = try await CompanionPresentationModelService.fetchModels(
                    provider: .lmStudio, baseURLText: self.lmStudioBaseURL, apiKey: "")
            }
        case "elevenlabs":
            runHealthCheck(id, configured: isSet(elevenLabsAPIKey)) {
                _ = try await CompanionRemoteVoiceService.fetchElevenLabsVoices(apiKey: self.elevenLabsAPIKey)
            }
        case "openai":
            runHealthCheck(id, configured: isSet(effectiveOpenAIVoiceKey)) {
                try await CompanionRemoteVoiceService.verifyOpenAIKey(apiKey: self.effectiveOpenAIVoiceKey)
            }
        default:
            break
        }
    }

    private func isSet(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func configuredSecretAccounts() -> Set<String> {
        Set(defaults.array(forKey: CompanionPreferenceKey.configuredSecretAccounts) as? [String] ?? [])
    }

    private func isSecretAccountConfigured(_ account: String) -> Bool {
        configuredSecretAccounts().contains(account)
    }

    private func readConfiguredSecret(account: String) -> String? {
        guard isSecretAccountConfigured(account) else { return nil }
        return CompanionSecretVault.read(account: account)
    }

    private func setSecretAccountConfigured(_ account: String, configured: Bool) {
        var accounts = configuredSecretAccounts()
        if configured {
            accounts.insert(account)
        } else {
            accounts.remove(account)
        }
        defaults.set(Array(accounts).sorted(), forKey: CompanionPreferenceKey.configuredSecretAccounts)
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
                    let settings = CompanionPresentationSettings.load(
                        role: .conversation,
                        defaults: self.defaults,
                        environment: self.presentationEnvironment,
                        resolveSecrets: true
                    )
                    key = settings.apiKey
                }
                let models = try await CompanionPresentationModelService.fetchModels(
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

    func selectPresentationModel(_ option: CompanionPresentationModelOption) {
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
            guard let rawProvider = defaults.string(forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .provider)),
                  let provider = CompanionPresentationProvider(rawValue: rawProvider) else { continue }
            roleModelProvider[role] = provider
            roleModelID[role] = defaults.string(forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .model))
                ?? provider.defaultModel
            roleReasoningEffort[role] = defaults.string(forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .reasoningEffort))
                ?? provider.defaultReasoningEffort
            roleServiceTier[role] = defaults.string(forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .serviceTier))
                ?? provider.defaultServiceTier
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
        return CompanionPresentationModelService.fallbackReasoningEfforts(provider: provider, modelID: modelID)
    }

    /// Same idea as `selectedPresentationServiceTierOptions`, scoped to one role.
    func roleServiceTierOptions(for role: ModelRole) -> [CompanionPresentationServiceTierOption] {
        guard let provider = roleModelProvider[role] else { return [] }
        let modelID = roleModelID[role] ?? provider.defaultModel
        let options: [CompanionPresentationServiceTierOption]
        if let option = (roleModelOptions[role] ?? []).first(where: { $0.id == modelID }) {
            options = option.serviceTiers
        } else {
            options = CompanionPresentationModelService.fallbackServiceTierOptions(provider: provider, modelID: modelID)
        }
        guard !options.isEmpty else { return [] }
        if options.contains(where: { $0.id == "default" }) { return options }
        return [CompanionPresentationServiceTierOption(id: "default", title: "Default", detail: "Use the provider's default tier")] + options
    }

    /// Clamps a role's stored reasoning-effort/service-tier choice to what its
    /// current provider/model actually supports, the same guard the main row
    /// applies in `applyCapabilitiesForSelectedModel`/`applyFallbackCapabilitiesForCurrentModel`.
    private func clampRoleCapabilities(for role: ModelRole) {
        let reasoningOptions = roleReasoningOptions(for: role)
        let currentReasoning = (roleReasoningEffort[role] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if reasoningOptions.isEmpty {
            roleReasoningEffort[role] = "none"
        } else if currentReasoning.isEmpty || currentReasoning == "none" || (currentReasoning != "default" && !reasoningOptions.contains(currentReasoning)) {
            roleReasoningEffort[role] = "default"
        }
        defaults.set(roleReasoningEffort[role], forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .reasoningEffort))

        let serviceOptions = roleServiceTierOptions(for: role).map(\.id)
        let currentService = (roleServiceTier[role] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if serviceOptions.isEmpty {
            roleServiceTier[role] = "default"
        } else if currentService.isEmpty || !serviceOptions.contains(currentService) {
            roleServiceTier[role] = "default"
        }
        defaults.set(roleServiceTier[role], forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .serviceTier))
    }

    /// Sets, or clears when `provider` is nil ("Use main model"), the role's
    /// provider override. Clearing removes every per-role key for that role
    /// so `CompanionPresentationSettings.load(role:)` falls all the way back
    /// to the global `presentationLLM*` keys instead of leaving a stale but
    /// coincidentally-matching per-role value behind.
    func selectRoleProvider(_ provider: CompanionPresentationProvider?, for role: ModelRole) {
        guard let provider else {
            roleModelProvider.removeValue(forKey: role)
            roleModelID.removeValue(forKey: role)
            roleReasoningEffort.removeValue(forKey: role)
            roleServiceTier.removeValue(forKey: role)
            roleModelOptions.removeValue(forKey: role)
            roleModelDiscoveryStatus.removeValue(forKey: role)
            defaults.removeObject(forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .provider))
            defaults.removeObject(forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .model))
            defaults.removeObject(forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .reasoningEffort))
            defaults.removeObject(forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .serviceTier))
            return
        }
        roleModelProvider[role] = provider
        roleModelID[role] = provider.defaultModel
        roleModelOptions[role] = []
        roleModelDiscoveryStatus[role] = "Model discovery not checked"
        defaults.set(provider.rawValue, forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .provider))
        defaults.set(provider.defaultModel, forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .model))
        clampRoleCapabilities(for: role)
    }

    func selectRoleModel(_ option: CompanionPresentationModelOption, for role: ModelRole) {
        guard roleModelProvider[role] != nil else { return }
        roleModelID[role] = option.id
        defaults.set(option.id, forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .model))
        clampRoleCapabilities(for: role)
    }

    func selectRoleModelID(_ id: String, for role: ModelRole) {
        guard roleModelProvider[role] != nil else { return }
        roleModelID[role] = id
        defaults.set(id, forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .model))
        clampRoleCapabilities(for: role)
    }

    func setRoleReasoningEffort(_ value: String, for role: ModelRole) {
        guard roleModelProvider[role] != nil else { return }
        roleReasoningEffort[role] = value
        defaults.set(value, forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .reasoningEffort))
    }

    func setRoleServiceTier(_ value: String, for role: ModelRole) {
        guard roleModelProvider[role] != nil else { return }
        roleServiceTier[role] = value
        defaults.set(value, forKey: CompanionPreferenceKey.presentationLLMRoleKey(role, .serviceTier))
    }

    /// Model discovery for one role's override, scoped to that role's own
    /// provider. Unlike `loadPresentationModels` (which discovers for the
    /// single main-model row this pane also shows), this fetches for
    /// whichever provider a role currently points at. It reuses the exact
    /// same underlying network call (`CompanionPresentationModelService.fetchModels`)
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
                let models = try await CompanionPresentationModelService.fetchModels(
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
    /// `CompanionSpeechProvider` overload above.
    func focusIntegration(for provider: CompanionPresentationProvider) {
        switch provider {
        case .xai: integrationFocusProviderID = "xai"
        case .ollama: integrationFocusProviderID = "ollama"
        case .lmStudio: integrationFocusProviderID = "lmstudio"
        case .groq: integrationFocusProviderID = "groq"
        case .custom: integrationFocusProviderID = "custom"
        case .claudeCLI, .codexCLI: integrationFocusProviderID = nil
        }
    }

    // MARK: Personalities

    var activePersonality: Personality? {
        personalities.first { $0.id == activePersonalityID }
    }

    func loadPersonalities() {
        let loaded = personalityStore.load()
        personalities = loaded.personalities
        activePersonalityID = loaded.activeID
        writeActivePersonalityToDefaults()
    }

    func selectPersonality(_ id: String) {
        guard personalities.contains(where: { $0.id == id }) else { return }
        let changed = id != activePersonalityID
        activePersonalityID = id
        personalityStore.save(personalities, activeID: id)
        writeActivePersonalityToDefaults()
        refreshPresentationStatus()
        intakeStatus = "Personality set to \(activePersonality?.name ?? "Attaché")."
        // Apply after the base status so a missing-key fallback hint wins.
        if let personality = activePersonality {
            applyPersonalityVoiceAndPet(personality)
        }
        // A brief wave when the character actually changes, then the pet resumes
        // its normal activity (INF-298).
        if changed {
            triggerMoment(.greet, agent: .none)
        }
    }

    @discardableResult
    func createPersonality(name: String, prompt: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = Personality(
            id: "custom.\(UUID().uuidString)",
            name: trimmedName.isEmpty ? "My Personality" : trimmedName,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines)
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
    var isLiveCallActive: Bool { conversationTargetSnapshot != nil }

    /// The user-facing personality switch from the dock or the ⌘[ / ⌘] shortcut.
    /// In a live call it clarifies the last turn in the new personality's voice;
    /// otherwise it is a plain switch. Kept separate from `selectPersonality` so
    /// the internal switch `anotherTake` performs never re-enters clarify.
    func switchPersonalityFromUI(_ id: String) {
        if isLiveCallActive {
            clarifyWithPersonality(id)
        } else {
            selectPersonality(id)
        }
    }

    /// Live "clarify with a different personality" (INF-301): the new personality
    /// reacts to the most recent update and gives its own take in its voice and
    /// pet, then listening resumes under it. Narration only, so it never changes
    /// the frozen agent-send target or the Ask Attaché / Tell Agent routing.
    func clarifyWithPersonality(_ id: String) {
        if let last = cards.max(by: { $0.createdAt < $1.createdAt }) {
            anotherTake(card: last, targetPersonalityID: id)
        } else {
            selectPersonality(id)
        }
    }

    func addPersonality() {
        let new = Personality(
            id: "custom.\(UUID().uuidString)",
            name: "New Personality",
            prompt: Personality.newTemplate
        )
        personalities.append(new)
        selectPersonality(new.id)
    }

    func duplicatePersonality(id: String) {
        guard let source = personalities.first(where: { $0.id == id }) else { return }
        let copy = Personality(
            id: "custom.\(UUID().uuidString)",
            name: "\(source.name) Copy",
            prompt: source.prompt,
            voiceRef: source.voiceRef,
            petCharacter: source.petCharacter,
            accentColorHex: source.accentColorHex
        )
        if let index = personalities.firstIndex(where: { $0.id == id }) {
            personalities.insert(copy, at: index + 1)
        } else {
            personalities.append(copy)
        }
        selectPersonality(copy.id)
    }

    /// Apply a personality's bundled voice and pet so a switch changes brain,
    /// voice, and pet as one unit (INF-296). A nil voiceRef means "inherit the
    /// current voice", so switching among voice-agnostic personalities leaves the
    /// user's chosen voice alone. A cloud voice whose API key is missing falls
    /// back to the on-device engine with a hint instead of failing the switch.
    private func applyPersonalityVoiceAndPet(_ personality: Personality) {
        petCharacter = personality.petCharacter ?? .robot
        guard let ref = personality.voiceRef?.resolved(availableSystemVoiceIDs: installedSystemVoiceIDs()) else {
            return
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
            if let value = ref.xaiBaseURL { xaiBaseURL = value }
            if let value = ref.xaiLanguage { xaiLanguage = value }
            speechProvider = .xai
        case .openai:
            guard hasSpeechAPIKey(for: .openai) else { return fallBackToSystemVoice(missing: "OpenAI") }
            if let value = ref.openaiVoiceID { openaiVoiceID = value }
            if let value = ref.openaiVoiceName { openaiVoiceName = value }
            speechProvider = .openai
        }
    }

    private func installedSystemVoiceIDs() -> Set<String> {
        Set(speechVoiceOptions.map { $0.id })
    }

    private func hasSpeechAPIKey(for provider: CompanionSpeechProvider) -> Bool {
        switch provider {
        case .system: return true
        case .elevenLabs: return !elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .xai: return !xaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .openai: return !openaiVoiceAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func fallBackToSystemVoice(missing provider: String) {
        speechProvider = .system
        intakeStatus = "\(provider) needs an API key, so this personality is using the on-device voice for now."
    }

    /// Change the pet as a user action, keeping it in sync with the active
    /// personality. Programmatic switches set `petCharacter` directly instead.
    func selectPetCharacter(_ character: BubblesPetCharacter) {
        petCharacter = character
        capturePetIntoActivePersonality()
    }

    /// Fold the current voice selection onto the active personality, so a voice
    /// edit belongs to the personality rather than an orphan global (INF-296).
    func captureCurrentVoiceIntoActivePersonality() {
        guard let index = personalities.firstIndex(where: { $0.id == activePersonalityID }) else { return }
        personalities[index].voiceRef = PersonalityVoiceRef.capture(from: defaults)
        personalityStore.save(personalities, activeID: activePersonalityID)
    }

    /// Fold the current pet onto the active personality (INF-296).
    func capturePetIntoActivePersonality() {
        guard let index = personalities.firstIndex(where: { $0.id == activePersonalityID }) else { return }
        personalities[index].petCharacter = petCharacter
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
        guard let imported = try? PersonalityStore.importPersonality(from: data) else {
            intakeStatus = "Could not import that personality file."
            return
        }
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
        let prompt = activePersonality?.prompt ?? CompanionPersonality.defaultProfilePrompt
        defaults.set(prompt, forKey: CompanionPreferenceKey.personalityPrompt)
    }

    private func applyCapabilitiesForSelectedModel(_ option: CompanionPresentationModelOption) {
        if option.reasoningEfforts.isEmpty {
            presentationReasoningEffort = "none"
        } else {
            let options = option.reasoningEfforts
            let current = presentationReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
            if current.isEmpty || current == "none" || (current != "default" && !options.contains(current)) {
                presentationReasoningEffort = "default"
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
            if current.isEmpty || current == "none" || (current != "default" && !reasoningOptions.contains(current)) {
                presentationReasoningEffort = "default"
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

    func selectSpeechVoice(_ option: CompanionVoiceOption?) {
        speechProvider = .system
        speechVoiceIdentifier = option?.id
        intakeStatus = option.map { "Assistant voice set to \($0.title)." } ?? "Assistant voice set to system default."
        previewAssistantVoice()
        captureCurrentVoiceIntoActivePersonality()
    }

    func selectElevenLabsVoice(_ voice: RemoteVoiceOption) {
        speechProvider = .elevenLabs
        elevenLabsVoiceID = voice.id
        elevenLabsVoiceName = voice.name
        intakeStatus = "ElevenLabs voice set to \(voice.name)."
        previewAssistantVoice()
        captureCurrentVoiceIntoActivePersonality()
    }

    func selectXAIVoice(_ voice: RemoteVoiceOption) {
        speechProvider = .xai
        xaiVoiceID = voice.id
        xaiVoiceName = voice.name
        intakeStatus = "xAI voice set to \(voice.name)."
        previewAssistantVoice()
        captureCurrentVoiceIntoActivePersonality()
    }

    func selectOpenAIVoice(_ voice: RemoteVoiceOption) {
        speechProvider = .openai
        openaiVoiceID = voice.id
        openaiVoiceName = voice.name
        intakeStatus = "OpenAI voice set to \(voice.name)."
        previewAssistantVoice()
        captureCurrentVoiceIntoActivePersonality()
    }

    func saveOpenAIVoiceIntegration() {
        let trimmed = openaiVoiceAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try CompanionSecretVault.save(trimmed, account: Self.openaiDevelopmentSecretAccount)
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
            try CompanionSecretVault.save(trimmed, account: Self.elevenLabsDevelopmentSecretAccount)
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
            try CompanionSecretVault.save(trimmed, account: Self.xaiDevelopmentSecretAccount)
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
                let voices = try await CompanionRemoteVoiceService.fetchElevenLabsVoices(apiKey: key)
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
        voiceProviderStatus = "Loading xAI voices..."
        Task {
            do {
                let voices = try await CompanionRemoteVoiceService.fetchXAIVoices(apiKey: key, baseURL: xaiBaseURL)
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
                try await CompanionRemoteVoiceService.verifyOpenAIKey(apiKey: key)
                await MainActor.run {
                    self.openaiVoiceOptions = CompanionRemoteVoiceService.builtInOpenAIVoices
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
        let migratedAutomationAttachment = migrateAutomationAttachmentIfNeeded(in: snapshot, updateStatus: updateStatus)
        if attachedCodexSession?.category == .archivedSession {
            attachedCodexSessionID = nil
        }
        updateCodexWatcher()
        if updateStatus, !migratedAutomationAttachment {
            intakeStatus = codexSessions.isEmpty
                ? "No active Codex sessions found."
                : "Loaded \(codexSessions.count) active Codex sessions."
        }
    }

    private func startCodexSessionRefreshTimer() {
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

    func refreshSessionIndex() {
        guard !enabledAgentSources.isEmpty else {
            sessionRecords = []
            sessionIndexRevision += 1
            isIndexingSessions = false
            return
        }
        guard !isIndexingSessions else { return }
        isIndexingSessions = true
        let enabledSources = enabledAgentSources
        sessionIndexQueue.async { [weak self] in
            guard let self else { return }
            let records = self.sessionIndexer.refresh()
            DispatchQueue.main.async {
                self.sessionRecords = records.filter { enabledSources.contains($0.sourceKind) }
                self.sessionIndexRevision += 1
                self.isIndexingSessions = false
                self.tagUntaggedSessions()
                self.syncWatchedTitles()
            }
        }
    }

    /// Background LLM topic tagging. Labels untagged sessions (most-recent first) in
    /// small batches so each row gets a short subject like "Taxes" or "Penumbra".
    /// Tags persist in the index cache, so this only does real work for new or
    /// changed sessions after the first pass. Bounded per run to keep cost in check.
    func tagUntaggedSessions(maxPerRun: Int = 480, batchSize: Int = 12) {
        guard ProcessInfo.processInfo.environment["ATTACHE_DISABLE_TOPIC_TAGGING"] != "1" else { return }
        guard !isTaggingSessions, presentationService.isPresentationConfigured(for: .tagging) else { return }
        let pending = Array(sessionIndexer.untaggedRecords()
            .filter { enabledAgentSources.contains($0.sourceKind) }
            .prefix(maxPerRun))
        guard !pending.isEmpty else { return }
        isTaggingSessions = true
        // Seed the vocabulary with tags already on record so a fresh run keeps reusing
        // them; grows as batches complete to keep similar sessions consistent.
        var vocabulary = Set(sessionRecords.compactMap { $0.topicTag }.filter { !$0.isEmpty })

        Task { [weak self] in
            guard let self else { return }
            for start in stride(from: 0, to: pending.count, by: batchSize) {
                let batch = Array(pending[start..<min(start + batchSize, pending.count)])
                let items = batch.map { record in
                    SessionTagger.Item(
                        id: record.id,
                        title: record.title,
                        snippet: record.content,
                        project: self.curatedProjectName(forCWD: record.project)
                    )
                }
                // Tagging failures stay silent to the user by design (this is
                // deliberate, per docs/reviews/2026-07-10-app-review.md): a
                // failed batch is simply skipped, exactly as before. The only
                // change (INF-254) is counting the failure for the
                // diagnostics snapshot instead of it vanishing unobserved.
                let reply: String?
                do {
                    reply = try await self.presentationService.complete(
                        system: SessionTagger.systemPrompt,
                        user: SessionTagger.userPrompt(for: items, knownTags: Array(vocabulary)),
                        role: .tagging
                    )
                } catch {
                    reply = nil
                    await MainActor.run { self.taggingFailureCount += 1 }
                }
                let tags = reply.map { SessionTagger.parse($0) } ?? [:]
                vocabulary.formUnion(tags.values)
                if !tags.isEmpty {
                    // SessionIndexer is internally locked, so writing back off the
                    // index queue is safe; refresh and this stay serialized.
                    let updated = self.sessionIndexer.applyTags(tags)
                    await MainActor.run {
                        self.sessionRecords = self.filteredEnabledRecords(updated)
                        self.sessionIndexRevision += 1
                    }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            await MainActor.run { self.isTaggingSessions = false }
        }
    }

    var localAgentSourcesEnabled: Bool {
        codexSourceEnabled || claudeCodeSourceEnabled
    }

    func setCodexSourceEnabled(_ enabled: Bool) {
        guard codexSourceEnabled != enabled else { return }
        codexSourceEnabled = enabled
        defaults.set(enabled, forKey: CompanionPreferenceKey.codexSourceEnabled)

        if !enabled {
            codexSessions = []
            archivedCodexSessions = []
            codexAutomations = []
            attachedTargets = attachedTargets.filter { $0.value.sourceKind != .codex }
            if attachedCodexSession?.sourceKind == .codex {
                attachedCodexSessionID = attachedSessionList.first?.id
            }
            updateCodexWatcher()
        }

        rebuildSessionIndexer()
        refreshCodexSessions(updateStatus: false)
        refreshSessionIndex()
    }

    func setClaudeCodeSourceEnabled(_ enabled: Bool) {
        guard claudeCodeSourceEnabled != enabled else { return }
        claudeCodeSourceEnabled = enabled
        defaults.set(enabled, forKey: CompanionPreferenceKey.claudeCodeSourceEnabled)
        if !enabled {
            // Mirror the Codex disable path: stop watching Claude sessions now
            // instead of only rebuilding the index (they'd keep producing
            // voicemail until restart otherwise) (INF-168).
            attachedTargets = attachedTargets.filter { $0.value.sourceKind != .claudeCode }
            if attachedCodexSession?.sourceKind == .claudeCode {
                attachedCodexSessionID = attachedSessionList.first?.id
            }
            updateCodexWatcher()
        }
        rebuildSessionIndexer()
        refreshSessionIndex()
    }

    func focusIntegration(for provider: CompanionSpeechProvider) {
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
        SessionSearchRanker.search(
            query,
            in: sessionRecords,
            pinned: [],
            includeArchived: includeArchived
        )
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
        defaults.set(sessionRenames, forKey: CompanionPreferenceKey.sessionRenames)
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
        if attachedTargets[hit.record.id] != nil {
            detachCodexSession(hit.record.id)
        } else {
            watchSearchHit(hit, focus: false)
        }
    }

    func watchSearchHit(_ hit: SessionSearchHit, focus: Bool) {
        watchSession(target(for: hit.record), focus: focus)
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

    private func watchSession(_ session: CodexSessionTarget, focus: Bool) {
        attachedTargets[session.id] = session
        if focus || attachedCodexSessionID == nil {
            attachedCodexSessionID = session.id
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
        followUpAnswerText = ""
        isGeneratingFollowUpAnswer = true
        followUpStatus = "Asking Attaché about \(target)."
        // A fresh attempt (typed question or explicit retry) supersedes any
        // stale recovery banner from a previous failure (INF-254).
        followUpRecovery = nil

        presentationService.answerFollowUpQuestion(
            card: card,
            danQuestion: trimmed
        ) { [weak self] result in
            guard let self,
                  self.followUpAnswerRequestID == requestID else {
                return
            }
            self.isGeneratingFollowUpAnswer = false
            switch result {
            case .success(let answer):
                self.followUpAnswerText = answer.answerText
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
        liveFollowUpAnswerText = ""
        isGeneratingLiveFollowUpAnswer = true
        liveFollowUpStatus = "Asking Attaché about \(session.displayTitle)."
        // A fresh attempt (typed question or explicit retry) supersedes any
        // stale recovery banner from a previous failure (INF-254).
        liveFollowUpRecovery = nil

        presentationService.answerFollowUpQuestion(
            card: followUpContextCard(for: session),
            danQuestion: trimmed
        ) { [weak self] result in
            guard let self,
                  self.liveFollowUpAnswerRequestID == requestID else {
                return
            }
            self.isGeneratingLiveFollowUpAnswer = false
            switch result {
            case .success(let answer):
                self.liveFollowUpAnswerText = answer.answerText
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
        answer: CompanionFollowUpAnswerResult
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
        followUpAnswerText = ""
        isGeneratingFollowUpAnswer = false
        followUpStatus = "Ask Attaché about this update."
    }

    private func resetLiveFollowUpAnswerStatus() {
        liveFollowUpAnswerRequestID = nil
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
            metadataJSON: #"{"synthetic":"companion_follow_up_context"}"#,
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
            playback.play(card)
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
        if let next = livePlaybackQueue.replyFinished() {
            playCardLive(cardID: next)
        }
    }

    /// Play a queued live update by id without marking it heard first; heard state
    /// is set in `finishPlayback` only after it actually plays.
    private func playCardLive(cardID: String) {
        reloadCards(select: cardID)
        guard let card = cards.first(where: { $0.id == cardID }) else {
            // The card vanished (archived/deleted); free the slot and move on.
            if let next = livePlaybackQueue.finished() { playCardLive(cardID: next) }
            return
        }
        playback.play(card)
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
    func applyCustomThemeEdit(_ spec: CompanionThemeSpec) {
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
    func createCustomTheme() -> CompanionThemeSpec {
        let base = theme
        let spec = CompanionThemeSpec(
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
    func importCustomTheme(from url: URL) throws -> CompanionThemeSpec {
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
        if let value = defaults.string(forKey: CompanionPreferenceKey.visualMode),
           let mode = CompanionVisualMode(rawValue: value) {
            visualMode = mode
        }
        miniCompanionEnabled = defaults.bool(forKey: CompanionPreferenceKey.miniCompanion)
        miniCompanionClickThrough = defaults.bool(forKey: CompanionPreferenceKey.miniCompanionClickThrough)
        if defaults.object(forKey: CompanionPreferenceKey.petTypesAlong) != nil {
            petTypesAlong = defaults.bool(forKey: CompanionPreferenceKey.petTypesAlong)
        }
        petRareIdles = defaults.bool(forKey: CompanionPreferenceKey.petRareIdles)
        petHoverReaction = defaults.bool(forKey: CompanionPreferenceKey.petHoverReaction)
        if defaults.object(forKey: CompanionPreferenceKey.petFocusAngle) != nil {
            petFocusAngle = defaults.double(forKey: CompanionPreferenceKey.petFocusAngle)
        }
        if let value = defaults.string(forKey: CompanionPreferenceKey.petCharacter),
           let characterChoice = BubblesPetCharacter(rawValue: value) {
            petCharacter = characterChoice
        }
        if let value = defaults.string(forKey: CompanionPreferenceKey.visualSymmetry),
           let symmetry = CompanionVisualSymmetry(rawValue: value) {
            visualSymmetry = symmetry
        }
        if let value = defaults.string(forKey: CompanionPreferenceKey.idleBrand),
           let brand = CompanionIdleBrand(rawValue: value) {
            idleBrand = brand
        }
        if let value = defaults.string(forKey: CompanionPreferenceKey.idleCustomText) {
            idleCustomText = value
        }
        if idleBrand == .customImage {
            loadIdleImageIfNeeded()
        }
        // Custom themes load before the theme selection so a persisted
        // "custom" choice resolves its colors instead of the fallback.
        customThemes = CustomThemeStore.load()
        if let storedID = defaults.string(forKey: CompanionPreferenceKey.customThemeID) {
            activeCustomThemeID = storedID
            CustomThemeStore.activeSpec = customThemes.first { $0.id == storedID }
        }
        if let value = defaults.string(forKey: CompanionPreferenceKey.theme),
           let loadedTheme = CompanionTheme(rawValue: value) {
            theme = loadedTheme
        }
        if let value = defaults.string(forKey: CompanionPreferenceKey.appearanceMode),
           let loadedMode = CompanionAppearanceMode(rawValue: value) {
            appearanceMode = loadedMode
        } else {
            applyAppearance()
        }
        if defaults.object(forKey: CompanionPreferenceKey.surfaceOpacity) != nil {
            surfaceOpacity = min(1.0, max(0.35, defaults.double(forKey: CompanionPreferenceKey.surfaceOpacity)))
        }
        if defaults.object(forKey: CompanionPreferenceKey.brightnessLevel) != nil {
            brightnessLevel = min(2, max(0, defaults.integer(forKey: CompanionPreferenceKey.brightnessLevel)))
        }
        if defaults.object(forKey: CompanionPreferenceKey.visualIntensity) != nil {
            visualIntensity = min(1.8, max(0.3, defaults.double(forKey: CompanionPreferenceKey.visualIntensity)))
        }
        if defaults.object(forKey: CompanionPreferenceKey.seekStepSeconds) != nil {
            seekStepSeconds = min(30, max(2, defaults.integer(forKey: CompanionPreferenceKey.seekStepSeconds)))
        }
        if defaults.object(forKey: CompanionPreferenceKey.captionFontSize) != nil {
            captionFontSize = defaults.double(forKey: CompanionPreferenceKey.captionFontSize)
        }
        if defaults.object(forKey: CompanionPreferenceKey.captionLineCount) != nil {
            captionLineCount = defaults.integer(forKey: CompanionPreferenceKey.captionLineCount)
        }
        if defaults.object(forKey: CompanionPreferenceKey.audioCacheRetentionMinutes) != nil {
            audioCacheRetentionMinutes = defaults.integer(forKey: CompanionPreferenceKey.audioCacheRetentionMinutes)
        } else {
            playback.setAudioCacheRetention(minutes: audioCacheRetentionMinutes)
        }
        if let voiceModeRaw = defaults.string(forKey: CompanionPreferenceKey.voiceInputMode),
           let voiceMode = CompanionVoiceInputMode(rawValue: voiceModeRaw) {
            voiceInputMode = voiceMode
        }
        if let narrationRaw = defaults.string(forKey: CompanionPreferenceKey.narrationDetail),
           let narration = CompanionNarrationDetail(rawValue: narrationRaw) {
            narrationDetail = narration
        }
        if let value = defaults.string(forKey: CompanionPreferenceKey.microphoneDeviceID) {
            microphoneDeviceID = value
        }
        if let renames = defaults.dictionary(forKey: CompanionPreferenceKey.sessionRenames) as? [String: String] {
            sessionRenames = renames
        }
        if defaults.object(forKey: CompanionPreferenceKey.codexSourceEnabled) != nil {
            codexSourceEnabled = defaults.bool(forKey: CompanionPreferenceKey.codexSourceEnabled)
        }
        if defaults.object(forKey: CompanionPreferenceKey.claudeCodeSourceEnabled) != nil {
            claudeCodeSourceEnabled = defaults.bool(forKey: CompanionPreferenceKey.claudeCodeSourceEnabled)
        }
        if let raw = defaults.string(forKey: CompanionPreferenceKey.agentInstructionSendPolicy),
           let policy = AgentInstructionSendPolicy(rawValue: raw) {
            agentInstructionSendPolicy = policy
        }
        loadWatchedSessions()
        if defaults.object(forKey: CompanionPreferenceKey.captionsEnabled) != nil {
            captionsEnabled = defaults.bool(forKey: CompanionPreferenceKey.captionsEnabled)
        }
        if defaults.object(forKey: CompanionPreferenceKey.uiTextScale) != nil {
            uiTextScale = AttacheTypeScale.clamp(defaults.double(forKey: CompanionPreferenceKey.uiTextScale))
        }
        // A pending resume step (set by the mid-onboarding voice relaunch)
        // reopens the sheet even when a previous run was completed, so the
        // Help-menu re-run path resumes too.
        showOnboarding = !defaults.bool(forKey: CompanionPreferenceKey.onboardingCompleted)
            || defaults.object(forKey: CompanionPreferenceKey.onboardingResumeStep) != nil
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.detectNewlyDownloadedVoice()
        }
        if defaults.object(forKey: CompanionPreferenceKey.lowLatencyCaptions) != nil {
            lowLatencyCaptions = defaults.bool(forKey: CompanionPreferenceKey.lowLatencyCaptions)
        }
        if let value = defaults.string(forKey: CompanionPreferenceKey.spokenLanguage) {
            spokenLanguage = CompanionCaptionLanguage.named(value).id
        }
        if defaults.object(forKey: CompanionPreferenceKey.onDeviceOnly) != nil {
            onDeviceOnly = defaults.bool(forKey: CompanionPreferenceKey.onDeviceOnly)
        }
        if defaults.object(forKey: CompanionPreferenceKey.voicemailMode) != nil {
            voicemailMode = defaults.bool(forKey: CompanionPreferenceKey.voicemailMode)
        }
        if defaults.object(forKey: CompanionPreferenceKey.autoHideControls) != nil {
            autoHideControls = defaults.bool(forKey: CompanionPreferenceKey.autoHideControls)
        }
        if defaults.object(forKey: CompanionPreferenceKey.autoHideDelaySeconds) != nil {
            let value = defaults.double(forKey: CompanionPreferenceKey.autoHideDelaySeconds)
            if value >= 1, value <= 8 { autoHideDelaySeconds = value }
        }
        if defaults.object(forKey: CompanionPreferenceKey.showPersonalityNameInDock) != nil {
            showPersonalityNameInDock = defaults.bool(forKey: CompanionPreferenceKey.showPersonalityNameInDock)
        }
        if let value = defaults.string(forKey: CompanionPreferenceKey.notifyScope),
           let scope = CompanionNotifyScope(rawValue: value) {
            notifyScope = scope
        }
        if defaults.object(forKey: CompanionPreferenceKey.showInMenuBar) != nil {
            showInMenuBar = defaults.bool(forKey: CompanionPreferenceKey.showInMenuBar)
        }
        if defaults.object(forKey: CompanionPreferenceKey.playbackSpeed) != nil {
            playbackSpeed = min(1.6, max(0.8, defaults.double(forKey: CompanionPreferenceKey.playbackSpeed)))
        }
        if defaults.object(forKey: CompanionPreferenceKey.showTips) != nil {
            showTips = defaults.bool(forKey: CompanionPreferenceKey.showTips)
        }
        if defaults.object(forKey: CompanionPreferenceKey.installClaudeHooks) != nil {
            installClaudeHooks = defaults.bool(forKey: CompanionPreferenceKey.installClaudeHooks)
        }
        if defaults.object(forKey: CompanionPreferenceKey.showPersonalitySwitcher) != nil {
            showPersonalitySwitcher = defaults.bool(forKey: CompanionPreferenceKey.showPersonalitySwitcher)
        }
        if defaults.object(forKey: CompanionPreferenceKey.showActivityInsights) != nil {
            showActivityInsights = defaults.bool(forKey: CompanionPreferenceKey.showActivityInsights)
        }
        if defaults.object(forKey: CompanionPreferenceKey.captionSyncOffsetMs) != nil {
            captionSyncOffsetMs = min(10_000, max(-2_000, defaults.integer(forKey: CompanionPreferenceKey.captionSyncOffsetMs)))
        }
        // The migration reads the keychain, and a keychain read can block on a
        // SecurityAgent authorization (first launch after the app bundle is
        // replaced). Running it inline here left the app alive with no window
        // until the dialog was answered, so it runs once, off the launch path.
        if !defaults.bool(forKey: CompanionPreferenceKey.legacyKeyMigrationDone) {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.migrateLegacyPresentationKeys()
                DispatchQueue.main.async {
                    self?.defaults.set(true, forKey: CompanionPreferenceKey.legacyKeyMigrationDone)
                }
            }
        }
        // Loads the main Settings > Model row state, which is the shared
        // "main model" any role with no per-role override falls back to;
        // .conversation is the reasonable placeholder role for that row (see
        // the same call in loadPresentationModels, and roleModelProvider/D3
        // for the per-role overrides loaded just below).
        let presentationSettings = CompanionPresentationSettings.load(
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
        if defaults.object(forKey: CompanionPreferenceKey.conversationFallbackChainEnabled) != nil {
            conversationFallbackChainEnabled = defaults.bool(forKey: CompanionPreferenceKey.conversationFallbackChainEnabled)
        }
        conversationFallbackChain = ((defaults.array(forKey: CompanionPreferenceKey.conversationFallbackChainProviders) as? [String]) ?? [])
            .compactMap(CompanionPresentationProvider.init(rawValue:))
        // Needs presentationProvider loaded above (it credits whatever
        // provider was configured at migration time); pure defaults
        // read/write, so unlike migrateLegacyPresentationKeys it's safe
        // inline on the launch path.
        migrateCloudConsentToPerProvider()
        if let value = defaults.string(forKey: CompanionPreferenceKey.speechProvider),
           let provider = CompanionSpeechProvider(rawValue: value) {
            speechProvider = provider
        }
        if let value = defaults.string(forKey: CompanionPreferenceKey.ollamaBaseURL), !value.isEmpty { ollamaBaseURL = value }
        if let value = defaults.string(forKey: CompanionPreferenceKey.lmStudioBaseURL), !value.isEmpty { lmStudioBaseURL = value }
        if let value = defaults.string(forKey: CompanionPreferenceKey.customBaseURL), !value.isEmpty { customBaseURL = value }
        if let value = defaults.string(forKey: CompanionPreferenceKey.elevenLabsModelID),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            elevenLabsModelID = value
        }
        if let value = defaults.string(forKey: CompanionPreferenceKey.elevenLabsOutputFormat),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            elevenLabsOutputFormat = value
        }
        if let value = defaults.string(forKey: CompanionPreferenceKey.xaiBaseURL),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            xaiBaseURL = value
        }
        if let value = defaults.string(forKey: CompanionPreferenceKey.xaiLanguage),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            xaiLanguage = value
        }
        loadStoredSecretsAsync(presentationAccount: presentationSettings.provider.developmentSecretAccount)
        speechVoiceOptions = CompanionVoiceCatalog.options()
        if let savedVoice = defaults.string(forKey: CompanionPreferenceKey.speechVoiceIdentifier) {
            let trimmed = savedVoice.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == Self.systemVoicePreference || trimmed.isEmpty {
                speechVoiceIdentifier = nil
            } else if trimmed == Self.legacyAutoSelectedSamanthaVoiceID,
                      !defaults.bool(forKey: CompanionPreferenceKey.legacySamanthaDefaultMigrated) {
                defaults.set(true, forKey: CompanionPreferenceKey.legacySamanthaDefaultMigrated)
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
        if let savedFocus = defaults.string(forKey: CompanionPreferenceKey.attachedCodexSessionID),
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
            let groq = self.readConfiguredSecret(account: CompanionPresentationProvider.groq.developmentSecretAccount) ?? ""
            let custom = self.readConfiguredSecret(account: CompanionPresentationProvider.custom.developmentSecretAccount) ?? ""
            let openai = self.readConfiguredSecret(account: Self.openaiDevelopmentSecretAccount) ?? ""
            DispatchQueue.main.async {
                self.presentationAPIKey = presentation
                self.elevenLabsAPIKey = elevenLabs
                self.xaiAPIKey = xai
                self.groqAPIKey = groq
                self.customAPIKey = custom
                self.openaiVoiceAPIKey = openai
                self.applyStoredCloudVoicePreferences()
            }
        }
    }

    /// Voice preferences that only make sense once the matching cloud key is
    /// present, applied after the stored secrets finish loading.
    private func applyStoredCloudVoicePreferences() {
        let hasElevenLabsKey = !elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasXAIKey = !xaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasOpenAIKey = !effectiveOpenAIVoiceKey.isEmpty

        if hasElevenLabsKey, let value = defaults.string(forKey: CompanionPreferenceKey.elevenLabsVoiceID) {
            elevenLabsVoiceID = value
        }
        if hasElevenLabsKey, let value = defaults.string(forKey: CompanionPreferenceKey.elevenLabsVoiceName) {
            elevenLabsVoiceName = value
        }
        if hasXAIKey, let value = defaults.string(forKey: CompanionPreferenceKey.xaiVoiceID),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            xaiVoiceID = value
        }
        if hasXAIKey, let value = defaults.string(forKey: CompanionPreferenceKey.xaiVoiceName),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            xaiVoiceName = value
        }
        if hasOpenAIKey, let value = defaults.string(forKey: CompanionPreferenceKey.openaiVoiceID),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            openaiVoiceID = value
        }
        if hasOpenAIKey, let value = defaults.string(forKey: CompanionPreferenceKey.openaiVoiceName),
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
            onDeviceOnly: onDeviceOnly,
            lowLatency: lowLatencyCaptions,
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

    private var selectedSpeechConfiguration: CompanionSpeechConfiguration {
        CompanionSpeechConfiguration(
            provider: speechProvider,
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

    private func applySpeechConfiguration() {
        playback.configureVoice(
            configuration: selectedSpeechConfiguration.resolvedForPlayback(
                systemVoiceIdentifier: speechVoiceIdentifier
            )
        )
        if !cards.isEmpty {
            prepareUnreadVoicemailAudio()
        }
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
        liveFollowUpText = ""
        resetLiveFollowUpAnswerStatus()
        updateCodexWatcher()
    }

    /// The simulator's focus override (INF-284): which fabricated session the
    /// user last clicked on the ring. Consumed by ActivitySimulatorPanel.
    @Published var simulatedFleetFocusID: String?

    /// Mini companion size requests from its context menu (INF-286); the
    /// window controller applies them, keeping frame persistence intact.
    let miniCompanionResize = PassthroughSubject<NSSize, Never>()

    /// Remove a session from the watch list (stop collecting its voicemail).
    func detachCodexSession(_ id: String) {
        attachedTargets.removeValue(forKey: id)
        if attachedCodexSessionID == id { attachedCodexSessionID = attachedSessionList.first?.id }
        updateCodexWatcher()
    }

    private func persistWatchedSessions() {
        let sessions = attachedSessionList
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        defaults.set(data, forKey: CompanionPreferenceKey.watchedSessions)
    }

    private func loadWatchedSessions() {
        guard let data = defaults.data(forKey: CompanionPreferenceKey.watchedSessions),
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
            if updateStatus {
                intakeStatus = "Moved automation focus to active Codex session \(activeRun.displayTitle)."
            }
        } else {
            self.attachedCodexSessionID = nil
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
