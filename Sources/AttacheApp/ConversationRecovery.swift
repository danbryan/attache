import Foundation

enum ConversationFailureCategory: Equatable {
    case usageOrRateLimit
    case modelUnavailable
    case other
}

struct ConversationRecovery: Equatable {
    let category: ConversationFailureCategory
    let failedPrompt: String
    let errorMessage: String

    var offersModelSwitch: Bool {
        category == .usageOrRateLimit || category == .modelUnavailable
    }

    static func classify(errorMessage: String, failedPrompt: String) -> ConversationRecovery {
        let normalized = errorMessage.lowercased()
        let usageMarkers = [
            "usage limit", "usage_limit", "rate limit", "rate_limit", "quota", "too many requests",
            "resource exhausted", "insufficient credits", "credit balance"
        ]
        let modelMarkers = [
            "model is unavailable", "model unavailable", "model_not_found",
            "model does not exist", "model is not supported", "requires a newer version", "unsupported model"
        ]
        let category: ConversationFailureCategory
        if usageMarkers.contains(where: normalized.contains) {
            category = .usageOrRateLimit
        } else if modelMarkers.contains(where: normalized.contains) {
            category = .modelUnavailable
        } else {
            category = .other
        }
        return ConversationRecovery(
            category: category,
            failedPrompt: failedPrompt,
            errorMessage: errorMessage
        )
    }
}
