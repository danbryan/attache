import AppKit

/// Central gate for the app pulling itself to the system foreground.
///
/// Normally the app activates itself on launch and whenever an overlay opens so
/// its window is in front for the user. Under the UI smoke harness's background
/// mode (`SMOKE_BACKGROUND=1`, which sets `ATTACHE_UI_TEST_BACKGROUND=1` on the
/// app's environment) the run must leave whatever the user has frontmost
/// untouched, so every self-activation is suppressed. The window still orders
/// front WITHIN the app, and the harness drives it entirely through keyboard
/// events posted to the app's pid plus accessibility reads, neither of which
/// needs the app to be the system's active app.
enum AppActivation {
    /// True only when both `ATTACHE_UI_TEST=1` and
    /// `ATTACHE_UI_TEST_BACKGROUND=1` are set, so the background flag can never
    /// suppress a real user's foreground activation on its own. See
    /// `AppActivationTests` for the non-bypass proof.
    static func shouldSuppressForeground(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["ATTACHE_UI_TEST"] == "1" && environment["ATTACHE_UI_TEST_BACKGROUND"] == "1"
    }

    /// Brings the app to the system foreground unless background smoke mode has
    /// suppressed it. Drop-in replacement for a bare
    /// `NSApp.activate(ignoringOtherApps: true)` at the app's own launch and
    /// overlay-open sites.
    static func bringToForeground() {
        guard !shouldSuppressForeground() else { return }
        NSApp.activate(ignoringOtherApps: true)
    }
}
