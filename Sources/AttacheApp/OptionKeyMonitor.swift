import AppKit
import Combine

/// App-wide live Option-key state for the dock's right-click context menus
/// (INF-354). SwiftUI's `.contextMenu` has no `NSMenuItem.isAlternate`
/// equivalent, so the macOS "hold Option to reveal the power/destructive
/// variant" convention is reproduced here instead: every dock context menu
/// reads `OptionKeyMonitor.shared.isHeld` while building its item list, and
/// because it is a real `@Published` property, SwiftUI re-evaluates the menu
/// content and swaps the alternate items in live while the menu stays open.
///
/// Started once at launch (`AppDelegate.applicationDidFinishLaunching`).
///
/// `ATTACHE_UI_TEST_FORCE_OPTION_MENU=1` (only under `ATTACHE_UI_TEST=1`,
/// matching every other UI-test-only override in this app) forces `isHeld`
/// true so `scripts/ui-smoke.sh` can assert the Option-alternate items exist
/// without synthesizing a real modifier-flag event.
@MainActor
final class OptionKeyMonitor: ObservableObject {
    static let shared = OptionKeyMonitor()

    @Published private(set) var isHeld: Bool
    private var monitor: Any?

    private init() {
        let environment = ProcessInfo.processInfo.environment
        isHeld = environment["ATTACHE_UI_TEST"] == "1"
            && environment["ATTACHE_UI_TEST_FORCE_OPTION_MENU"] == "1"
    }

    func start() {
        guard monitor == nil else { return }
        let environment = ProcessInfo.processInfo.environment
        guard environment["ATTACHE_UI_TEST"] != "1" || environment["ATTACHE_UI_TEST_FORCE_OPTION_MENU"] != "1" else {
            // The forced-on smoke fixture stays forced on; a real flagsChanged
            // monitor would immediately flip it back off.
            return
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.isHeld = event.modifierFlags.contains(.option)
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
