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
    @Published private(set) var conversationElapsedSeconds: Int = 0
    @Published private(set) var pendingAssistantReply: String?
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
    @Published var showActivityInsights: Bool = false {
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
    @Published var presentationProvider: CompanionPresentationProvider = .ollama {
        didSet {
            defaults.set(presentationProvider.rawValue, forKey: CompanionPreferenceKey.presentationLLMProvider)
            refreshPresentationStatus()
        }
    }
    @Published var presentationBaseURL: String = CompanionPresentationProvider.ollama.defaultBaseURL {
        didSet {
            defaults.set(presentationBaseURL, forKey: CompanionPreferenceKey.presentationLLMBaseURL)
            refreshPresentationStatus()
        }
    }
    @Published var presentationModel: String = CompanionPresentationProvider.ollama.defaultModel {
        didSet {
            defaults.set(presentationModel, forKey: CompanionPreferenceKey.presentationLLMModel)
            refreshPresentationStatus()
        }
    }
    @Published var presentationReasoningEffort: String = CompanionPresentationProvider.ollama.defaultReasoningEffort {
        didSet {
            defaults.set(presentationReasoningEffort, forKey: CompanionPreferenceKey.presentationReasoningEffort)
            refreshPresentationStatus()
        }
    }
    @Published var presentationServiceTier: String = "default" {
        didSet {
            defaults.set(presentationServiceTier, forKey: CompanionPreferenceKey.presentationServiceTier)
            refreshPresentationStatus()
        }
    }
    @Published var presentationAPIKey: String = ""
    @Published var presentationAPIKeySecretRef: String = "" {
        didSet {
            defaults.set(presentationAPIKeySecretRef, forKey: CompanionPreferenceKey.presentationLLMAPIKeySecretRef)
            refreshPresentationStatus()
        }
    }
    @Published private(set) var presentationModelOptions: [CompanionPresentationModelOption] = []
    @Published private(set) var presentationModelDiscoveryStatus: String = "Model discovery not checked"
    @Published private(set) var presentationStatus: String = "Presentation LLM not checked"
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
    private var expectingReplyAudio = false
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
            locateSessionFile: { CompanionSessionReader.sessionFileURL(forSessionID: $0) }
        )
        if let recoveryMessage = twoWay.startupRecoveryMessage {
            intakeStatus = recoveryMessage
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
        rebuildSessionIndexer()
        sessionRecords = filteredEnabledRecords(sessionIndexer.allRecords)
        refreshSessionIndex()
        codexSessionWatcher.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.receive(event)
            }
        }
        codexSessionWatcher.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                self?.intakeStatus = status
            }
        }
        codexSessionWatcher.onAttention = { [weak self] sessionID, state in
            DispatchQueue.main.async {
                self?.handleAttentionChange(sessionID: sessionID, state: state)
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
            intakeStatus = "Listening on \(serverURLText)."
        } catch {
            intakeStatus = "Event intake blocked: \(error.localizedDescription)"
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
                sessionAttention[sessionID] = .awaitingAnswer
            }
            persistNeedsYouNotice(event: notice, line: event.text)
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
    func handleAttentionChange(sessionID: String, state: SessionAttentionState) {
        let previous = sessionAttention[sessionID]
        if state == .quiet {
            sessionAttention.removeValue(forKey: sessionID)
        } else {
            sessionAttention[sessionID] = state
        }
        let wasNeeding = previous?.needsUser ?? false
        if state.needsUser, !wasNeeding {
            fileNeedsYouNotice(sessionID: sessionID, state: state)
        } else if !state.needsUser, wasNeeding {
            resolveNeedsYouNotices(sessionID: sessionID)
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
        let presented: NormalizedEvent = await withCheckedContinuation { continuation in
            presentationService.prepare(event, personality: personality) { presentedEvent in
                continuation.resume(returning: presentedEvent)
            }
        }
        // persist() mutates observed @Published state (the card list, playback
        // queue, intake status). It runs from a background Task here, so it must
        // hop to the main actor: mutating @Published off-main makes SwiftUI flush
        // a transaction synchronously and re-enter body, overflowing the stack.
        await MainActor.run { persist(presented) }
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

        let summarized = cards
        guard !summarized.isEmpty else {
            playback.preview(inboxDigestText(for: summarized))
            return
        }

        guard presentationService.isPresentationConfigured else {
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
            let recapText = await self?.presentationService.complete(system: system, user: user)
            // persist/play mutate @Published state and the store, so hop back to
            // the main actor before touching either (mutating observed state
            // off-main re-enters SwiftUI's body and overflows the stack).
            await MainActor.run {
                guard let self else { return }
                let trimmed = CompanionPersonality.stripDashes(recapText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                guard !trimmed.isEmpty else {
                    // The LLM was configured but returned nothing usable: fall
                    // back to the deterministic digest and leave the inbox as is.
                    self.playback.preview(self.inboxDigestText(for: summarized))
                    self.intakeStatus = "Recap unavailable; played the quick digest instead."
                    return
                }
                self.deliverRecap(trimmed, summarizing: summarized, personality: personality)
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

        removeFailedTurnsBeforeRetry()
        conversationRecovery = nil
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

        let context = conversationTargetSnapshot
        let messages = buildConversationMessages(context: context)
        let sessionID = context?.target.id
        let workingDirectory = context?.workingDirectory
        let agentTarget = context?.agentSendTarget
        let allowAgentInstructionTool = agentTarget != nil

        presentationService.converse(
            messages: messages,
            allowAgentInstructionTool: allowAgentInstructionTool,
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
                    self.surfaceConversationReply(reply)
                case .failure(let error):
                    let errorMessage = error.localizedDescription
                    let message = "I hit a problem: \(errorMessage)"
                    let recovery = ConversationRecovery.classify(
                        errorMessage: errorMessage,
                        failedPrompt: trimmed
                    )
                    self.conversationRecovery = recovery
                    self.conversationStatus = errorMessage
                    self.appendConversationTurn(role: .assistant, text: message)
                    if recovery.offersModelSwitch {
                        // Preserve the user's exact words. Switching only changes
                        // the selected brain; retry remains an explicit action.
                        self.conversationDraft = trimmed
                        self.loadPresentationModels(preserveCurrentSelection: true)
                    } else {
                        self.maybeResumeContinuousListening()
                    }
                }
            }
        )
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
        selectPresentationModel(option)
        conversationDestination = .attache
        conversationStatus = "Switched to \(presentationProvider.title) \(option.id). Review the restored draft, then retry."
    }

    func selectConversationRecoveryProvider(_ provider: CompanionPresentationProvider) {
        selectPresentationProvider(provider)
        selectPresentationModelID(provider.defaultModel)
        conversationDestination = .attache
        conversationStatus = "Switched to \(provider.title) \(presentationModel). Review the restored draft, then retry."
        loadPresentationModels()
    }

    func retryConversationAfterFailure() {
        guard let recovery = conversationRecovery, !isAwaitingReply else { return }
        let editedDraft = conversationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        sendConversationMessage(editedDraft.isEmpty ? recovery.failedPrompt : editedDraft)
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

    private func surfaceConversationReply(_ reply: String) {
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
        _ = persistConversationReply(trimmed)
        playback.preview(trimmed)
        revealTimer?.invalidate()
        revealTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            self?.revealPendingReply()
        }
    }

    private func persistConversationReply(_ reply: String) -> VoicemailCard? {
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
                targetDisplayName: pending.target.displayTitle
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

    private func handleTwoWayDeliveryChanges(_ changed: [Instruction]) {
        guard let latest = changed.sorted(by: { $0.createdAt < $1.createdAt }).last else { return }
        switch latest.state {
        case .delivered:
            let target = latest.targetDisplayName ?? "agent"
            let message = "Sent to \(target). Watching for the reply…"
            intakeStatus = message
            liveFollowUpStatus = message
            if conversationActive { conversationStatus = message }
        case .failed:
            let reason = latest.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = reason.isEmpty ? "Send failed." : "Send failed: \(reason)"
            intakeStatus = message
            liveFollowUpStatus = message
            if conversationActive { conversationStatus = message }
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
            canStageAgentInstruction: context?.agentSendTarget != nil
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
    private func applyStageAgentInstructionTool(
        arguments: String,
        target: AgentSendTarget?,
        sourceUtterance: String
    ) async -> String {
        guard let instruction = Self.agentInstruction(fromToolArguments: arguments) else {
            return "No instruction was provided to stage for the agent."
        }
        guard let target else {
            return "No agent session was explicitly focused when this conversation turn began."
        }
        // Freeze the complete send before crossing back to the UI actor. The
        // structured tool payload must never be recomputed from mutable call UI.
        let pending = PendingAgentSend(
            text: instruction,
            target: target,
            origin: .personalityTool,
            sourceUtterance: sourceUtterance
        )
        return await MainActor.run { [pending] in
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
        guard let decoded = try? JSONDecoder().decode(
            AgentInstructionToolArguments.self,
            from: Data(arguments.utf8)
        ) else { return nil }
        let instruction = decoded.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return instruction.isEmpty ? nil : instruction
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

    /// One-time acknowledgment that cloud presentation/voice providers send data
    /// off the Mac. Keyed by category so a user acknowledges once per category.
    var cloudConsentPresentationAcknowledged: Bool {
        get { defaults.bool(forKey: CompanionPreferenceKey.cloudConsentPresentation) }
        set { defaults.set(newValue, forKey: CompanionPreferenceKey.cloudConsentPresentation) }
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

    func loadPresentationModels(preserveCurrentSelection: Bool = false) {
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
            return
        }

        presentationModelDiscoveryStatus = "Loading \(provider.title) models..."
        Task {
            do {
                let key: String
                if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    key = apiKey
                } else {
                    let settings = CompanionPresentationSettings.load(
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
                await MainActor.run {
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
                await MainActor.run {
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
        activePersonalityID = id
        personalityStore.save(personalities, activeID: id)
        writeActivePersonalityToDefaults()
        refreshPresentationStatus()
        intakeStatus = "Personality set to \(activePersonality?.name ?? "Attaché")."
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
        selectPersonality(personalities[nextIndex].id)
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
            prompt: source.prompt
        )
        if let index = personalities.firstIndex(where: { $0.id == id }) {
            personalities.insert(copy, at: index + 1)
        } else {
            personalities.append(copy)
        }
        selectPersonality(copy.id)
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
    }

    func selectElevenLabsVoice(_ voice: RemoteVoiceOption) {
        speechProvider = .elevenLabs
        elevenLabsVoiceID = voice.id
        elevenLabsVoiceName = voice.name
        intakeStatus = "ElevenLabs voice set to \(voice.name)."
        previewAssistantVoice()
    }

    func selectXAIVoice(_ voice: RemoteVoiceOption) {
        speechProvider = .xai
        xaiVoiceID = voice.id
        xaiVoiceName = voice.name
        intakeStatus = "xAI voice set to \(voice.name)."
        previewAssistantVoice()
    }

    func selectOpenAIVoice(_ voice: RemoteVoiceOption) {
        speechProvider = .openai
        openaiVoiceID = voice.id
        openaiVoiceName = voice.name
        intakeStatus = "OpenAI voice set to \(voice.name)."
        previewAssistantVoice()
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
            // Deliver any confirmed instruction whose session has gone quiet. Run on
            // the main actor so the shared store is never touched off-main.
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
        guard !isTaggingSessions, presentationService.isPresentationConfigured else { return }
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
                let reply = await self.presentationService.complete(
                    system: SessionTagger.systemPrompt,
                    user: SessionTagger.userPrompt(for: items, knownTags: Array(vocabulary))
                )
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
            case .failure(let error):
                self.followUpStatus = "Answer failed for \(target): \(error.localizedDescription)"
            }
        }
    }

    func clearFollowUpAnswer() {
        followUpAnswerRequestID = nil
        followUpAnswerText = ""
        isGeneratingFollowUpAnswer = false
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
            case .failure(let error):
                self.liveFollowUpStatus = "Answer failed for \(target): \(error.localizedDescription)"
            }
        }
    }

    func clearLiveFollowUpAnswer() {
        liveFollowUpAnswerRequestID = nil
        liveFollowUpAnswerText = ""
        isGeneratingLiveFollowUpAnswer = false
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
        let presentationSettings = CompanionPresentationSettings.load(
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
        if showActivityInsights,
           let focusedID = attachedCodexSession?.id,
           let focusedTarget = enabledTargets.first(where: { $0.id == focusedID }) {
            sessionActivityWatcher.watch([focusedTarget])
        } else {
            sessionActivityWatcher.stop()
        }
    }

    /// Switch which attached session is focused, without changing the watch list.
    func focusCodexSession(_ id: String) {
        guard attachedTargets[id] != nil, id != attachedCodexSessionID else { return }
        attachedCodexSessionID = id
        liveFollowUpText = ""
        resetLiveFollowUpAnswerStatus()
        updateCodexWatcher()
    }

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
