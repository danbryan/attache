import AttacheCore
import Foundation

/// The immutable authority boundary for one model request (INF-304).
///
/// Captured on the calling actor before any async model, retrieval, fallback,
/// preview, recap, tagging, another-take, or follow-up work begins. Every
/// user-facing role reads the personality, prompt, memory scope, user input,
/// and session authorization from this frozen value, never from live global
/// state. A personality or focus switch during an in-flight request cannot
/// mutate it; the next request captures a fresh snapshot.
///
/// The personality is a value type, so copying it here freezes its id, name,
/// prompt, model, reasoning, and presence. The session authorization is either
/// context-free (no work-session evidence or tools) or a frozen focused
/// session. Reverse-send destinations are a separate safety object.
struct AttacheRequestSnapshot: Equatable {
    let requestID: String
    let capturedAt: Date
    let role: AttacheRequestRole
    let personality: Personality
    let profilePrompt: String
    let userInput: String
    let session: AttacheSessionAuthorization
    /// The exact resolved provider/model configuration captured before async
    /// work begins. `nil` is an explicit unavailable state, never permission
    /// for a service to reload mutable global defaults later.
    let modelSettings: AttachePresentationSettings?
    /// Already selected and policy-filtered evidence from app-owned stores.
    /// The service never reopens a memory file, transcript, session index, or
    /// other mutable context source after this snapshot is captured (INF-338).
    let contextItems: [AttacheContextItem]
    /// The resolved per-personality/app strategy, frozen with the request.
    let contextStrategy: AttacheContextStrategy
    /// Content-free memory-selection decisions made before compilation,
    /// including local-only and scope exclusions that never enter a prompt.
    let memorySelectionReceipt: [AttacheMemoryReceiptEntry]
    /// The exact, call-scoped suffix of direct-chat turns selected before any
    /// async work begins. Older turns are represented by bounded summary items
    /// in `contextItems`; neither collection is allowed to cross a hang-up.
    let directChatMessages: [AttacheChatMessage]
    /// Per-message egress provenance for the exact direct-chat suffix. This is
    /// frozen beside the bytes so a later remote fallback cannot launder an
    /// assistant answer that was derived from local-only memory.
    let directChatMessageSources: [AttachePrebuiltMessageSource]

    var isFocused: Bool { session.isFocused }
    var personalityID: String { personality.id }
    var personalityName: String { personality.name }

    var focusedSession: AttacheFocusedSession? { session.focusedSession }

    /// Compatibility view for prompt builders while AppModel migrates to
    /// compiler-native evidence. It is derived only from frozen selected items;
    /// the service never loads its own memory authority.
    var memoryContext: String? {
        let selected = contextItems
            .filter { $0.source == .durableMemory }
            .map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return selected.isEmpty ? nil : selected.joined(separator: "\n")
    }

    init(
        requestID: String = UUID().uuidString,
        capturedAt: Date = Date(),
        role: AttacheRequestRole,
        personality: Personality,
        profilePrompt: String,
        userInput: String,
        session: AttacheSessionAuthorization,
        modelSettings: AttachePresentationSettings?,
        contextItems: [AttacheContextItem],
        contextStrategy: AttacheContextStrategy,
        memorySelectionReceipt: [AttacheMemoryReceiptEntry] = [],
        directChatMessages: [AttacheChatMessage] = [],
        directChatMessageSources: [AttachePrebuiltMessageSource] = []
    ) {
        self.requestID = requestID
        self.capturedAt = capturedAt
        self.role = role
        self.personality = personality
        self.profilePrompt = profilePrompt
        self.userInput = userInput
        self.session = session
        self.modelSettings = modelSettings
        self.contextItems = contextItems
        self.contextStrategy = contextStrategy
        self.memorySelectionReceipt = memorySelectionReceipt
        self.directChatMessages = directChatMessages
        self.directChatMessageSources = directChatMessageSources
    }

    /// Rebuild only the compiler strategy for an explicit overflow retry.
    /// Authority, model settings, personality, selected memory, direct-chat
    /// suffix, and the user's exact draft remain frozen byte-for-byte.
    func retryingOverflow(with strategy: AttacheContextStrategy) -> AttacheRequestSnapshot {
        AttacheRequestSnapshot(
            requestID: requestID,
            capturedAt: capturedAt,
            role: role,
            personality: personality,
            profilePrompt: profilePrompt,
            userInput: userInput,
            session: session,
            modelSettings: modelSettings,
            contextItems: contextItems,
            contextStrategy: strategy,
            memorySelectionReceipt: memorySelectionReceipt,
            directChatMessages: directChatMessages,
            directChatMessageSources: directChatMessageSources
        )
    }

    /// Transitional initializer for existing tests and the root wiring pass.
    /// It converts the already-frozen string into a structured item immediately;
    /// no service path can use it to read mutable memory later.
    init(
        requestID: String = UUID().uuidString,
        capturedAt: Date = Date(),
        role: AttacheRequestRole,
        personality: Personality,
        profilePrompt: String,
        memoryContext: String?,
        userInput: String,
        session: AttacheSessionAuthorization,
        modelSettings: AttachePresentationSettings? = nil,
        contextStrategy: AttacheContextStrategy = .automatic
    ) {
        let memoryItems: [AttacheContextItem]
        if let memory = memoryContext?.trimmingCharacters(in: .whitespacesAndNewlines),
           !memory.isEmpty {
            memoryItems = [AttacheContextItem(
                source: .durableMemory,
                content: memory,
                provenance: "frozen-legacy-memory-selection",
                priority: 500,
                treatment: .headTailExcerpt
            )]
        } else {
            memoryItems = []
        }
        self.init(
            requestID: requestID,
            capturedAt: capturedAt,
            role: role,
            personality: personality,
            profilePrompt: profilePrompt,
            userInput: userInput,
            session: session,
            modelSettings: modelSettings,
            contextItems: memoryItems,
            contextStrategy: contextStrategy,
            memorySelectionReceipt: [],
            directChatMessages: [],
            directChatMessageSources: []
        )
    }
}
