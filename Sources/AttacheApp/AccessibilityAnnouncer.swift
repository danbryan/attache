import AppKit

/// Posts VoiceOver announcements (INF-356 step 4). No existing announcement
/// call site was found elsewhere in the app to follow, so this uses Apple's
/// standard `NSAccessibility.post(element:notification:userInfo:)` pattern
/// directly against the app object, which VoiceOver honors regardless of
/// which window is key.
enum AccessibilityAnnouncer {
    static func announce(_ message: String) {
        guard !message.isEmpty else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}
