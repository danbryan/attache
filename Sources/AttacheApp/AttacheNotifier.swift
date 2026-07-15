import AttacheCore
import AppKit
import Foundation
import UserNotifications

/// What kind of alert a notification carries; maps to an honest interruption
/// level. Needs-you is time-sensitive (degrades to active without the
/// entitlement), everything else is active. Nothing is ever critical.
enum AttacheAlertKind {
    case recap
    case needsYou

    var interruptionLevel: UNNotificationInterruptionLevel {
        switch self {
        case .needsYou: return .timeSensitive
        case .recap: return .active
        }
    }
}

/// What the user wants banners for. Scheduling and quiet hours are
/// deliberately NOT duplicated here: macOS Focus profiles and Do Not Disturb
/// govern delivery of everything this app posts.
enum AttacheNotifyScope: String, CaseIterable, Identifiable {
    case needsYouOnly
    case allUpdates
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .needsYouOnly: return "Needs-you only"
        case .allUpdates: return "All updates"
        case .off: return "Off"
        }
    }

    var allowsRecaps: Bool { self == .allUpdates }
    var allowsNeedsYou: Bool { self != .off }
}

/// Posts local notifications for updates that queue silently in Voicemail mode,
/// so the user knows something is waiting without it speaking over their audio.
/// All delivery is system-gated: Focus profiles and DND decide whether a banner
/// shows; the app never builds its own quiet-hours machinery.
final class AttacheNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AttacheNotifier()

    static let categoryIdentifier = "attache.card"
    static let playActionIdentifier = "attache.play"
    static let inboxActionIdentifier = "attache.inbox"
    static let focusActionIdentifier = "attache.focus"

    private override init() { super.init() }

    /// Call once at launch: installs the delegate and the card category with
    /// its actions so banner buttons work even from a cold start.
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let play = UNNotificationAction(identifier: Self.playActionIdentifier, title: "Play")
        let inbox = UNNotificationAction(identifier: Self.inboxActionIdentifier, title: "Open Inbox")
        let focus = UNNotificationAction(identifier: Self.focusActionIdentifier, title: "Focus Session")
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [play, inbox, focus],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }

    // The app's own window is the surface while it is frontmost; banners are
    // for when the user is elsewhere.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        DispatchQueue.main.async {
            completionHandler(NSApp.isActive ? [] : [.banner, .badge])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let cardID = userInfo["cardID"] as? String
        let sessionID = userInfo["sessionID"] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            switch action {
            case Self.playActionIdentifier:
                if let cardID {
                    NotificationCenter.default.post(name: .attachePlayCard, object: cardID)
                }
            case Self.focusActionIdentifier:
                if let sessionID, !sessionID.isEmpty {
                    NotificationCenter.default.post(name: .attacheFocusSession, object: sessionID)
                }
            default:
                NotificationCenter.default.post(name: .attacheOpenInbox, object: nil)
            }
            completionHandler()
        }
    }

    /// UI automation must never trigger OS permission prompts; they steal
    /// focus and cannot be driven (ATTACHE_UI_TEST).
    private var suppressPromptsForUITest: Bool {
        ProcessInfo.processInfo.environment["ATTACHE_UI_TEST"] != nil
    }

    struct BadgePermissionState {
        var canUseNativeBadge: Bool
        var shouldOpenSystemSettings: Bool
    }

    func requestAuthorizationIfUndetermined(completion: ((BadgePermissionState) -> Void)? = nil) {
        guard !suppressPromptsForUITest else {
            completion?(BadgePermissionState(canUseNativeBadge: false, shouldOpenSystemSettings: false))
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                completion?(Self.badgePermissionState(from: settings))
                return
            }
            self.requestAuthorization(completion: completion)
        }
    }

    func requestAuthorization(completion: ((BadgePermissionState) -> Void)? = nil) {
        guard !suppressPromptsForUITest else {
            completion?(BadgePermissionState(canUseNativeBadge: false, shouldOpenSystemSettings: false))
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            guard granted, error == nil else {
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    completion?(Self.badgePermissionState(from: settings))
                }
                return
            }
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                completion?(Self.badgePermissionState(from: settings))
            }
        }
    }

    func canUseNativeApplicationBadge(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            completion(Self.badgePermissionState(from: settings).canUseNativeBadge)
        }
    }

    func setApplicationBadgeCount(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { error in
            if let error {
                NSLog("\(AttacheAppSupport.appDisplayName) badge count update failed: \(error.localizedDescription)")
            }
        }
    }

    func openSystemNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.bryanlabs.attache"
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?bundleID=\(bundleID)",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ].compactMap(URL.init(string:))
        for url in urls where NSWorkspace.shared.open(url) {
            return
        }
    }

    private static func badgePermissionState(from settings: UNNotificationSettings) -> BadgePermissionState {
        let allowed = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        return BadgePermissionState(
            canUseNativeBadge: allowed && settings.badgeSetting == .enabled,
            shouldOpenSystemSettings: settings.authorizationStatus == .denied
                || (allowed && settings.badgeSetting != .enabled)
        )
    }

    func post(card: VoicemailCard, kind: AttacheAlertKind) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = card.sessionTitle.map { "Attaché · \($0)" } ?? "Attaché"
            let body = card.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            content.body = body.isEmpty ? "A new agent update is waiting in your voicemail." : body
            content.sound = kind == .needsYou ? .default : nil
            content.interruptionLevel = kind.interruptionLevel
            content.categoryIdentifier = Self.categoryIdentifier
            var userInfo: [String: Any] = ["cardID": card.id]
            if let sessionID = card.externalSessionID {
                userInfo["sessionID"] = sessionID
            }
            content.userInfo = userInfo

            let request = UNNotificationRequest(identifier: card.id, content: content, trigger: nil)
            center.add(request)
        }
    }
}
