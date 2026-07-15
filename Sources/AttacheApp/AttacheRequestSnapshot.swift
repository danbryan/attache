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
    let role: AttacheRequestRole
    let personality: Personality
    let profilePrompt: String
    let memoryContext: String?
    let userInput: String
    let session: AttacheSessionAuthorization

    var isFocused: Bool { session.isFocused }
    var personalityID: String { personality.id }
    var personalityName: String { personality.name }

    var focusedSession: AttacheFocusedSession? { session.focusedSession }
}