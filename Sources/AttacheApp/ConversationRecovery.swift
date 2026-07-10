import AttacheCore
import Foundation

struct ConversationRecovery: Equatable {
    let category: ConversationFailureCategory
    let failedPrompt: String
    let errorMessage: String

    var offersModelSwitch: Bool {
        category == .usageOrRateLimit || category == .modelUnavailable
    }

    /// Classifies a failed conversation call structurally where possible
    /// (HTTP status, URLError code) and only falls back to string-marker
    /// matching for CLI providers, whose failures arrive as plain text with
    /// no HTTP status.
    ///
    /// Precedence: 429/402 -> usageOrRateLimit; 404 or 400-with-model-marker
    /// -> modelUnavailable; timeout/connection-lost or 5xx -> transient;
    /// 401/403 -> auth; then (CLI providers only) the legacy text markers;
    /// otherwise `.other`.
    static func classify(
        errorMessage: String,
        failedPrompt: String,
        httpStatus: Int? = nil,
        urlErrorCode: URLError.Code? = nil,
        isCLIProvider: Bool = false
    ) -> ConversationRecovery {
        let normalized = errorMessage.lowercased()
        let usageMarkers = [
            "usage limit", "usage_limit", "rate limit", "rate_limit", "quota", "too many requests",
            "resource exhausted", "insufficient credits", "credit balance"
        ]
        let modelMarkers = [
            "model is unavailable", "model unavailable", "model_not_found",
            "model does not exist", "model is not supported", "requires a newer version", "unsupported model"
        ]
        let transientURLErrorCodes: Set<URLError.Code> = [
            .timedOut,
            .networkConnectionLost,
            .notConnectedToInternet,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed
        ]

        let category: ConversationFailureCategory
        if let status = httpStatus, status == 429 || status == 402 {
            category = .usageOrRateLimit
        } else if let status = httpStatus,
                  status == 404 || (status == 400 && modelMarkers.contains(where: normalized.contains)) {
            category = .modelUnavailable
        } else if let code = urlErrorCode, transientURLErrorCodes.contains(code) {
            category = .transient
        } else if let status = httpStatus, (500..<600).contains(status) {
            category = .transient
        } else if let status = httpStatus, status == 401 || status == 403 {
            category = .auth
        } else if isCLIProvider, usageMarkers.contains(where: normalized.contains) {
            category = .usageOrRateLimit
        } else if isCLIProvider, modelMarkers.contains(where: normalized.contains) {
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
