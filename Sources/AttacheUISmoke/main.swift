import AppKit
import ApplicationServices
import CoreGraphics

// AttacheUISmoke: accessibility-driven UI smoke harness (INF-156).
//
// Usage: attache-ui-smoke [path-to-Attache.app] [repo-root]
// Env:   SMOKE_ONLY=f1,f4  run a subset of flows while iterating.
//
// The harness launches the packaged app with ATTACHE_UI_TEST=1, drives it via
// AXUIElement actions, and exits nonzero if any step fails. Run it through
// scripts/ui-smoke.sh, which handles packaging and fresh-user state.

let arguments = CommandLine.arguments
let appPath = arguments.count > 1 ? arguments[1] : "dist/Attache.app"
let repoRoot = arguments.count > 2 ? arguments[2] : FileManager.default.currentDirectoryPath

guard AXElement.processIsTrusted else {
    print("""
    FAIL: this process is not trusted for Accessibility control.
    Grant it in System Settings > Privacy & Security > Accessibility (the
    terminal or app hosting this harness), then re-run scripts/ui-smoke.sh.
    """)
    exit(2)
}

let onlyFlows = ProcessInfo.processInfo.environment["SMOKE_ONLY"]
    .map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }) }

func enabled(_ flow: String) -> Bool {
    let key = flow.lowercased()
    if let onlyFlows { return onlyFlows.contains(key) }
    // "dock-menus" is opt-in, not because it needs a live backend like the
    // others here, but because it is currently blocked on a SwiftUI/AX
    // limitation (see the KNOWN LIMITATION comment on openContextMenu in this
    // file, INF-354): AXShowMenu fails outright for `.contextMenu`-hosted
    // dock buttons, so every step in it currently fails deterministically.
    // Kept runnable via SMOKE_ONLY=dock-menus for whoever revisits this.
    return !["f7", "f8", "f9", "f10", "f11", "f12", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20", "f21", "f22", "f23", "f24", "context", "dock-menus"].contains(key)
}

let app = AppUnderTest(appURL: URL(fileURLWithPath: appPath))
let run = SmokeRun()

func mainWindow() throws -> AXElement {
    // The single main window carries the app display name. Settings is now an
    // in-window overlay (INF-377), and the Character Studio is a sheet, so
    // prefer the named window to never accidentally return one of those.
    if let named = app.appWindows.first(where: { $0.title == "Attaché" }) {
        return named
    }
    guard let window = app.appWindows.first(where: { !$0.title.contains("Settings") }) ?? app.appWindows.first else {
        throw SmokeError(message: "app has no windows")
    }
    return window
}

/// The in-window Settings overlay surface (INF-377). Returns the overlay root
/// element (AX identifier "Settings Overlay") so existing `.descendants` /
/// `.firstDescendant` lookups keep working against the panes inside it.
func settingsWindow() throws -> AXElement {
    guard let overlay = (try mainWindow()).firstDescendant(containing: "Settings Overlay") else {
        throw SmokeError(message: "settings overlay not open in main window")
    }
    return overlay
}

/// Presses the overlay's close affordance ("Close Settings"); Escape also works.
func closeSettingsOverlay() throws {
    let close = try waitForElement("Close Settings button", in: try settingsWindow(),
                                   role: kAXButtonRole as String, containing: "Close Settings")
    _ = close.press()
}

/// The Character Studio surface (INF-377): a sheet over the Settings overlay,
/// inside the main window. Reachable either as an application window or as a
/// descendant of the presenting window, so both are checked.
func personalityStudioWindow() throws -> AXElement {
    if let window = app.appWindows.first(where: {
        $0.identifier == "Character Studio" || $0.firstDescendant(containing: "Character Studio") != nil
    }) {
        return window
    }
    if let surface = app.axApp.firstDescendant(containing: "Character Studio") {
        return surface
    }
    let titles = app.appWindows.map { "\"\($0.title)\"" }.joined(separator: ", ")
    throw SmokeError(message: "no character studio surface found; open windows: [\(titles)]")
}

func runShell(_ script: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-lc", script]
    process.currentDirectoryURL = URL(fileURLWithPath: repoRoot)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw SmokeError(message: "shell command failed (\(process.terminationStatus)): \(script)\n\(output)")
    }
    return output
}

func waitForFile(_ path: String,
                 toContain description: String,
                 timeout: TimeInterval = 120,
                 interval: TimeInterval = 1,
                 condition: (String) -> Bool) throws {
    try waitUntil(description, timeout: timeout, interval: interval) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return condition(text)
    }
}

func occurrenceCount(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchStart = haystack.startIndex
    while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
        count += 1
        searchStart = range.upperBound
    }
    return count
}

@discardableResult
func waitForInboxCardRow(containing token: String, timeout: TimeInterval = 120) throws -> AXElement {
    try waitForElement("inbox card row containing \(token)", in: try mainWindow(), timeout: timeout) { element in
        element.role != kAXTextFieldRole as String
            && element.matches("Play")
            && element.matches(token)
    }
}

@discardableResult
func waitForHistoryCardRow(filteredBy token: String, timeout: TimeInterval = 120) throws -> AXElement {
    try waitForElement("history card row filtered by \(token)", in: try mainWindow(), timeout: timeout) { element in
        element.role != kAXTextFieldRole as String
            && element.matches("Replay")
    }
}

func sendConversationPrompt(_ text: String) throws {
    let existingField = (try? mainWindow())?.descendants(where: { element in
        element.role == kAXTextFieldRole as String
            && (element.matchesExactly("Conversation message") || element.matchesExactly("Call message"))
    }, collectLimit: 1).first
    if existingField == nil {
        app.key(Key.l, command: true)
    }
    let field = try waitForElement("conversation or call message field", in: try mainWindow(), timeout: 20) { element in
        element.role == kAXTextFieldRole as String
            && (element.matchesExactly("Conversation message") || element.matchesExactly("Call message"))
    }
    _ = field.setFocused()
    if !field.setValue(text) { app.type(text) }
    try waitUntil("conversation text to land", timeout: 8, interval: 0.5) {
        if field.stringValue.contains(text) { return true }
        _ = field.setFocused()
        if !field.setValue(text) { app.type(text) }
        return field.stringValue.contains(text)
    }
    if field.matchesExactly("Call message") {
        let send = try waitForElement("enabled call send button", in: try mainWindow(), timeout: 20) { element in
            element.role == kAXButtonRole as String
                && element.matchesExactly("Send call message")
                && element.isEnabled
        }
        guard send.press() else {
            throw SmokeError(message: "AXPress failed on call send button: \(send.summary); actions: \(send.actionNames)")
        }
    } else {
        let send = try waitForElement("enabled conversation send button", in: try mainWindow(), timeout: 20) { element in
            element.role == kAXButtonRole as String
                && element.matchesExactly("Send conversation message")
                && element.isEnabled
        }
        guard send.press() else {
            throw SmokeError(message: "AXPress failed on conversation send button: \(send.summary); actions: \(send.actionNames)")
        }
    }
}

func selectConversationDestination(_ title: String) throws {
    let option = try waitForElement("conversation destination \(title)", in: try mainWindow(), timeout: 8) { element in
        element.matchesExactly(title)
            && (element.actionNames.contains(kAXPressAction) || element.role == kAXRadioButtonRole as String)
    }
    if !option.press(), !option.setSelected(true) {
        throw SmokeError(message: "could not select conversation destination \(title): \(option.summary); actions: \(option.actionNames)")
    }
}

/// Selects a settings sidebar section by title. The overlay sidebar (INF-377)
/// exposes each section as a button carrying the AX identifier
/// "Settings section <title>"; pressing it switches the pane, asserted via a
/// marker string unique to the target pane.
func selectSettingsSection(_ title: String, paneMarker: String) throws {
    let identifier = "Settings section \(title)"
    let row = try waitForElement("sidebar row \"\(title)\"", in: try settingsWindow(),
                                 role: kAXButtonRole as String, containing: identifier, timeout: 10)
    guard row.press() else {
        throw SmokeError(message: "AXPress failed on sidebar row \"\(title)\": \(row.summary)")
    }
    _ = try waitForElement("\(title) pane content", in: try settingsWindow(), containing: paneMarker)
}

/// Opens a popup button and picks the menu item with the given title. The menu
/// can attach under the popup or under the application element depending on
/// the control, so both are searched.
func selectPopup(_ popup: AXElement, item: String) throws {
    guard popup.press() else {
        throw SmokeError(message: "AXPress failed on popup \(popup.summary); actions: \(popup.actionNames)")
    }
    var chosen: AXElement?
    try waitUntil("menu item \"\(item)\" in opened popup", timeout: 5) {
        for root in [popup, app.axApp] {
            if let found = root.firstDescendant(role: kAXMenuItemRole as String, containing: item) {
                chosen = found
                return true
            }
        }
        return false
    }
    guard let chosen, chosen.press() else {
        throw SmokeError(message: "could not press menu item \"\(item)\"")
    }
}

/// Right-clicks a dock control (`AXShowMenu`, the accessibility action macOS
/// maps a secondary click to) and returns the opened menu, for asserting
/// item labels before optionally pressing one (INF-354's dock context
/// menus).
///
/// KNOWN LIMITATION (investigated, not fixed by this ticket): on this
/// macOS/SwiftUI combination, `AXUIElementPerformAction(.. , kAXShowMenuAction
/// ..)` returns an outright failure for a `Button` wrapped in SwiftUI's
/// `.contextMenu { }` (confirmed on the dock's Settings/Voicemail/Call/
/// Personality controls, and reproducible on the *pre-existing* personality
/// context menu that shipped before this ticket, so it is not a regression).
/// A synthesized secondary-click `CGEvent` was tried as a workaround and
/// rejected: in this headed environment its screen-point delivery landed on
/// the real system  menu instead of the app window (a Spaces/coordinate
/// mismatch), which is unsafe to keep experimenting with since a
/// mis-targeted click could press a real destructive system item. Real
/// end users are unaffected (a physical right-click is a normal AppKit
/// gesture, not an AX action); only *this automated driving path* is
/// blocked. The "dock-menus" flow stays in the code, opt-in only (see the
/// `enabled()` blacklist), so it is available the next time someone
/// revisits reliable right-click automation for SwiftUI `.contextMenu`.
func openContextMenu(_ trigger: AXElement) throws -> AXElement {
    guard trigger.perform("AXShowMenu") else {
        throw SmokeError(message: "AXShowMenu failed on \(trigger.summary); actions: \(trigger.actionNames). See the KNOWN LIMITATION comment on openContextMenu.")
    }
    var menu: AXElement?
    try waitUntil("context menu for \(trigger.summary)", timeout: 5) {
        menu = app.axApp.descendants(where: { $0.role == kAXMenuRole as String }, collectLimit: 4).first
        return menu != nil
    }
    guard let menu else {
        throw SmokeError(message: "context menu did not open for \(trigger.summary)")
    }
    return menu
}

/// Every visible item title in an already-open context menu (see
/// `openContextMenu`), in AX discovery order.
func contextMenuItemTitles(_ menu: AXElement) -> [String] {
    menu.descendants(where: { $0.role == kAXMenuItemRole as String }).map(\.title)
}

/// Presses a titled item inside an already-open context menu.
func pressContextMenuItem(_ menu: AXElement, item: String) throws {
    guard let chosen = menu.firstDescendant(role: kAXMenuItemRole as String, containing: item) else {
        throw SmokeError(message: "context menu item \"\(item)\" not found among \(contextMenuItemTitles(menu)). AX tree:\n\(menu.treeDump())")
    }
    guard chosen.press() else {
        throw SmokeError(message: "could not press context menu item \"\(item)\"")
    }
}

func dismissOnboardingIfPresent() throws {
    if (try mainWindow()).firstDescendant(containing: "Welcome to Attaché") != nil {
        let skip = try waitForElement("skip button", in: try mainWindow(),
                                      role: kAXButtonRole as String, containing: "Skip for now")
        guard skip.press() else {
            throw SmokeError(message: "AXPress failed on \(skip.summary)")
        }
        try waitForElementGone("onboarding sheet", in: try mainWindow(),
                               containing: "Welcome to Attaché")
    }
}

func focusSessionInCommandK(query: String, sessionID: String, timeout: TimeInterval = 80) throws {
    app.activate()
    app.key(Key.k, command: true)
    let field = try waitForElement("switcher search field", in: try mainWindow(),
                                   role: kAXTextFieldRole as String, containing: "Search name")
    _ = field.setFocused()
    if !field.setValue(query) { app.type(query) }
    let row = try waitForElement("session search row", in: try mainWindow(), timeout: timeout) { element in
        element.role != kAXTextFieldRole as String
            && element.matches(sessionID)
            && element.actionNames.contains(kAXPressAction as String)
    }
    guard row.press() else {
        throw SmokeError(message: "AXPress failed on session search row: \(row.summary); actions: \(row.actionNames)")
    }
    try waitForElementGone("switcher search field", in: try mainWindow(),
                           role: kAXTextFieldRole as String, containing: "Search name", timeout: 8)
}

func openAgentCallComposer() throws -> AXElement {
    app.key(Key.l, command: true)
    _ = try waitForElement("live call composer", in: try mainWindow(),
                           containing: "Live call composer", timeout: 20)
    try selectConversationDestination("Tell Agent")
    return try waitForElement("agent call message field", in: try mainWindow(),
                              role: kAXTextFieldRole as String, exactly: "Call message", timeout: 10)
}

func enterAgentCallInstruction(_ instruction: String, mustContain token: String? = nil) throws {
    let editor = try waitForElement("agent call message field", in: try mainWindow(),
                                    role: kAXTextFieldRole as String, exactly: "Call message", timeout: 10)
    _ = editor.setFocused()
    if !editor.setValue(instruction) { app.type(instruction) }
    let expected = token ?? instruction
    try waitUntil("instruction text to land in the live composer", timeout: 8, interval: 0.5) {
        if editor.stringValue.contains(expected) { return true }
        _ = editor.setFocused()
        if !editor.setValue(instruction) { app.type(instruction) }
        return editor.stringValue.contains(expected)
    }
}

func pressAgentInstructionSend(timeout: TimeInterval = 10) throws {
    let send = try waitForElement("enabled agent call send button", in: try mainWindow(), timeout: timeout) { element in
        element.role == kAXButtonRole as String
            && element.matchesExactly("Send call message")
            && element.isEnabled
    }
    guard send.press() else {
        throw SmokeError(message: "AXPress failed on agent call send button: \(send.summary); actions: \(send.actionNames)")
    }
}

/// Types `text` into the on-call "Call message" field and presses Send.
/// Shared by the `call-*` pose states below (INF-244's screenshot matrix);
/// mirrors the proven inline pattern flows f15/f16 already use, but factored
/// out since every `call-*` pose case needs the identical steps. Assumes a
/// call is already open (Command-L) and, when relevant, the right
/// destination is already selected.
func sendCallMessagePose(_ text: String) throws {
    let field = try waitForElement("call message field", in: try mainWindow(),
                                   role: kAXTextFieldRole as String, exactly: "Call message",
                                   timeout: 20)
    _ = field.setFocused()
    if !field.setValue(text) { app.type(text) }
    try waitUntil("call text to land", timeout: 8, interval: 0.5) {
        if field.stringValue.contains(text) { return true }
        _ = field.setFocused()
        if !field.setValue(text) { app.type(text) }
        return field.stringValue.contains(text)
    }
    let send = try waitForElement("call send button", in: try mainWindow(),
                                  role: kAXButtonRole as String, exactly: "Send call message",
                                  timeout: 8)
    guard send.press() else {
        throw SmokeError(message: "AXPress failed on call send button: \(send.summary); actions: \(send.actionNames)")
    }
}

/// Waits for the on-call composer's phase-driven status row
/// (`CallHUD.swift`'s `callStatusRow`, AX label "Conversation status: <text>")
/// to contain every token in `tokens`. This is the row `CallStatusPresentation`
/// drives from `CallPhase` alone (INF-244), so matching it is the direct
/// proof a given phase is on screen, not just an incidental caption elsewhere.
@discardableResult
func waitForConversationStatus(containingAll tokens: [String], timeout: TimeInterval) throws -> AXElement {
    try waitForElement("conversation status containing \(tokens)", in: try mainWindow(), timeout: timeout) { element in
        element.matches("Conversation status:") && tokens.allSatisfy { element.matches($0) }
    }
}

/// The app's frontmost normal-layer (kCGWindowLayer == 0) window id, picking
/// the largest by area if there is more than one (the main content window
/// over any small utility panel).
func frontmostWindowID(forPID pid: pid_t) -> CGWindowID? {
    guard let infoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: AnyObject]] else {
        return nil
    }
    func area(of info: [String: AnyObject]) -> CGFloat {
        guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return 0 }
        return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    }
    let candidates = infoList.filter { info in
        (info[kCGWindowOwnerPID as String] as? pid_t) == pid
            && (info[kCGWindowLayer as String] as? Int) == 0
    }
    return candidates.max(by: { area(of: $0) < area(of: $1) })?[kCGWindowNumber as String] as? CGWindowID
}

/// Resolves a window by title substring rather than by largest area, for poses
/// that need to capture a specific secondary window (like Settings) instead of
/// the app's main window, which `frontmostWindowID` would otherwise pick
/// whenever it happens to be the larger of the two.
func windowID(forPID pid: pid_t, titleContains needle: String) -> CGWindowID? {
    guard let infoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: AnyObject]] else {
        return nil
    }
    return infoList.first { info in
        (info[kCGWindowOwnerPID as String] as? pid_t) == pid
            && (info[kCGWindowLayer as String] as? Int) == 0
            && ((info[kCGWindowName as String] as? String)?.localizedCaseInsensitiveContains(needle) ?? false)
    }?[kCGWindowNumber as String] as? CGWindowID
}

/// Screenshots the app's own window by CGWindowID via `screencapture -l`,
/// never the whole screen. This is INF-244's fix for the screenshot matrix:
/// a full-screen `screencapture -x` captures whatever macOS Space is
/// currently visible to a human at the physical display, which on a machine
/// in active concurrent use is frequently NOT the Space the harness's
/// packaged app launched into (AXUIElement actions work across Spaces; the
/// screen the human sees does not follow them). Window-id capture pulls
/// directly from the window server's buffer for that specific window,
/// independent of which Space is frontmost, so the screenshot is guaranteed
/// to show Attaché rather than whatever else happened to be on screen.
func captureAppWindowScreenshot(to path: String, titleContains: String? = nil) {
    let resolvedWindowID = titleContains.flatMap { windowID(forPID: app.pid, titleContains: $0) }
        ?? frontmostWindowID(forPID: app.pid)
    guard let windowID = resolvedWindowID else {
        print("screenshot: could not resolve a window id for pid \(app.pid); skipping capture to \(path)")
        return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    // -x: no sound. -o: no window shadow (keeps the crop to just the window's
    // own content). -l<id>: capture exactly this window, any Space.
    process.arguments = ["-x", "-o", "-l\(windowID)", path]
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            print("screenshot: screencapture exited \(process.terminationStatus) for window \(windowID)")
        }
    } catch {
        print("screenshot: failed to launch screencapture: \(error)")
    }
}

/// Same as `captureAppWindowScreenshot`, but targets a specific window by
/// title substring (see `windowID(forPID:titleContains:)`) rather than the
/// largest window owned by the app.
func captureNamedWindowScreenshot(to path: String, titleContains needle: String) {
    guard let windowID = windowID(forPID: app.pid, titleContains: needle) else {
        print("screenshot: could not resolve a window id containing \"\(needle)\" for pid \(app.pid); skipping capture to \(path)")
        return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l\(windowID)", path]
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            print("screenshot: screencapture exited \(process.terminationStatus) for window \(windowID)")
        }
    } catch {
        print("screenshot: failed to launch screencapture: \(error)")
    }
}

// Pose mode: launch the app, arrange a named state, and hold it on screen so a
// human or screenshot tool can capture it. SMOKE_POSE=inbox|settings|live
// (comma-separated applies in order), SMOKE_TEXTSCALE=1.3 to set text size,
// SMOKE_POSE_SECONDS to change the hold time.
//
// The call-* states below pose each CallPhase the on-call composer can show
// (INF-244's screenshot-matrix success criterion), driven only through
// deterministic local fixtures (a mock OpenAI-compatible personality
// provider, a fake `codex` CLI shadow, or a test-only mic override) so this
// never depends on real network access or paid provider credentials. See
// scripts/call-phase-screenshot-matrix.sh for how each state's fixture is
// wired up before launch.
if let pose = ProcessInfo.processInfo.environment["SMOKE_POSE"] {
    let holdSeconds = Double(ProcessInfo.processInfo.environment["SMOKE_POSE_SECONDS"] ?? "30") ?? 30
    do {
        try app.launch()
        if let skip = (try mainWindow()).firstDescendant(role: kAXButtonRole as String,
                                                         containing: "Skip for now") {
            _ = skip.press()
        }
        if let scaleText = ProcessInfo.processInfo.environment["SMOKE_TEXTSCALE"],
           let scale = Double(scaleText) {
            app.activate()
            app.key(Key.comma, command: true)
            try waitUntil("settings window", timeout: 10) { (try? settingsWindow()) != nil }
            let slider = try waitForElement("Text size slider", in: try settingsWindow(),
                                            role: kAXSliderRole as String, containing: "Text size")
            _ = slider.setValue(scale)
            if !pose.contains("settings") {
                try closeSettingsOverlay()
            }
        }
        for state in pose.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch state {
            case "inbox":
                let button = try waitForElement("voicemail dock button", in: try mainWindow(),
                                                role: kAXButtonRole as String, containing: "Open inbox")
                _ = button.press()

            // The four overlay poses (INF-358 check 2): each opens its
            // overlay by keyboard shortcut and waits for its own AX marker,
            // so a screenshot taken right after confirms the character is
            // visible (dimmed) behind a real, on-screen overlay rather than
            // guessing a fixed delay.
            case "palette":
                app.activate()
                app.key(Key.k, command: true)
                _ = try waitForElement("switcher search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search name")

            case "history":
                app.activate()
                app.key(Key.y, command: true)
                _ = try waitForElement("history search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search history")

            case "charswitcher":
                app.activate()
                app.key(Key.p, command: true, shift: true)
                _ = try waitForElement("character switcher", in: try mainWindow(), containing: "Attaché switcher")

            case "settings":
                app.activate()
                app.key(Key.comma, command: true)
                try waitUntil("settings window", timeout: 10) { (try? settingsWindow()) != nil }
            case "about":
                // Poses the About pane so the Responsiveness section
                // (INF-349) can be captured for evidence.
                app.activate()
                app.key(Key.comma, command: true)
                try waitUntil("settings window", timeout: 10) { (try? settingsWindow()) != nil }
                try selectSettingsSection("About", paneMarker: "Responsiveness")

            case "voice-pane":
                // INF-364 multilingual audit (b): the Voice & Captions pane
                // holds the Spoken language picker, independent of app UI
                // language (a macOS AppleLanguages / localization concern).
                app.activate()
                app.key(Key.comma, command: true)
                try waitUntil("settings window", timeout: 10) { (try? settingsWindow()) != nil }
                try selectSettingsSection("Voice & Captions", paneMarker: "Spoken language")
                // The Spoken language row sits below the fold; scroll the
                // pane's own scroll view down so the screenshot shows it
                // without depending on inconsistent scroll-into-view support.
                if let scrollBar = try? waitForElement(
                    "Voice & Captions pane scroll bar",
                    in: try settingsWindow(),
                    timeout: 5,
                    matching: { element in element.role == kAXScrollBarRole as String }
                ) {
                    _ = scrollBar.setValue(1.0)
                    Thread.sleep(forTimeInterval: 0.4)
                }
                _ = try waitForElement("Spoken language row", in: try settingsWindow(),
                                       containing: "Spoken language", timeout: 10)
            case "live":
                break
            case "play":
                // Post a demo event and start playback so captions and the
                // transport are on screen for the hold.
                _ = try runShell("scripts/send-event.sh")
                let button = try waitForElement("voicemail dock button", in: try mainWindow(),
                                                role: kAXButtonRole as String, containing: "Open inbox")
                _ = button.press()
                let row = try waitForElement("card row play action", in: try mainWindow(),
                                             containing: "Play Shell smoke update")
                _ = row.press()
                _ = try waitForElement("speaking indicator", in: try mainWindow(),
                                       containing: "Assistant speaking", timeout: 15)
                // Freeze the frame: paused playback keeps captions and the
                // transport on screen for the whole hold.
                let pause = try waitForElement("Pause control", in: try mainWindow(),
                                               role: kAXButtonRole as String, containing: "Pause")
                _ = pause.press()

            case "playing":
                // Like "play" but leaves the narration running through the
                // hold, so a recording captures live playback (the character
                // renderer's lip-sync evidence, INF-270).
                _ = try runShell("scripts/send-event.sh")
                let button = try waitForElement("voicemail dock button", in: try mainWindow(),
                                                role: kAXButtonRole as String, containing: "Open inbox")
                _ = button.press()
                let row = try waitForElement("card row play action", in: try mainWindow(),
                                             containing: "Play Shell smoke update")
                _ = row.press()
                _ = try waitForElement("speaking indicator", in: try mainWindow(),
                                       containing: "Assistant speaking", timeout: 15)

            case "playing-hold6":
                // INF-358 check 1: same as "playing", but the screenshot is
                // deliberately delayed 6s into the (~7s) demo narration
                // instead of firing the instant speech starts. Paired with
                // ATTACHE_CHARACTER_RARE_IDLE_SECONDS=5 this proves rare idle
                // stayed suppressed well past its forced interval while
                // still actively speaking.
                _ = try runShell("scripts/send-event.sh")
                let holdButton = try waitForElement("voicemail dock button", in: try mainWindow(),
                                                    role: kAXButtonRole as String, containing: "Open inbox")
                _ = holdButton.press()
                let holdRow = try waitForElement("card row play action", in: try mainWindow(),
                                                 containing: "Play Shell smoke update")
                _ = holdRow.press()
                _ = try waitForElement("speaking indicator", in: try mainWindow(),
                                       containing: "Assistant speaking", timeout: 15)
                Thread.sleep(forTimeInterval: 6)

            case "playing-settled":
                // INF-358 check 1: plays the demo narration to completion
                // (speaking indicator disappears), then waits 8s at idle.
                // Paired with ATTACHE_CHARACTER_RARE_IDLE_SECONDS=5 this
                // proves rare idle resumes once playback is over.
                _ = try runShell("scripts/send-event.sh")
                let settledButton = try waitForElement("voicemail dock button", in: try mainWindow(),
                                                       role: kAXButtonRole as String, containing: "Open inbox")
                _ = settledButton.press()
                let settledRow = try waitForElement("card row play action", in: try mainWindow(),
                                                    containing: "Play Shell smoke update")
                _ = settledRow.press()
                _ = try waitForElement("speaking indicator", in: try mainWindow(),
                                       containing: "Assistant speaking", timeout: 15)
                try waitForElementGone("speaking indicator", in: try mainWindow(),
                                       containing: "Assistant speaking", timeout: 20)
                Thread.sleep(forTimeInterval: 8)
            case "korean-voice-torture":
                // INF-364 multilingual audit (c): pick an on-device Korean
                // system voice for the active personality, then play a
                // Korean-text card, so captions render Korean while every
                // fixed app control around them (Pause, Hang up, the sidebar)
                // stays in English UI chrome. ATTACHE_FORCE_PLAIN_READBACK=1
                // (set by the wrapper) speaks the event text verbatim, so this
                // is deterministic and does not depend on a live presentation
                // LLM translating into Korean.
                app.activate()
                app.key(Key.comma, command: true)
                try waitUntil("settings window", timeout: 10) { (try? settingsWindow()) != nil }
                try selectSettingsSection("Voice & Captions", paneMarker: "Voice engine")
                // The "Voice" row's popup can show the same "System default"
                // text as the unrelated "Input source" popup further down the
                // same pane, so disambiguate by picking the topmost match
                // (Voice appears near the top of the pane, Input source near
                // the bottom, see the pane layout in VoicePane.swift).
                var candidatePopups: [AXElement] = []
                try waitUntil("system voice popup", timeout: 10) {
                    candidatePopups = (try? settingsWindow())?.descendants(where: { element in
                        element.role == kAXPopUpButtonRole as String
                            && (element.matchText.contains("en-US") || element.matchText.contains("ko-KR")
                                || element.matchText == "System default")
                    }, collectLimit: 20) ?? []
                    return !candidatePopups.isEmpty
                }
                guard let voicePopup = candidatePopups.min(by: { ($0.frame?.minY ?? .infinity) < ($1.frame?.minY ?? .infinity) }) else {
                    throw SmokeError(message: "no system voice popup found")
                }
                try selectPopup(voicePopup, item: "ko-KR")
                try closeSettingsOverlay()

                let koreanText = "안녕하세요 저는 앱 개발자입니다 오늘은 날씨가 정말 좋습니다"
                _ = try runShell("EVENT_TITLE='Korean voice torture card' EVENT_TEXT='\(koreanText)' scripts/send-event.sh")
                let button = try waitForElement("voicemail dock button", in: try mainWindow(),
                                                role: kAXButtonRole as String, containing: "Open inbox")
                _ = button.press()
                let row = try waitForElement("card row play action", in: try mainWindow(),
                                             containing: "Play Korean voice torture card")
                _ = row.press()
                _ = try waitForElement("speaking indicator", in: try mainWindow(),
                                       containing: "Assistant speaking", timeout: 15)

            case "checksum-torture":
                // INF-364 evidence: a checksum-heavy card, paused on screen so
                // a screenshot shows the caption box wrapping the oversized
                // token instead of overflowing.
                let tortureText = """
                Build verification finished. The release checksum is e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b85 and it matched the published artifact exactly.
                """
                _ = try runShell("EVENT_TITLE='Checksum torture card' EVENT_TEXT='\(tortureText)' scripts/send-event.sh")
                let button = try waitForElement("voicemail dock button", in: try mainWindow(),
                                                role: kAXButtonRole as String, containing: "Open inbox")
                _ = button.press()
                let row = try waitForElement("card row play action", in: try mainWindow(),
                                             containing: "Play Checksum torture card")
                _ = row.press()
                _ = try waitForElement("speaking indicator", in: try mainWindow(),
                                       containing: "Assistant speaking", timeout: 15)
                // Freeze the frame so the screenshot reliably shows the caption
                // box, not a moment mid-transition.
                let pause = try waitForElement("Pause control", in: try mainWindow(),
                                               role: kAXButtonRole as String, containing: "Pause")
                _ = pause.press()

            case "checksum-torture-playing":
                // Like "checksum-torture" but leaves narration running through
                // the hold, for a short recording of the progressive sub-word
                // highlight advancing across the checksum.
                let tortureText = """
                Build verification finished. The release checksum is e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b85 and it matched the published artifact exactly.
                """
                _ = try runShell("EVENT_TITLE='Checksum torture card' EVENT_TEXT='\(tortureText)' scripts/send-event.sh")
                let button = try waitForElement("voicemail dock button", in: try mainWindow(),
                                                role: kAXButtonRole as String, containing: "Open inbox")
                _ = button.press()
                let row = try waitForElement("card row play action", in: try mainWindow(),
                                             containing: "Play Checksum torture card")
                _ = row.press()
                _ = try waitForElement("speaking indicator", in: try mainWindow(),
                                       containing: "Assistant speaking", timeout: 15)

            case "press-celebrate":
                // Moment-plumbing probe (INF-271): fires a celebrate through
                // the simulator panel's button so a recording can verify the
                // one-shot path end to end without waiting on a real turn.
                Thread.sleep(forTimeInterval: 2)
                let celebrate = try waitForElement("celebrate moment button", in: try mainWindow(),
                                                   role: kAXButtonRole as String, containing: "Celebrate")
                _ = celebrate.press()

            case "press-fleet-demo":
                // Fleet reel support (INF-275): kicks off the simulator's
                // scripted 40 second fleet story so a recording captures
                // badge join/leave, ripples, and the blocked hop.
                Thread.sleep(forTimeInterval: 2)
                let demo = try waitForElement("fleet demo button", in: try mainWindow(),
                                              role: kAXButtonRole as String, containing: "Fleet demo")
                _ = demo.press()

            case "sim-phase":
                // Crown totem QA (INF-285): pins the simulator to the phase
                // named by SMOKE_POSE_PHASE so a capture can study one totem
                // without racing the cycler.
                let phaseName = ProcessInfo.processInfo.environment["SMOKE_POSE_PHASE"] ?? "agentThinking"
                let phaseTitles = [
                    "sleeping": "Sleeping",
                    "idle": "Idle",
                    "agentThinking": "Agent thinking",
                    "agentResponding": "Agent responding",
                    "toolRunning": "Tool running",
                    "speaking": "Speaking",
                    "paused": "Playback paused",
                    "blockedOnUser": "Needs your input",
                    "error": "Error"
                ]
                Thread.sleep(forTimeInterval: 2)
                let picker = try waitForElement("simulated phase picker", in: try mainWindow(),
                                                role: kAXPopUpButtonRole as String, containing: "Simulated phase")
                try selectPopup(picker, item: phaseTitles[phaseName] ?? phaseName)
                _ = try waitForElement("simulated activity readout", in: try mainWindow(),
                                       containing: phaseName, timeout: 8)

            case "sim-fleet":
                // Simulator layout QA: bring the longest fleet controls into
                // view before the window-scoped capture so ellipses or clipped
                // buttons cannot hide below the scroll position.
                Thread.sleep(forTimeInterval: 2)
                let scrollBar = try waitForElement(
                    "activity simulator scroll bar",
                    in: try mainWindow()
                ) { element in
                    element.role == kAXScrollBarRole as String
                }
                guard scrollBar.setValue(1.0) else {
                    throw SmokeError(message: "could not scroll to the simulator fleet controls")
                }
                Thread.sleep(forTimeInterval: 0.4)
                let button = try waitForElement(
                    "add subagents simulator button",
                    in: try mainWindow(),
                    role: kAXButtonRole as String,
                    containing: "Add sub-agents to the focused session"
                )
                _ = button.perform("AXScrollToVisible")

            case "type-along":
                // Delight reel support (INF-273): type like a user so the
                // character's types-along taps are on screen while a recording
                // runs, then leave the hold open for the rare-idle window.
                Thread.sleep(forTimeInterval: 6)
                app.type("pair programming with attache ")
                Thread.sleep(forTimeInterval: 3)
                app.type("the character types along while the agents rest ")

            case "play-selected-when-ready":
                // Choreography demo support (INF-271): the first card of a
                // fresh profile selects itself on arrival, so pressing Space
                // starts its narration with no overlay covering the character.
                // Space is a no-op until a card exists, making this safe to
                // poll while a real agent turn is still composing.
                try waitUntil("selected card starts speaking", timeout: 240, interval: 4) {
                    app.key(Key.space)
                    Thread.sleep(forTimeInterval: 0.6)
                    return (try? mainWindow())?
                        .firstDescendant(containing: "Assistant speaking") != nil
                }

            // The seven call-* states below pose CallPhase.thinking,
            // .preparingAudio, .speaking, .sendQueued, .sendDelivered,
            // .failed, and .listening (INF-244's screenshot matrix). Each
            // drives the on-call composer to the matching real phase, then
            // waits for CallStatusPresentation's own status text via AX
            // before falling through to the shared hold-sleep below, so the
            // screenshot proves the real phase rendered, not a mockup.
            case "call-thinking":
                let prompt = ProcessInfo.processInfo.environment["ATTACHE_POSE_PROMPT"] ?? "Attache pose thinking check"
                try dismissOnboardingIfPresent()
                app.key(Key.l, command: true)
                try selectConversationDestination("Ask Attaché")
                try sendCallMessagePose(prompt)
                try waitForConversationStatus(containingAll: ["Thinking"], timeout: 20)

            case "call-preparingaudio":
                let prompt = ProcessInfo.processInfo.environment["ATTACHE_POSE_PROMPT"] ?? "Attache pose preparing audio check"
                try dismissOnboardingIfPresent()
                app.key(Key.l, command: true)
                try selectConversationDestination("Ask Attaché")
                try sendCallMessagePose(prompt)
                try waitForConversationStatus(containingAll: ["Preparing audio"], timeout: 30)

            case "call-speaking":
                let prompt = ProcessInfo.processInfo.environment["ATTACHE_POSE_PROMPT"] ?? "Attache pose speaking check"
                try dismissOnboardingIfPresent()
                app.key(Key.l, command: true)
                try selectConversationDestination("Ask Attaché")
                try sendCallMessagePose(prompt)
                try waitForConversationStatus(containingAll: ["Speaking"], timeout: 30)
                // Best-effort freeze: a conversation reply plays through the
                // same live preview transport the off-call "play" case above
                // pauses (livePreviewTransportBar in AttacheRootView.swift),
                // reachable on-call because this is a preview, not a saved
                // card. If it is not found quickly, fall through and hold
                // whatever is on screen instead of failing the whole pose.
                if let pause = try? waitForElement("live preview pause control", in: try mainWindow(),
                                                   role: kAXButtonRole as String, containing: "Pause",
                                                   timeout: 4) {
                    _ = pause.press()
                }

            case "call-failed":
                let prompt = ProcessInfo.processInfo.environment["ATTACHE_POSE_PROMPT"] ?? "Attache pose failure check"
                try dismissOnboardingIfPresent()
                app.key(Key.l, command: true)
                try selectConversationDestination("Ask Attaché")
                try sendCallMessagePose(prompt)
                try waitForConversationStatus(containingAll: ["usage limit"], timeout: 20)

            case "call-sendqueued", "call-senddelivered":
                let env = ProcessInfo.processInfo.environment
                guard let nonce = env["ATTACHE_POSE_AGENT_NONCE"], !nonce.isEmpty,
                      let sessionID = env["ATTACHE_POSE_AGENT_SESSION_ID"], !sessionID.isEmpty,
                      let token = env["ATTACHE_POSE_AGENT_TOKEN"], !token.isEmpty else {
                    throw SmokeError(message: "\(state) pose requires ATTACHE_POSE_AGENT_NONCE/_SESSION_ID/_TOKEN")
                }
                let prompt = "reply exactly \(token) and do not use tools"
                try dismissOnboardingIfPresent()
                try focusSessionInCommandK(query: nonce, sessionID: sessionID)
                app.key(Key.l, command: true)
                try selectConversationDestination("Tell Agent")
                _ = try waitForElement("frozen Tell Agent target", in: try mainWindow(), timeout: 8) { element in
                    element.matches("Tell Codex") && element.matches(nonce)
                }
                try sendCallMessagePose(prompt)
                let enable = try waitForElement("Enable send-to-agent button", in: try mainWindow(),
                                                role: kAXButtonRole as String, exactly: "Enable send-to-agent",
                                                timeout: 15)
                guard enable.press() else {
                    throw SmokeError(message: "AXPress failed on Enable send-to-agent: \(enable.summary); actions: \(enable.actionNames)")
                }
                _ = try waitForElement("per-instruction confirmation sheet", in: try mainWindow(),
                                       containing: token, timeout: 12)
                let confirm = try waitForElement("Send to agent confirmation button", in: try mainWindow(),
                                                 role: kAXButtonRole as String, exactly: "Send to agent",
                                                 timeout: 12)
                guard confirm.press() else {
                    throw SmokeError(message: "AXPress failed on Send to agent confirmation: \(confirm.summary); actions: \(confirm.actionNames)")
                }
                try waitForElementGone("confirmation sheet", in: try mainWindow(), containing: "Send this to", timeout: 8)
                if state == "call-sendqueued" {
                    // The wrapper script keeps the target session's transcript
                    // growing every second (never idle), so the confirmed
                    // instruction can never dispatch and stays queued for the
                    // whole hold, matching the two-way expiry gate's own
                    // non-idle mechanism (scripts/two-way-negative-path-smoke.sh).
                    try waitForConversationStatus(containingAll: ["when the session is quiet"], timeout: 30)
                } else {
                    // No keepalive here: the fake codex CLI resolves quickly,
                    // so this state is caught right as it appears rather than
                    // waited out, keeping the screenshot inside
                    // CallStatusPresentation.deliveredEmphasisWindow.
                    try waitForConversationStatus(containingAll: ["watching for the reply"], timeout: 60)
                }

            case "call-listening":
                // Real mic/speech activation is unnecessary risk here (a real
                // permission prompt could stall unattended automation); the
                // wrapper instead sets ATTACHE_UI_TEST_FORCE_LISTENING=1,
                // honored only alongside ATTACHE_UI_TEST=1 (see
                // MicTranscriptController.shouldForceListeningForPose), which
                // flips the same published flag CallPhase.derive reads.
                try dismissOnboardingIfPresent()
                app.key(Key.l, command: true)
                try waitForConversationStatus(containingAll: ["Release the mic"], timeout: 20)

            case "saved-call":
                // A saved (non-private) call, for the crown-band-absent and
                // PRIVATE-chip-absent comparison screenshots (INF-356).
                try dismissOnboardingIfPresent()
                app.key(Key.l, command: true)
                _ = try waitForElement("saved call composer", in: try mainWindow(),
                                       containing: "Live call composer", timeout: 10)

            case "private", "private-echo":
                // Incognito identity screenshots (INF-356): the default
                // character crown band + PRIVATE chip, and the same on
                // Echo's voice-bars presence. ATTACHE_POSE_THEME optionally
                // switches the theme first, for the window-tint matrix.
                try dismissOnboardingIfPresent()
                _ = try waitForElement("voicemail dock button", in: try mainWindow(),
                                       role: kAXButtonRole as String, containing: "Open inbox", timeout: 15)
                if let themeName = ProcessInfo.processInfo.environment["ATTACHE_POSE_THEME"] {
                    app.activate()
                    app.key(Key.comma, command: true)
                    try waitUntil("settings window", timeout: 10) { (try? settingsWindow()) != nil }
                    let popup = try waitForElement("Theme picker", in: try settingsWindow(),
                                                   role: kAXPopUpButtonRole as String, containing: "Theme")
                    try selectPopup(popup, item: themeName)
                    try waitUntil("theme picker to read \(themeName)", timeout: 5) {
                        popup.stringValue.contains(themeName)
                    }
                    try closeSettingsOverlay()
                    try waitUntil("settings window to close", timeout: 5) { (try? settingsWindow()) == nil }
                }
                if state == "private-echo" {
                    app.activate()
                    app.key(Key.p, command: true, shift: true)
                    let search = try waitForElement("character search", in: try mainWindow(),
                                                    role: kAXTextFieldRole as String, containing: "Search personalities")
                    _ = search.setFocused()
                    if !search.setValue("Echo") { app.type("Echo") }
                    _ = try waitForElement("filtered Echo character", in: try mainWindow(), containing: "Echo")
                    app.key(Key.returnKey)
                    try waitForElementGone("character switcher after Echo selection", in: try mainWindow(),
                                           containing: "Attaché switcher", timeout: 5)
                }
                // The pre-call chevron (not yet on a call) offers "Start
                // Private Call" directly; pressing Cmd+L first would start a
                // SAVED call and swap this button for the on-call overflow
                // menu, whose item reads "Make This Call Private" instead.
                app.activate()
                let more = try waitForElement("more call options", in: try mainWindow(),
                                              containing: "More call options")
                try selectPopup(more, item: "Start Private Call")
                _ = try waitForElement("private call composer", in: try mainWindow(),
                                       containing: "Private call composer", timeout: 10)
                _ = try waitForElement("PRIVATE indicator chip", in: try mainWindow(),
                                       exactly: "PRIVATE", timeout: 10)

            default:
                print("unknown pose state: \(state)")
            }
        }
        // Screenshot the app's own window (by CGWindowID, never the whole
        // screen) the instant the requested state is confirmed on screen,
        // before the hold-sleep even starts, if the wrapper asked for one.
        // Settings is now an in-window overlay (INF-377), so every pose lands
        // on the single main window and the main-window capture is correct.
        if let screenshotPath = ProcessInfo.processInfo.environment["ATTACHE_POSE_SCREENSHOT_PATH"] {
            captureAppWindowScreenshot(to: screenshotPath)
        }
        print("posing \(pose) for \(Int(holdSeconds))s")
        // Wrapper scripts tail the log for this marker to time recordings;
        // without a flush it sits in the block buffer until exit when stdout
        // is a file, which is exactly too late.
        fflush(stdout)
        // INF-364 evidence: instead of one screenshot then a single sleep, a
        // burst directory captures a short frame sequence (by CGWindowID,
        // same as the single-shot path above) across the hold, so a wrapper
        // script can stitch them into a short recording of the sub-word
        // progressive highlight advancing across a long token.
        if let burstDir = ProcessInfo.processInfo.environment["ATTACHE_POSE_BURST_DIR"] {
            let intervalMs = Int(ProcessInfo.processInfo.environment["ATTACHE_POSE_BURST_INTERVAL_MS"] ?? "150") ?? 150
            let deadline = Date().addingTimeInterval(holdSeconds)
            var frame = 0
            while Date() < deadline {
                let framePath = burstDir + String(format: "/frame-%04d.png", frame)
                captureAppWindowScreenshot(to: framePath)
                frame += 1
                Thread.sleep(forTimeInterval: Double(intervalMs) / 1000.0)
            }
        } else {
            Thread.sleep(forTimeInterval: holdSeconds)
        }
    } catch {
        print("pose failed: \(error)")
    }
    app.terminateAndWait()
    exit(0)
}

print("UI smoke starting: app=\(appPath)")

// A unique title prevents a state-preserving smoke run from selecting an older
// short fixture that happens to share the generic Shell smoke title.
let primarySmokeEventTitle = "Shell smoke update \(UUID().uuidString.prefix(8))"

// The launch is a precondition for every flow, not part of flow 1: without it,
// a SMOKE_ONLY subset would run against nothing.
guard run.requiredStep("setup", "app launches and shows a window", { try app.launch() }) else {
    exit(Int32(run.summarize()))
}

// MARK: Flow 1: fresh launch reaches idle
// Onboarding (INF-153) has not landed; when it does, its skip path asserts here.

if enabled("f1") {
    run.step("f1-launch", "onboarding appears on fresh profiles and skips to idle") {
        // The welcome sheet shows only when the completed flag is absent:
        // fresh profiles must walk the skip path; primed profiles fall
        // straight through.
        if (try mainWindow()).firstDescendant(containing: "Welcome to Attaché") != nil {
            let skip = try waitForElement("skip button", in: try mainWindow(),
                                          role: kAXButtonRole as String, containing: "Skip for now")
            guard skip.press() else {
                throw SmokeError(message: "AXPress failed on \(skip.summary)")
            }
            try waitForElementGone("onboarding sheet", in: try mainWindow(),
                                   containing: "Welcome to Attaché")
        }
    }
    run.step("f1-launch", "idle dock exposes Open inbox") {
        _ = try waitForElement("voicemail dock button", in: try mainWindow(),
                               role: kAXButtonRole as String, containing: "Open inbox")
    }
    run.step("f1-launch", "idle dock exposes Open settings") {
        _ = try waitForElement("settings dock button", in: try mainWindow(),
                               role: kAXButtonRole as String, containing: "Open settings")
    }
    run.step("f1-launch", "idle dock exposes the focus status button") {
        _ = try waitForElement("focus dock button", in: try mainWindow(),
                               role: kAXButtonRole as String, containing: "Focus status")
    }
    run.step("f1-boundary", "context-free call exposes no work-session context") {
        app.activate()
        app.key(Key.l, command: true)
        _ = try waitForElement("context-free live call composer", in: try mainWindow(),
                               containing: "Live call composer", timeout: 10)
        _ = try waitForElement("explicit no-session boundary", in: try mainWindow(),
                               containing: "No work session context", timeout: 10)
        _ = try waitForElement("context-free character message field", in: try mainWindow(), timeout: 10) { element in
            element.role == kAXTextFieldRole as String
                && element.matchesExactly("Call message")
        }
    }
    run.step("f1-boundary", "saved call shows no PRIVATE indicator") {
        guard (try mainWindow()).firstDescendant(exactly: "PRIVATE") == nil else {
            throw SmokeError(message: "Saved (non-private) call unexpectedly exposed the PRIVATE indicator")
        }
    }
    run.step("f1-boundary", "hang up closes the context-free call") {
        let hangUp = try waitForElement("context-free Hang up control", in: try mainWindow(),
                                       role: kAXButtonRole as String, containing: "Hang up")
        guard hangUp.press() else {
            throw SmokeError(message: "AXPress failed on \(hangUp.summary)")
        }
        try waitForElementGone("context-free live call composer", in: try mainWindow(),
                               containing: "Live call composer", timeout: 10)
    }
    run.step("f1-private", "private call is reachable and discloses its storage boundary") {
        let more = try waitForElement(
            "more call options",
            in: try mainWindow(),
            containing: "More call options"
        )
        try selectPopup(more, item: "Start Private Call")
        _ = try waitForElement(
            "private call composer",
            in: try mainWindow(),
            containing: "Private call composer",
            timeout: 10
        )
        _ = try waitForElement(
            "private call disclosure",
            in: try mainWindow(),
            containing: "Not saved by Attaché",
            timeout: 10
        )
        _ = try waitForElement(
            "private call session boundary",
            in: try mainWindow(),
            containing: "No work session context",
            timeout: 10
        )
        guard (try mainWindow()).firstDescendant(exactly: "Tell Agent") == nil else {
            throw SmokeError(message: "Private Call exposed the disabled Tell Agent destination")
        }
        // INF-356: the persistent PRIVATE chip in the call HUD, discoverable
        // by automation via its exact accessibility label.
        _ = try waitForElement(
            "PRIVATE indicator chip",
            in: try mainWindow(),
            exactly: "PRIVATE",
            timeout: 10
        )
    }
    run.step("f1-private", "hang up erases the private call surface") {
        let hangUp = try waitForElement(
            "private call Hang up control",
            in: try mainWindow(),
            role: kAXButtonRole as String,
            containing: "Hang up"
        )
        guard hangUp.press() else {
            throw SmokeError(message: "AXPress failed on \(hangUp.summary)")
        }
        try waitForElementGone(
            "private call composer",
            in: try mainWindow(),
            containing: "Private call composer",
            timeout: 10
        )
        guard (try mainWindow()).firstDescendant(exactly: "PRIVATE") == nil else {
            throw SmokeError(message: "PRIVATE indicator survived hang-up")
        }
    }
}

// MARK: Flow 2: demo event becomes an unread card and plays on demand

if enabled("f2") {
    run.step("f2-event", "send-event.sh is accepted by the token-guarded server") {
        // Keep this fixture long enough for the headed harness to exercise
        // pause, seek, resume, visualizer motion, and live-call geometry before
        // playback naturally completes, even on a fast machine.
        let smokeText = """
        Attaché accepted a local Codex-style event from the helper script. This longer playback fixture verifies that the unread voicemail opens normally, captions advance with the spoken words, the audio bars continue moving, seeking remains responsive, and the live call composer stays in its own lane above every playback control. The fixture is intentionally detailed so the smoke harness can inspect the active interface without racing the end of a short clip.
        """
        let output = try runShell("EVENT_TITLE='\(primarySmokeEventTitle)' EVENT_TEXT='\(smokeText)' scripts/send-event.sh")
        guard output.contains("accepted") else {
            throw SmokeError(message: "server did not accept the demo event: \(output)")
        }
    }
    run.step("f2-event", "unread badge shows the new card") {
        _ = try waitForElement("unread badge", in: try mainWindow(),
                               role: kAXButtonRole as String, containing: "unread")
    }
    run.step("f2-event", "off-call event stays silent until explicit play") {
        // Give any incorrect automatic playback enough time to surface. An
        // off-call event must remain an unread voicemail with no speaking or
        // pause transport until the next step presses its Play action.
        Thread.sleep(forTimeInterval: 0.8)
        let window = try mainWindow()
        guard window.firstDescendant(containing: "Assistant speaking") == nil else {
            throw SmokeError(message: "off-call voicemail started speaking without an explicit play action")
        }
        guard window.firstDescendant(role: kAXButtonRole as String, containing: "Pause") == nil else {
            throw SmokeError(message: "off-call voicemail exposed active playback before Play was pressed")
        }
    }
    var overlayOpened = false
    run.step("f2-event", "AXPress opens the voicemail overlay") {
        let button = try waitForElement("voicemail dock button", in: try mainWindow(),
                                        role: kAXButtonRole as String, containing: "Open inbox")
        guard button.press() else {
            throw SmokeError(message: "AXPress failed on \(button.summary); actions: \(button.actionNames)")
        }
        _ = try waitForElement("demo card in inbox", in: try mainWindow(), containing: primarySmokeEventTitle)
        overlayOpened = true
    }
    run.step("f2-event", "playback starts on demand") {
        guard overlayOpened else { throw SmokeError(message: "skipped: overlay did not open") }
        // Filter first so the target row is rendered even in a busy inbox.
        let field = try waitForElement("inbox search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search inbox")
        _ = field.setFocused()
        if !field.setValue("Shell smoke") { app.type("Shell smoke") }
        let row = try waitForElement("card row play action", in: try mainWindow(),
                                     containing: "Play \(primarySmokeEventTitle)")
        guard row.press() else {
            throw SmokeError(message: "AXPress failed on \(row.summary); actions: \(row.actionNames)")
        }
        _ = try waitForElement("speaking indicator", in: try mainWindow(),
                               containing: "Assistant speaking", timeout: 15)
    }
}

// MARK: Flow 3: transport pause/resume/seek, captions visible

if enabled("f3") {
    run.step("f3-transport", "pause halts playback") {
        let pause = try waitForElement("Pause control", in: try mainWindow(),
                                       role: kAXButtonRole as String, containing: "Pause")
        guard pause.press() else { throw SmokeError(message: "AXPress failed on \(pause.summary)") }
        _ = try waitForElement("paused indicator", in: try mainWindow(), containing: "Playback paused")
    }
    run.step("f3-transport", "scrubber accepts a seek") {
        let slider = try waitForElement("seek slider", in: try mainWindow(),
                                        role: kAXSliderRole as String, containing: "Seek playback")
        let before = slider.doubleValue ?? 0
        let target = before < 0.5 ? min(1.0, before + 0.25) : max(0.0, before - 0.25)
        if !slider.setValue(target) {
            // SwiftUI sliders often reject a direct value set; step instead.
            guard slider.actionNames.contains(kAXIncrementAction as String) else {
                throw SmokeError(message: "cannot seek: \(slider.summary) rejects value set and has no increment action (actions: \(slider.actionNames))")
            }
            for _ in 0..<3 { _ = slider.perform(kAXIncrementAction) }
        }
        try waitUntil("slider value to move from \(before)", timeout: 5) {
            guard let now = slider.doubleValue else { return false }
            return abs(now - before) > 0.02
        }
    }
    run.step("f3-transport", "resume speaks again") {
        let resume = try waitForElement("Resume control", in: try mainWindow(),
                                        role: kAXButtonRole as String, containing: "Resume")
        guard resume.press() else { throw SmokeError(message: "AXPress failed on \(resume.summary)") }
        _ = try waitForElement("speaking indicator", in: try mainWindow(), containing: "Assistant speaking")
    }
    run.step("f3-transport", "live composer stays above captions and playback controls") {
        // The idle dock may auto-hide during a long clip. Command-L is the
        // supported call shortcut and must work independently of dock chrome.
        app.activate()
        app.key(Key.l, command: true)

        let window = try mainWindow()
        guard let originalWindowFrame = window.frame else {
            throw SmokeError(message: "main window did not expose AX geometry")
        }
        let constrainedSize = CGSize(
            width: min(originalWindowFrame.width, 940),
            height: min(originalWindowFrame.height, 620)
        )
        guard window.setSize(constrainedSize) else {
            throw SmokeError(message: "could not resize the main window for constrained-layout verification")
        }
        defer { _ = window.setSize(originalWindowFrame.size) }

        let composer = try waitForElement("live call composer", in: try mainWindow(),
                                          containing: "Live call composer")
        let caption = try waitForElement("visible karaoke caption", in: try mainWindow(), timeout: 10) { element in
            guard let frame = element.frame else { return false }
            return element.matchesExactly("Assistant speaking")
                && frame.width > 100
                && frame.height > 20
        }
        let slider = try waitForElement("seek slider", in: try mainWindow(),
                                        role: kAXSliderRole as String, containing: "Seek playback")
        let pause = try waitForElement("Pause control", in: try mainWindow(),
                                       role: kAXButtonRole as String, containing: "Pause")

        do {
            try waitUntil("live composer to settle above the playback lane", timeout: 3, interval: 0.1) {
                guard let composerFrame = composer.frame,
                      let captionFrame = caption.frame,
                      let sliderFrame = slider.frame,
                      let pauseFrame = pause.frame else { return false }
                let protectedFrames = [captionFrame, sliderFrame, pauseFrame]
                return protectedFrames.allSatisfy { !composerFrame.intersects($0) }
                    && composerFrame.maxY + 8 <= (protectedFrames.map(\.minY).min() ?? .greatestFiniteMagnitude)
            }
        } catch {
            let frames = [composer.frame, caption.frame, slider.frame, pause.frame]
                .map { $0.map(NSStringFromRect) ?? "missing" }
                .joined(separator: ", ")
            throw SmokeError(message: "live composer did not settle into its reserved lane: \(frames)")
        }

        // The primary control must remain directly actionable while the call
        // composer is present, not merely exposed somewhere in the AX tree.
        guard pause.press() else { throw SmokeError(message: "Pause is not actionable with the composer visible") }
        let resume = try waitForElement("Resume control", in: try mainWindow(),
                                        role: kAXButtonRole as String, containing: "Resume")
        guard resume.press() else { throw SmokeError(message: "Resume is not actionable with the composer visible") }
    }
    run.step("f3-transport", "captions are visible during playback") {
        _ = try waitForElement("visible karaoke caption", in: try mainWindow(), timeout: 5) { element in
            guard let frame = element.frame else { return false }
            return element.matchesExactly("Assistant speaking")
                && frame.width > 100
                && frame.height > 20
        }
        let transcript = try waitForElement("caption transcript", in: try mainWindow(),
                                            containing: "Assistant speaking transcript")
        guard transcript.matchText.count > 40 else {
            throw SmokeError(message: "caption transcript did not expose the spoken text: \(transcript.summary)")
        }
    }
    run.step("f3-transport", "muted smoke playback still drives the audio visualizer") {
        let visualizer = try waitForElement("audio visualizer", in: try mainWindow(),
                                            containing: "Audio visualizer", timeout: 15)
        try waitUntil("audio visualizer to report analyzed energy", timeout: 12, interval: 0.5) {
            let value = visualizer.matchText
            let numbers = value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            return numbers.contains(where: { $0 > 0 })
        }
    }
    run.step("f3-transport", "hang up returns playback to the inbox") {
        let hangUp = try waitForElement("Hang up control", in: try mainWindow(),
                                        role: kAXButtonRole as String, containing: "Hang up")
        guard hangUp.press() else { throw SmokeError(message: "AXPress failed on \(hangUp.summary)") }
    }

    // INF-364: a checksum-heavy torture card must not overflow the caption box.
    let tortureEventTitle = "Caption torture card \(UUID().uuidString.prefix(8))"
    var tortureCardOpened = false
    run.step("f3-transport", "torture card with a checksum is accepted") {
        let tortureText = """
        Build verification finished. The release checksum is e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b85 and it matched the published artifact exactly.
        """
        let output = try runShell("EVENT_TITLE='\(tortureEventTitle)' EVENT_TEXT='\(tortureText)' scripts/send-event.sh")
        guard output.contains("accepted") else {
            throw SmokeError(message: "server did not accept the torture card event: \(output)")
        }
    }
    run.step("f3-transport", "torture card opens from the inbox") {
        let button = try waitForElement("voicemail dock button", in: try mainWindow(),
                                        role: kAXButtonRole as String, containing: "Open inbox")
        guard button.press() else {
            throw SmokeError(message: "AXPress failed on \(button.summary); actions: \(button.actionNames)")
        }
        // 30s here, not the default 10: the AX window list has been observed to
        // report empty for several seconds right after the surface switch while
        // the app ingests the torture payload (2026-07-17 flake, app healthy).
        let field = try waitForElement("inbox search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search inbox",
                                       timeout: 30)
        _ = field.setFocused()
        if !field.setValue(tortureEventTitle) { app.type(tortureEventTitle) }
        let row = try waitForElement("torture card row play action", in: try mainWindow(),
                                     containing: "Play \(tortureEventTitle)", timeout: 30)
        guard row.press() else {
            throw SmokeError(message: "AXPress failed on \(row.summary); actions: \(row.actionNames)")
        }
        _ = try waitForElement("speaking indicator", in: try mainWindow(),
                               containing: "Assistant speaking", timeout: 15)
        tortureCardOpened = true
    }
    run.step("f3-transport", "checksum caption stays visible and never overflows the window") {
        guard tortureCardOpened else { throw SmokeError(message: "skipped: torture card did not open") }
        let window = try mainWindow()
        guard let windowFrame = window.frame else {
            throw SmokeError(message: "main window did not expose AX geometry")
        }
        let caption = try waitForElement("visible karaoke caption", in: try mainWindow(), timeout: 10) { element in
            guard let frame = element.frame else { return false }
            return element.matchesExactly("Assistant speaking")
                && frame.width > 100
                && frame.height > 20
        }
        guard let captionFrame = caption.frame else {
            throw SmokeError(message: "caption element lost its AX geometry")
        }
        guard windowFrame.contains(captionFrame) || windowFrame.intersects(captionFrame) else {
            throw SmokeError(message: "caption frame \(captionFrame) fell entirely outside the window \(windowFrame)")
        }
        guard captionFrame.width <= windowFrame.width, captionFrame.height <= windowFrame.height else {
            throw SmokeError(message: "checksum caption overflowed the window: caption \(captionFrame), window \(windowFrame)")
        }
        let transcript = try waitForElement("caption transcript", in: try mainWindow(),
                                            containing: "Assistant speaking transcript")
        guard transcript.matchText.contains("e3b0c44298") else {
            throw SmokeError(message: "caption transcript did not expose the checksum text: \(transcript.summary)")
        }
    }
    run.step("f3-transport", "torture card pauses cleanly, leaving no stuck overlay") {
        // This card was opened as an ordinary voicemail play (not a live call
        // via Command-L), so there is no "Hang up" control to press here; pause
        // is the equivalent clean stop for this playback mode.
        guard tortureCardOpened else { throw SmokeError(message: "skipped: torture card did not open") }
        let pause = try waitForElement("Pause control", in: try mainWindow(),
                                       role: kAXButtonRole as String, containing: "Pause")
        guard pause.press() else { throw SmokeError(message: "AXPress failed on \(pause.summary)") }
        _ = try waitForElement("paused indicator", in: try mainWindow(), containing: "Playback paused")
    }
}

// MARK: Flow 4: Command-K search opens, filters, and closes

if enabled("f4") {
    var commandKSessionID: String?
    run.step("f4-commandk", "Command-K opens the switcher") {
        app.activate()
        app.key(Key.k, command: true)
        _ = try waitForElement("switcher search field", in: try mainWindow(),
                               role: kAXTextFieldRole as String, containing: "Search name")
        let row = try waitForElement("session row", in: try mainWindow(), timeout: 15) { element in
            element.role == kAXButtonRole as String
                && element.matches("Session ")
                && element.matchText.components(separatedBy: .whitespacesAndNewlines)
                    .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                    .contains { UUID(uuidString: $0) != nil }
        }
        commandKSessionID = row.matchText.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .first { UUID(uuidString: $0) != nil }
    }
    run.step("f4-commandk", "search filters to an exact session ID") {
        guard let commandKSessionID else {
            throw SmokeError(message: "could not capture a session ID from the initial Command-K results")
        }
        let field = try waitForElement("switcher search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search name")
        var attempts: [String] = []
        try waitUntil("query text to land in the search field", timeout: 12, interval: 0.8) {
            if field.stringValue.contains(commandKSessionID) { return true }
            app.activate()
            _ = field.setFocused()
            if !field.setValue(commandKSessionID) {
                app.type(commandKSessionID)
                attempts.append("typed (value now \"\(field.stringValue)\")")
            } else {
                attempts.append("set (value now \"\(field.stringValue)\")")
            }
            return field.stringValue.contains(commandKSessionID)
        }
        guard field.stringValue.contains(commandKSessionID) else {
            throw SmokeError(message: "search field never accepted text; attempts: \(attempts.joined(separator: ", "))")
        }
        _ = try waitForElement("filtered session", in: try mainWindow(), timeout: 10) { element in
            element.role == kAXButtonRole as String
                && element.matches(commandKSessionID)
        }
    }
    run.step("f4-commandk", "Escape closes the switcher") {
        // A just-rendered result list can swallow the first Escape; retry once.
        app.key(Key.escape)
        do {
            try waitForElementGone("switcher search field", in: try mainWindow(),
                                   role: kAXTextFieldRole as String, containing: "Search name", timeout: 4)
        } catch {
            app.key(Key.escape)
            try waitForElementGone("switcher search field", in: try mainWindow(),
                                   role: kAXTextFieldRole as String, containing: "Search name")
        }
    }
    run.step("f4-commandk", "Command-K reopens with the cursor back in search") {
        app.key(Key.k, command: true)
        let field = try waitForElement("switcher search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search name")
        // No setFocused or setValue fallback on purpose: this step exists to
        // prove the field takes focus by itself every time the palette opens.
        try waitUntil("typed text to land in the reopened field", timeout: 6, interval: 0.6) {
            if field.stringValue.contains("smoke") { return true }
            app.type("smoke")
            return field.stringValue.contains("smoke")
        }
        app.key(Key.escape)
        try waitForElementGone("switcher search field", in: try mainWindow(),
                               role: kAXTextFieldRole as String, containing: "Search name")
    }
}

// MARK: Flow 7: real Codex watch plus send-to-agent round trip

if enabled("f7") {
    let env = ProcessInfo.processInfo.environment
    let nonce = env["ATTACHE_CODEX_TWO_WAY_NONCE"] ?? ""
    let sessionID = env["ATTACHE_CODEX_TWO_WAY_SESSION_ID"] ?? ""
    let sessionFile = env["ATTACHE_CODEX_TWO_WAY_SESSION_FILE"] ?? ""
    let pongToken = env["ATTACHE_CODEX_TWO_WAY_PONG_TOKEN"] ?? (nonce.isEmpty ? "" : "ATTACHE_PONG_\(nonce)")
    let instruction = env["ATTACHE_CODEX_TWO_WAY_INSTRUCTION"] ?? "reply exactly \(pongToken) and do not use tools."
    var focusedSession = false
    var composerOpened = false
    var instructionStaged = false
    var enableConfirmed = false
    var sendConfirmed = false

    run.step("f7-codex-two-way", "environment identifies the disposable Codex session") {
        guard !nonce.isEmpty else { throw SmokeError(message: "ATTACHE_CODEX_TWO_WAY_NONCE is required") }
        guard !sessionID.isEmpty else { throw SmokeError(message: "ATTACHE_CODEX_TWO_WAY_SESSION_ID is required") }
        guard !sessionFile.isEmpty else { throw SmokeError(message: "ATTACHE_CODEX_TWO_WAY_SESSION_FILE is required") }
        guard !pongToken.isEmpty else { throw SmokeError(message: "ATTACHE_CODEX_TWO_WAY_PONG_TOKEN is required") }
        guard FileManager.default.fileExists(atPath: sessionFile) else {
            throw SmokeError(message: "session file does not exist: \(sessionFile)")
        }
    }

    run.step("f7-codex-two-way", "spawned Codex session appears in Command-K search") {
        try focusSessionInCommandK(query: nonce, sessionID: sessionID)
        focusedSession = true
    }

    run.step("f7-codex-two-way", "Tell Agent call composer opens for the focused session") {
        guard focusedSession else { throw SmokeError(message: "skipped: session was not focused") }
        _ = try openAgentCallComposer()
        composerOpened = true
    }

    run.step("f7-codex-two-way", "instruction is entered and staged for send-to-agent") {
        guard composerOpened else { throw SmokeError(message: "skipped: composer did not open") }
        try enterAgentCallInstruction(instruction, mustContain: pongToken)
        try pressAgentInstructionSend()
        instructionStaged = true
    }

    run.step("f7-codex-two-way", "first-use send-to-agent enable sheet confirms") {
        guard instructionStaged else { throw SmokeError(message: "skipped: instruction was not staged") }
        let enable = try waitForElement("Enable send-to-agent button", in: try mainWindow(),
                                        role: kAXButtonRole as String, exactly: "Enable send-to-agent",
                                        timeout: 12)
        guard enable.press() else {
            throw SmokeError(message: "AXPress failed on Enable send-to-agent: \(enable.summary); actions: \(enable.actionNames)")
        }
        _ = try waitForElement("per-instruction confirmation sheet", in: try mainWindow(),
                               containing: pongToken, timeout: 12)
        enableConfirmed = true
    }

    run.step("f7-codex-two-way", "per-instruction confirmation sends to Codex") {
        guard enableConfirmed else { throw SmokeError(message: "skipped: send-to-agent was not enabled") }
        let confirm = try waitForElement("Send to agent confirmation button", in: try mainWindow(),
                                         role: kAXButtonRole as String, exactly: "Send to agent",
                                         timeout: 12)
        guard confirm.press() else {
            throw SmokeError(message: "AXPress failed on Send to agent confirmation: \(confirm.summary); actions: \(confirm.actionNames)")
        }
        try waitForElementGone("confirmation sheet", in: try mainWindow(), containing: "Send this to", timeout: 8)
        sendConfirmed = true
    }

    run.step("f7-codex-two-way", "Codex transcript records the resumed instruction and pong reply") {
        guard sendConfirmed else { throw SmokeError(message: "skipped: instruction was not sent to Codex") }
        try waitForFile(sessionFile, toContain: "resumed Codex instruction and pong reply", timeout: 240, interval: 2) { text in
            text.contains("reply exactly \(pongToken)")
                && occurrenceCount(of: pongToken, in: text) >= 2
        }
    }

    run.step("f7-codex-two-way", "Attaché files the Codex pong as a watched-session card") {
        var resultingSummary = ""
        try waitUntil("delivered instruction to link its resulting card", timeout: 120, interval: 2) {
            let command = """
            sqlite3 "$HOME/Library/Application Support/Attache/attache.sqlite" \
              "SELECT c.summary FROM instructions i JOIN cards c ON c.id=i.resulting_card_id WHERE i.session_id='\(sessionID)' AND i.state='delivered' ORDER BY i.created_at DESC LIMIT 1;"
            """
            guard let output = try? runShell(command) else { return false }
            resultingSummary = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return !resultingSummary.isEmpty
        }
        app.activate()
        app.key(Key.i, command: true)
        let field = try waitForElement("inbox search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search inbox",
                                       timeout: 15)
        _ = field.setFocused()
        if !field.setValue(resultingSummary) { app.type(resultingSummary) }
        _ = try waitForInboxCardRow(containing: resultingSummary, timeout: 30)
        app.key(Key.escape)
        try? waitForElementGone("inbox search field", in: try mainWindow(),
                                role: kAXTextFieldRole as String, containing: "Search inbox", timeout: 5)
    }
}

// MARK: Flow 8: host stages Codex instruction, then personality reads Codex's reply

if enabled("f8") {
    let env = ProcessInfo.processInfo.environment
    let nonce = env["ATTACHE_PERSONALITY_TWO_WAY_NONCE"] ?? ""
    let sessionID = env["ATTACHE_PERSONALITY_TWO_WAY_SESSION_ID"] ?? ""
    let sessionFile = env["ATTACHE_PERSONALITY_TWO_WAY_SESSION_FILE"] ?? ""
    let providerLog = env["ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG"] ?? ""
    let pongToken = env["ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN"] ?? (nonce.isEmpty ? "" : "ATTACHE_SUM_\(nonce)_4")
    let directToken = env["ATTACHE_PERSONALITY_TWO_WAY_DIRECT_TOKEN"] ?? (nonce.isEmpty ? "" : "ATTACHE_DIRECT_\(nonce)_9")
    let mismatchToken = env["ATTACHE_PERSONALITY_TWO_WAY_MISMATCH_TOKEN"] ?? (nonce.isEmpty ? "" : "ATTACHE_MISMATCH_\(nonce)_7")
    let firstPrompt = env["ATTACHE_PERSONALITY_TWO_WAY_FIRST_PROMPT"] ?? "Tell Codex to reply exactly \(pongToken) and do not use tools."
    let secondPrompt = env["ATTACHE_PERSONALITY_TWO_WAY_SECOND_PROMPT"] ?? "What did Codex say? Read the session transcript."
    let mismatchPrompt = env["ATTACHE_PERSONALITY_TWO_WAY_MISMATCH_PROMPT"] ?? "Tell Claude Code to reply exactly \(mismatchToken) and do not use tools."
    let directPrompt = env["ATTACHE_PERSONALITY_TWO_WAY_DIRECT_PROMPT"] ?? "Send Codex directly and tell it to reply exactly \(directToken) and do not use tools."
    var focusedSession = false
    var conversationOpened = false
    var instructionStaged = false
    var enableConfirmed = false
    var sendConfirmed = false
    var codexReplyObserved = false

    run.step("f8-personality-codex-two-way", "environment identifies the disposable Codex session and personality provider") {
        guard !nonce.isEmpty else { throw SmokeError(message: "ATTACHE_PERSONALITY_TWO_WAY_NONCE is required") }
        guard !sessionID.isEmpty else { throw SmokeError(message: "ATTACHE_PERSONALITY_TWO_WAY_SESSION_ID is required") }
        guard !sessionFile.isEmpty else { throw SmokeError(message: "ATTACHE_PERSONALITY_TWO_WAY_SESSION_FILE is required") }
        guard !providerLog.isEmpty else { throw SmokeError(message: "ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG is required") }
        guard !pongToken.isEmpty else { throw SmokeError(message: "ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN is required") }
        guard !directToken.isEmpty else { throw SmokeError(message: "ATTACHE_PERSONALITY_TWO_WAY_DIRECT_TOKEN is required") }
        guard FileManager.default.fileExists(atPath: sessionFile) else {
            throw SmokeError(message: "session file does not exist: \(sessionFile)")
        }
        guard FileManager.default.fileExists(atPath: providerLog) else {
            throw SmokeError(message: "provider log does not exist: \(providerLog)")
        }
    }

    run.step("f8-personality-codex-two-way", "spawned Codex session appears in Command-K search") {
        try focusSessionInCommandK(query: nonce, sessionID: sessionID)
        focusedSession = true
    }

    run.step("f8-personality-codex-two-way", "Talk conversation opens for the focused session") {
        guard focusedSession else { throw SmokeError(message: "skipped: session was not focused") }
        app.key(Key.l, command: true)
        _ = try waitForElement("conversation or call message field", in: try mainWindow(), timeout: 20) { element in
            element.role == kAXTextFieldRole as String
                && (element.matchesExactly("Conversation message") || element.matchesExactly("Call message"))
        }
        conversationOpened = true
    }

    run.step("f8-personality-codex-two-way", "Attaché stages a Codex instruction from the user's request") {
        guard conversationOpened else { throw SmokeError(message: "skipped: conversation did not open") }
        try sendConversationPrompt(firstPrompt)
        let enable = try waitForElement("Enable send-to-agent button", in: try mainWindow(),
                                        role: kAXButtonRole as String, exactly: "Enable send-to-agent",
                                        timeout: 40)
        instructionStaged = true
        guard enable.press() else {
            throw SmokeError(message: "AXPress failed on Enable send-to-agent: \(enable.summary); actions: \(enable.actionNames)")
        }
        enableConfirmed = true
    }

    run.step("f8-personality-codex-two-way", "per-instruction confirmation sends the staged request") {
        guard instructionStaged, enableConfirmed else {
            throw SmokeError(message: "skipped: instruction was not staged")
        }
        _ = try waitForElement("per-instruction confirmation sheet", in: try mainWindow(),
                               containing: pongToken, timeout: 20)
        let confirm = try waitForElement("Send to agent confirmation button", in: try mainWindow(),
                                         role: kAXButtonRole as String, exactly: "Send to agent",
                                         timeout: 12)
        guard confirm.press() else {
            throw SmokeError(message: "AXPress failed on Send to agent confirmation: \(confirm.summary); actions: \(confirm.actionNames)")
        }
        try waitForElementGone("confirmation sheet", in: try mainWindow(), containing: "Send this to", timeout: 8)
        sendConfirmed = true
    }

    run.step("f8-personality-codex-two-way", "Codex transcript records the staged instruction and answer") {
        guard sendConfirmed else { throw SmokeError(message: "skipped: staged instruction was not sent") }
        try waitForFile(sessionFile, toContain: "personality-staged Codex instruction and answer", timeout: 240, interval: 2) { text in
            text.localizedCaseInsensitiveContains("reply exactly \(pongToken)")
                && occurrenceCount(of: pongToken, in: text) >= 2
        }
    }

    run.step("f8-personality-codex-two-way", "Attaché files the Codex answer as a watched-session card") {
        app.activate()
        app.key(Key.i, command: true)
        let field = try waitForElement("inbox search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search inbox",
                                       timeout: 15)
        _ = field.setFocused()
        if !field.setValue(pongToken) { app.type(pongToken) }
        do {
            _ = try waitForInboxCardRow(containing: pongToken, timeout: 60)
            app.key(Key.escape)
            try? waitForElementGone("inbox search field", in: try mainWindow(),
                                    role: kAXTextFieldRole as String, containing: "Search inbox", timeout: 5)
        } catch {
            app.key(Key.escape)
            try? waitForElementGone("inbox search field", in: try mainWindow(),
                                    role: kAXTextFieldRole as String, containing: "Search inbox", timeout: 5)
            app.key(Key.y, command: true)
            let historyField = try waitForElement("history search field", in: try mainWindow(),
                                                  role: kAXTextFieldRole as String, containing: "Search history",
                                                  timeout: 15)
            _ = historyField.setFocused()
            if !historyField.setValue(pongToken) { app.type(pongToken) }
            _ = try waitForHistoryCardRow(filteredBy: pongToken, timeout: 60)
            app.key(Key.escape)
            try? waitForElementGone("history search field", in: try mainWindow(),
                                    role: kAXTextFieldRole as String, containing: "Search history", timeout: 5)
        }
        codexReplyObserved = true
    }

    run.step("f8-personality-codex-two-way", "personality reads the updated session and tells the user Codex said 4") {
        guard codexReplyObserved else { throw SmokeError(message: "skipped: Codex answer was not observed") }
        try sendConversationPrompt(secondPrompt)
        do {
            _ = try waitForElement("personality final answer", in: try mainWindow(),
                                   containing: "Codex said 4.", timeout: 15)
        } catch {
            app.key(Key.y, command: true)
            let field = try waitForElement("history search field", in: try mainWindow(),
                                           role: kAXTextFieldRole as String, containing: "Search history",
                                           timeout: 15)
            _ = field.setFocused()
            if !field.setValue("Codex said 4") { app.type("Codex said 4") }
            _ = try waitForHistoryCardRow(filteredBy: "Codex said 4", timeout: 60)
            app.key(Key.escape)
            try? waitForElementGone("history search field", in: try mainWindow(),
                                    role: kAXTextFieldRole as String, containing: "Search history", timeout: 5)
        }
    }

    run.step("f8-personality-codex-two-way", "personality provider read the updated transcript") {
        try waitForFile(providerLog, toContain: "transcript read tool call", timeout: 10, interval: 0.5) { text in
            text.contains("\"name\": \"read_session_transcript\"")
        }
    }

    run.step("f8-personality-codex-two-way", "question about Codex stays with Attaché instead of staging another send") {
        let query = "SELECT COUNT(*) FROM instructions WHERE session_id='\(sessionID)' AND origin='personality_tool';"
        let output = try runShell("sqlite3 \"$HOME/Library/Application Support/Attache/Attache.sqlite\" \"\(query)\"")
        guard (Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) == 1 else {
            throw SmokeError(message: "agent-status question unexpectedly staged another personality instruction")
        }
    }

    run.step("f8-personality-codex-two-way", "enabled Ask Attaché handoff still requires native confirmation") {
        try sendConversationPrompt(directPrompt)
        _ = try waitForElement("second personality confirmation sheet", in: try mainWindow(),
                               containing: directToken, timeout: 20)
        let confirm = try waitForElement("second Send to agent confirmation button", in: try mainWindow(),
                                         role: kAXButtonRole as String, exactly: "Send to agent",
                                         timeout: 12)
        guard confirm.press() else {
            throw SmokeError(message: "AXPress failed on second Send to agent confirmation: \(confirm.summary)")
        }
        try waitForElementGone("second confirmation sheet", in: try mainWindow(), containing: "Send this to", timeout: 8)
        try waitUntil("direct personality handoff to persist the exact structured payload", timeout: 20, interval: 0.5) {
            let query = "SELECT COUNT(*) FROM instructions WHERE session_id='\(sessionID)' AND origin='personality_tool' AND source_utterance LIKE '%\(directToken)%' AND text='Reply exactly \(directToken). Do not use tools.';"
            guard let output = try? runShell("sqlite3 \"$HOME/Library/Application Support/Attache/Attache.sqlite\" \"\(query)\"") else {
                return false
            }
            return (Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) == 1
        }
        try waitForFile(sessionFile, toContain: "direct personality handoff and answer", timeout: 240, interval: 2) { text in
            text.localizedCaseInsensitiveContains("reply exactly \(directToken)")
                && occurrenceCount(of: directToken, in: text) >= 2
        }
        try waitUntil("both personality handoffs to persist their delivery checkpoints", timeout: 20, interval: 0.5) {
            let query = "SELECT COUNT(*) FROM instructions WHERE session_id='\(sessionID)' AND origin='personality_tool' AND state='delivered' AND delivery_checkpoint IS NOT NULL;"
            guard let output = try? runShell("sqlite3 \"$HOME/Library/Application Support/Attache/Attache.sqlite\" \"\(query)\"") else {
                return false
            }
            return (Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) >= 2
        }
    }

    // INF-246: naming an agent that is not the frozen/watched target must be
    // refused deterministically, never rerouted and never silently staged.
    // This session only watches Codex (claudeCodeSourceEnabled is off in this
    // smoke's setup), so declaring intended_agent "claude_code" here hits the
    // "no watched session of that source" branch of AgentInstructionMismatch.
    run.step("f8-personality-codex-two-way", "explicit handoff naming an unwatched agent is blocked, not staged") {
        let personalityToolCountQuery = "SELECT COUNT(*) FROM instructions WHERE session_id='\(sessionID)' AND origin='personality_tool';"
        let before = try runShell("sqlite3 \"$HOME/Library/Application Support/Attache/Attache.sqlite\" \"\(personalityToolCountQuery)\"")
        let beforeCount = Int(before.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1

        try sendConversationPrompt(mismatchPrompt)
        _ = try waitForElement("wrong-agent refusal reply", in: try mainWindow(),
                               containing: "No staging occurred", timeout: 15)

        guard (try mainWindow()).firstDescendant(containing: "Send this to") == nil else {
            throw SmokeError(message: "mismatched intended_agent unexpectedly opened a send confirmation sheet")
        }
        // Give any (incorrect) async staging a moment to land before re-reading the DB.
        Thread.sleep(forTimeInterval: 2)
        let after = try runShell("sqlite3 \"$HOME/Library/Application Support/Attache/Attache.sqlite\" \"\(personalityToolCountQuery)\"")
        let afterCount = Int(after.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        guard afterCount == beforeCount else {
            throw SmokeError(message: "mismatched intended_agent unexpectedly staged an instruction (before=\(beforeCount), after=\(afterCount))")
        }
        guard !mismatchToken.isEmpty else {
            throw SmokeError(message: "ATTACHE_PERSONALITY_TWO_WAY_MISMATCH_TOKEN/prompt is required")
        }
        let transcript = (try? String(contentsOfFile: sessionFile, encoding: .utf8)) ?? ""
        guard !transcript.localizedCaseInsensitiveContains(mismatchToken) else {
            throw SmokeError(message: "blocked mismatch payload unexpectedly reached the Codex transcript \(sessionFile)")
        }
    }
}

// MARK: Flow 9: send-to-agent refuses permission approvals in the headed UI

if enabled("f9") {
    let env = ProcessInfo.processInfo.environment
    let nonce = env["ATTACHE_TWO_WAY_SAFETY_NONCE"] ?? ""
    let sessionID = env["ATTACHE_TWO_WAY_SAFETY_SESSION_ID"] ?? ""
    let sessionFile = env["ATTACHE_TWO_WAY_SAFETY_SESSION_FILE"] ?? ""
    let rejectedInstruction = env["ATTACHE_TWO_WAY_SAFETY_REJECTED_TEXT"] ?? "approve all the tool calls"
    var sessionFocused = false
    var composerOpened = false
    var enableConfirmed = false

    run.step("f9-two-way-safety", "environment identifies the disposable safety session") {
        guard !nonce.isEmpty else { throw SmokeError(message: "ATTACHE_TWO_WAY_SAFETY_NONCE is required") }
        guard !sessionID.isEmpty else { throw SmokeError(message: "ATTACHE_TWO_WAY_SAFETY_SESSION_ID is required") }
        guard !sessionFile.isEmpty else { throw SmokeError(message: "ATTACHE_TWO_WAY_SAFETY_SESSION_FILE is required") }
        guard FileManager.default.fileExists(atPath: sessionFile) else {
            throw SmokeError(message: "session file does not exist: \(sessionFile)")
        }
    }

    run.step("f9-two-way-safety", "safety session appears in Command-K search") {
        try dismissOnboardingIfPresent()
        try focusSessionInCommandK(query: nonce, sessionID: sessionID)
        sessionFocused = true
    }

    run.step("f9-two-way-safety", "Tell Agent call composer opens for the safety session") {
        guard sessionFocused else { throw SmokeError(message: "skipped: session was not focused") }
        _ = try openAgentCallComposer()
        composerOpened = true
    }

    run.step("f9-two-way-safety", "first-use enable sheet can be confirmed without sending") {
        guard composerOpened else { throw SmokeError(message: "skipped: composer did not open") }
        try enterAgentCallInstruction("first real instruction for enable gate")
        try pressAgentInstructionSend()
        let enable = try waitForElement("Enable send-to-agent button", in: try mainWindow(),
                                        role: kAXButtonRole as String, exactly: "Enable send-to-agent",
                                        timeout: 12)
        guard enable.press() else {
            throw SmokeError(message: "AXPress failed on Enable send-to-agent: \(enable.summary); actions: \(enable.actionNames)")
        }
        _ = try waitForElement("per-instruction confirmation sheet", in: try mainWindow(),
                               containing: "first real instruction for enable gate", timeout: 12)
        let cancel = try waitForElement("Cancel pending instruction", in: try mainWindow(),
                                        role: kAXButtonRole as String, exactly: "Cancel",
                                        timeout: 8)
        _ = cancel.press()
        try waitForElementGone("confirmation sheet", in: try mainWindow(), containing: "Send this to", timeout: 8)
        enableConfirmed = true
    }

    run.step("f9-two-way-safety", "approval-like instruction is refused before confirmation") {
        guard enableConfirmed else { throw SmokeError(message: "skipped: send-to-agent was not enabled") }
        // Tell Agent is deliberately one-shot, including when the prior
        // confirmation is canceled. Select it again so this assertion reaches
        // the guarded agent-send path instead of accidentally asking Attaché.
        try selectConversationDestination("Tell Agent")
        _ = try waitForElement("frozen Tell Agent target for refusal", in: try mainWindow(), timeout: 8) { element in
            element.role == (kAXStaticTextRole as String)
                && element.stringValue.localizedCaseInsensitiveContains(nonce)
        }
        try enterAgentCallInstruction(rejectedInstruction)
        // The first staging acknowledgement is spoken in the live call. A
        // second turn is intentionally disabled until that audio completes.
        try pressAgentInstructionSend(timeout: 30)
        _ = try waitForElement("visible safety refusal", in: try mainWindow(),
                               containing: "won't deliver permission", timeout: 8)
        guard (try mainWindow()).firstDescendant(containing: "Send this to") == nil else {
            throw SmokeError(message: "approval-like instruction opened a send confirmation sheet")
        }
    }

    run.step("f9-two-way-safety", "refused payload never reaches the Codex transcript") {
        Thread.sleep(forTimeInterval: 4)
        let transcript = (try? String(contentsOfFile: sessionFile, encoding: .utf8)) ?? ""
        guard !transcript.localizedCaseInsensitiveContains(rejectedInstruction) else {
            throw SmokeError(message: "refused instruction appeared in transcript \(sessionFile)")
        }
    }
}

// MARK: Flow 14: explicit agent destination stages without provider tools,
// then (INF-250) delivers a second turn end to end against a fake Codex CLI.

if enabled("f14") {
    let env = ProcessInfo.processInfo.environment
    let nonce = env["ATTACHE_AGENT_MODE_NONCE"] ?? env["ATTACHE_AGENT_INTENT_NONCE"] ?? ""
    let sessionID = env["ATTACHE_AGENT_MODE_SESSION_ID"] ?? env["ATTACHE_AGENT_INTENT_SESSION_ID"] ?? ""
    let sessionFile = env["ATTACHE_AGENT_MODE_SESSION_FILE"] ?? env["ATTACHE_AGENT_INTENT_SESSION_FILE"] ?? ""
    let instructionToken = env["ATTACHE_AGENT_MODE_TOKEN"] ?? env["ATTACHE_AGENT_INTENT_TOKEN"] ?? (nonce.isEmpty ? "" : "ATTACHE_AGENT_MODE_\(nonce)")
    let prompt = env["ATTACHE_AGENT_MODE_PROMPT"] ?? env["ATTACHE_AGENT_INTENT_PROMPT"] ?? "reply exactly \(instructionToken) and do not use tools."
    // Second turn (INF-250): confirmed instead of canceled, delivered against
    // the fake `codex` CLI installed at ~/.local/bin/codex by
    // scripts/agent-destination-smoke.sh (see create-fake-codex-home.py).
    let deliverToken = env["ATTACHE_AGENT_MODE_DELIVER_TOKEN"] ?? (nonce.isEmpty ? "" : "ATTACHE_AGENT_MODE_DELIVER_\(nonce)")
    let deliverPrompt = env["ATTACHE_AGENT_MODE_DELIVER_PROMPT"] ?? "reply exactly \(deliverToken) and do not use tools."
    var focusedSession = false
    var stagedInstruction = false
    var deliverStaged = false
    var deliverConfirmed = false

    run.step("f14-agent-destination", "environment identifies the disposable Codex session") {
        guard !nonce.isEmpty else { throw SmokeError(message: "ATTACHE_AGENT_MODE_NONCE is required") }
        guard !sessionID.isEmpty else { throw SmokeError(message: "ATTACHE_AGENT_MODE_SESSION_ID is required") }
        guard !sessionFile.isEmpty else { throw SmokeError(message: "ATTACHE_AGENT_MODE_SESSION_FILE is required") }
        guard !instructionToken.isEmpty else { throw SmokeError(message: "ATTACHE_AGENT_MODE_TOKEN is required") }
        guard !deliverToken.isEmpty else { throw SmokeError(message: "ATTACHE_AGENT_MODE_DELIVER_TOKEN is required") }
        guard FileManager.default.fileExists(atPath: sessionFile) else {
            throw SmokeError(message: "session file does not exist: \(sessionFile)")
        }
    }

    run.step("f14-agent-destination", "Codex session appears in Command-K search") {
        try dismissOnboardingIfPresent()
        try focusSessionInCommandK(query: nonce, sessionID: sessionID)
        focusedSession = true
    }

    run.step("f14-agent-destination", "Tell Agent mode opens send-to-agent enable without personality routing") {
        guard focusedSession else { throw SmokeError(message: "skipped: session was not focused") }
        app.key(Key.l, command: true)
        try selectConversationDestination("Tell Agent")
        _ = try waitForElement("visible frozen Tell Agent target", in: try mainWindow(), timeout: 8) { element in
            element.matches("Tell Codex") && element.matches(nonce)
        }
        try sendConversationPrompt(prompt)
        let enable = try waitForElement("Enable send-to-agent button", in: try mainWindow(),
                                        role: kAXButtonRole as String, exactly: "Enable send-to-agent",
                                        timeout: 15)
        guard enable.press() else {
            throw SmokeError(message: "AXPress failed on Enable send-to-agent: \(enable.summary); actions: \(enable.actionNames)")
        }
        _ = try waitForElement("per-instruction confirmation sheet", in: try mainWindow(),
                               containing: instructionToken, timeout: 12)
        stagedInstruction = true
    }

    run.step("f14-agent-destination", "staged instruction can be canceled before delivery") {
        guard stagedInstruction else { throw SmokeError(message: "skipped: instruction was not staged") }
        let cancel = try waitForElement("Cancel pending instruction", in: try mainWindow(),
                                        role: kAXButtonRole as String, exactly: "Cancel",
                                        timeout: 8)
        _ = cancel.press()
        try waitForElementGone("confirmation sheet", in: try mainWindow(), containing: "Send this to", timeout: 8)
    }

    run.step("f14-agent-destination", "Tell Agent resets to Ask Attaché after one turn") {
        let ask = try waitForElement("Ask Attaché destination", in: try mainWindow(),
                                     role: kAXRadioButtonRole as String, containing: "Ask Attaché", timeout: 8)
        try waitUntil("Ask Attaché to be selected after the Tell Agent turn", timeout: 8) {
            ask.stringValue == "1"
        }
    }

    run.step("f14-agent-destination", "explicit agent-mode prompt was not delivered without final confirmation") {
        Thread.sleep(forTimeInterval: 2)
        let transcript = (try? String(contentsOfFile: sessionFile, encoding: .utf8)) ?? ""
        guard !transcript.contains(instructionToken) else {
            throw SmokeError(message: "unconfirmed explicit agent instruction appeared in transcript \(sessionFile)")
        }
    }

    // INF-250: a second Tell Agent turn, this time confirmed instead of
    // canceled, delivered end to end against the fake `codex` CLI. Two-way is
    // already enabled for this session from the first turn above, so this
    // instruction goes straight to the per-instruction confirmation sheet
    // (no "Enable send-to-agent" sheet a second time).
    run.step("f14-agent-destination", "Tell Agent stages a second instruction for real delivery") {
        try selectConversationDestination("Tell Agent")
        _ = try waitForElement("visible frozen Tell Agent target", in: try mainWindow(), timeout: 8) { element in
            element.matches("Tell Codex") && element.matches(nonce)
        }
        try sendConversationPrompt(deliverPrompt)
        _ = try waitForElement("per-instruction confirmation sheet", in: try mainWindow(),
                               containing: deliverToken, timeout: 12)
        deliverStaged = true
    }

    run.step("f14-agent-destination", "confirming the second instruction delivers it through the fake Codex CLI") {
        guard deliverStaged else { throw SmokeError(message: "skipped: second instruction was not staged") }
        let confirm = try waitForElement("Send to agent confirmation button", in: try mainWindow(),
                                         role: kAXButtonRole as String, exactly: "Send to agent",
                                         timeout: 12)
        guard confirm.press() else {
            throw SmokeError(message: "AXPress failed on Send to agent confirmation: \(confirm.summary); actions: \(confirm.actionNames)")
        }
        try waitForElementGone("confirmation sheet", in: try mainWindow(), containing: "Send this to", timeout: 8)
        deliverConfirmed = true
    }

    // Assertion 1 (INF-250): the fake codex records the resume invocation with
    // the exact text sent. The fake CLI (create-fake-codex-home.py) appends the
    // exact argument it received as a user response_item, so this proves the
    // real delivery path (not a canceled stage) reached the fake CLI verbatim.
    run.step("f14-agent-destination", "fake Codex records the resume invocation with the exact text sent") {
        guard deliverConfirmed else { throw SmokeError(message: "skipped: second instruction was not confirmed") }
        try waitForFile(sessionFile, toContain: "delivered Tell Agent instruction", timeout: 60, interval: 1) { text in
            text.contains(deliverPrompt)
        }
    }

    // Assertion 2 (INF-250): Tell Agent is deliberately one-shot (see
    // AppModel.sendConversationMessage's "Tell Agent is deliberately one-shot"
    // comment); confirm the destination reset holds for the delivered turn too,
    // not just the canceled one.
    run.step("f14-agent-destination", "Tell Agent resets to Ask Attaché after the delivered turn") {
        let ask = try waitForElement("Ask Attaché destination", in: try mainWindow(),
                                     role: kAXRadioButtonRole as String, containing: "Ask Attaché", timeout: 8)
        try waitUntil("Ask Attaché to be selected after the delivered Tell Agent turn", timeout: 8) {
            ask.stringValue == "1"
        }
    }

    // Assertion 3 (INF-250): A2's distinct .sendDelivered visual renders, via
    // the exact AX label CallHUD.swift exposes ("Conversation status: " plus
    // CallStatusPresentation's "Sent to \(target) · watching for the reply").
    run.step("f14-agent-destination", "delivered send renders A2's distinct sendDelivered status") {
        guard deliverConfirmed else { throw SmokeError(message: "skipped: second instruction was not delivered") }
        _ = try waitForElement("delivered conversation status label", in: try mainWindow(), timeout: 60) { element in
            element.matches("Conversation status:") && element.matches("watching for the reply")
        }
    }

    // Assertion 4 (INF-250): the two-way log's instructions row shows
    // origin=tell_agent, state=delivered for this exact instruction. No
    // settings/history view renders origin as text (grepped for
    // InstructionOrigin/origin renderers), so this queries the store directly,
    // matching f7/f8's existing precedent for delivery-state assertions.
    run.step("f14-agent-destination", "two-way log records delivered state with origin=tell_agent") {
        let query = """
        SELECT COUNT(*) FROM instructions \
        WHERE session_id='\(sessionID)' AND origin='tell_agent' AND state='delivered' \
        AND text='\(deliverPrompt)';
        """
        try waitUntil("delivered tell_agent instruction to land in the instructions table", timeout: 30, interval: 1) {
            guard let output = try? runShell("sqlite3 \"$HOME/Library/Application Support/Attache/Attache.sqlite\" \"\(query)\"") else {
                return false
            }
            return (Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) == 1
        }
    }
}

// MARK: Flow 15: live Ask Attaché text send shows acceptance and thinking feedback

if enabled("f15") {
    let env = ProcessInfo.processInfo.environment
    let nonce = env["ATTACHE_CONVERSATION_FEEDBACK_NONCE"] ?? ""
    let providerLog = env["ATTACHE_CONVERSATION_FEEDBACK_PROVIDER_LOG"] ?? ""
    let prompt = env["ATTACHE_CONVERSATION_FEEDBACK_PROMPT"] ?? "ATTACHE_CONVERSATION_FEEDBACK \(nonce)"
    let replyToken = env["ATTACHE_CONVERSATION_FEEDBACK_REPLY"] ?? (nonce.isEmpty ? "" : "ATTACHE_CONVERSATION_FEEDBACK_REPLY_\(nonce)")

    run.step("f15-conversation-feedback", "environment identifies the deterministic personality provider") {
        guard !nonce.isEmpty else { throw SmokeError(message: "ATTACHE_CONVERSATION_FEEDBACK_NONCE is required") }
        guard !providerLog.isEmpty else { throw SmokeError(message: "ATTACHE_CONVERSATION_FEEDBACK_PROVIDER_LOG is required") }
        guard !replyToken.isEmpty else { throw SmokeError(message: "ATTACHE_CONVERSATION_FEEDBACK_REPLY is required") }
        guard FileManager.default.fileExists(atPath: providerLog) else {
            throw SmokeError(message: "provider log does not exist: \(providerLog)")
        }
    }

    run.step("f15-conversation-feedback", "Ask Attaché call message clears and shows thinking feedback") {
        try dismissOnboardingIfPresent()
        app.key(Key.l, command: true)
        try selectConversationDestination("Ask Attaché")
        let field = try waitForElement("call message field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, exactly: "Call message",
                                       timeout: 20)
        _ = field.setFocused()
        if !field.setValue(prompt) { app.type(prompt) }
        try waitUntil("call text to land", timeout: 8, interval: 0.5) {
            if field.stringValue.contains(prompt) { return true }
            _ = field.setFocused()
            if !field.setValue(prompt) { app.type(prompt) }
            return field.stringValue.contains(prompt)
        }
        let send = try waitForElement("call send button", in: try mainWindow(),
                                      role: kAXButtonRole as String, exactly: "Send call message",
                                      timeout: 8)
        guard send.press() else {
            throw SmokeError(message: "AXPress failed on call send button: \(send.summary); actions: \(send.actionNames)")
        }
        try waitUntil("call field clears after accepting the message", timeout: 5, interval: 0.25) {
            field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        _ = try waitForElement("visible thinking feedback", in: try mainWindow(), containing: "Thinking", timeout: 5)
    }

    run.step("f15-conversation-feedback", "Ask Attaché shows audio preparation feedback") {
        _ = try waitForElement("visible audio preparation feedback", in: try mainWindow(),
                               containing: "Preparing audio",
                               timeout: 20)
    }

    run.step("f15-conversation-feedback", "Ask Attaché reply starts through karaoke captions") {
        _ = try waitForElement("live reply caption surface", in: try mainWindow(),
                               containing: "Assistant speaking", timeout: 60)
        try waitUntil("live reply captions to carry the deterministic reply token", timeout: 30) {
            guard let window = try? mainWindow(),
                  window.firstDescendant(containing: "Assistant speaking") != nil else {
                return false
            }
            return window.firstDescendant(containing: replyToken) != nil
        }
        let providerText = (try? String(contentsOfFile: providerLog, encoding: .utf8)) ?? ""
        guard providerText.contains(prompt) else {
            throw SmokeError(message: "provider log did not record prompt \(prompt). Log:\n\(providerText)")
        }
    }

    run.step("f15-conversation-feedback", "Ask Attaché reply is filed as a replayable card") {
        app.key(Key.y, command: true)
        let field = try waitForElement("history search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search history",
                                       timeout: 15)
        _ = field.setFocused()
        if !field.setValue(replyToken) { app.type(replyToken) }
        _ = try waitForHistoryCardRow(filteredBy: replyToken, timeout: 60)
        app.key(Key.escape)
        try? waitForElementGone("history search field", in: try mainWindow(),
                                role: kAXTextFieldRole as String, containing: "Search history", timeout: 5)
    }
}

// MARK: Flow 16: usage failures restore the prompt and offer explicit model recovery

if enabled("f16") {
    let env = ProcessInfo.processInfo.environment
    let prompt = env["ATTACHE_CONVERSATION_RECOVERY_PROMPT"] ?? "ATTACHE_CONVERSATION_RECOVERY"
    let providerLog = env["ATTACHE_CONVERSATION_RECOVERY_PROVIDER_LOG"] ?? ""

    run.step("f16-conversation-recovery", "environment identifies the deterministic usage-limit provider") {
        guard !prompt.isEmpty else { throw SmokeError(message: "ATTACHE_CONVERSATION_RECOVERY_PROMPT is required") }
        guard !providerLog.isEmpty else { throw SmokeError(message: "ATTACHE_CONVERSATION_RECOVERY_PROVIDER_LOG is required") }
        guard FileManager.default.fileExists(atPath: providerLog) else {
            throw SmokeError(message: "provider log does not exist: \(providerLog)")
        }
    }

    run.step("f16-conversation-recovery", "usage failure restores the draft and exposes model recovery") {
        try dismissOnboardingIfPresent()
        app.key(Key.l, command: true)
        try selectConversationDestination("Ask Attaché")
        let field = try waitForElement("call message field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, exactly: "Call message",
                                       timeout: 20)
        _ = field.setFocused()
        if !field.setValue(prompt) { app.type(prompt) }
        let send = try waitForElement("call send button", in: try mainWindow(),
                                      role: kAXButtonRole as String, exactly: "Send call message",
                                      timeout: 8)
        guard send.press() else {
            throw SmokeError(message: "AXPress failed on call send button: \(send.summary); actions: \(send.actionNames)")
        }
        _ = try waitForElement("usage-limit status", in: try mainWindow(), containing: "usage limit", timeout: 20)
        try waitUntil("failed prompt to return to the composer", timeout: 8, interval: 0.25) {
            field.stringValue == prompt
        }
        _ = try waitForElement("model recovery menu", in: try mainWindow(),
                               exactly: "Switch conversation model", timeout: 8)
        let retry = try waitForElement("retry action", in: try mainWindow(),
                                       role: kAXButtonRole as String, exactly: "Retry failed conversation", timeout: 8)
        guard retry.isEnabled else { throw SmokeError(message: "retry action is disabled after a recoverable failure") }

        let before = (try? String(contentsOfFile: providerLog, encoding: .utf8)) ?? ""
        let requestCount = occurrenceCount(of: "\"event\": \"request\"", in: before)
        Thread.sleep(forTimeInterval: 1.5)
        let after = (try? String(contentsOfFile: providerLog, encoding: .utf8)) ?? ""
        guard occurrenceCount(of: "\"event\": \"request\"", in: after) == requestCount else {
            throw SmokeError(message: "usage failure retried without an explicit user action")
        }
    }

    run.step("f16-conversation-recovery", "model selection is applied before an explicit retry") {
        let switcher = try waitForElement("model recovery menu", in: try mainWindow(),
                                          exactly: "Switch conversation model", timeout: 8)
        try selectPopup(switcher, item: "attache-recovery-smoke")
        _ = try waitForElement("model-switch confirmation", in: try mainWindow(),
                               containing: "Switched to Ollama attache-recovery-smoke", timeout: 8)

        let retry = try waitForElement("retry action", in: try mainWindow(),
                                       role: kAXButtonRole as String, exactly: "Retry failed conversation", timeout: 8)
        guard retry.press() else {
            throw SmokeError(message: "AXPress failed on retry action: \(retry.summary); actions: \(retry.actionNames)")
        }
        _ = try waitForElement("usage-limit status after retry", in: try mainWindow(), containing: "usage limit", timeout: 20)
        let field = try waitForElement("restored retry draft", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, exactly: "Call message", timeout: 8)
        guard field.stringValue == prompt else {
            throw SmokeError(message: "retry did not restore the failed prompt; value=\(field.stringValue)")
        }
        let logText = (try? String(contentsOfFile: providerLog, encoding: .utf8)) ?? ""
        guard occurrenceCount(of: "\"event\": \"request\"", in: logText) == 2 else {
            throw SmokeError(message: "expected exactly two provider requests after explicit retry. Log:\n\(logText)")
        }
        guard logText.contains("\"model\": \"attache-recovery-smoke\"") else {
            throw SmokeError(message: "retry did not use the selected model. Log:\n\(logText)")
        }
    }
}

// MARK: Flow 17: recap failure offers recovery, and a plain-readback card badges why (INF-254)

if enabled("f17") {
    let env = ProcessInfo.processInfo.environment
    let providerLog = env["ATTACHE_RECAP_RECOVERY_PROVIDER_LOG"] ?? ""
    let recoveryModel = env["ATTACHE_RECAP_RECOVERY_MODEL"] ?? ""

    run.step("f17-recap-recovery", "environment identifies the deterministic recap provider log") {
        guard !providerLog.isEmpty else { throw SmokeError(message: "ATTACHE_RECAP_RECOVERY_PROVIDER_LOG is required") }
        guard !recoveryModel.isEmpty else { throw SmokeError(message: "ATTACHE_RECAP_RECOVERY_MODEL is required") }
        guard FileManager.default.fileExists(atPath: providerLog) else {
            throw SmokeError(message: "provider log does not exist: \(providerLog)")
        }
    }

    run.step("f17-recap-recovery", "two waiting updates are posted (recap needs at least two)") {
        try dismissOnboardingIfPresent()
        let outputA = try runShell("EVENT_TITLE='Recap recovery A' EXTERNAL_SESSION_ID='recap-recovery-a' scripts/send-event.sh")
        guard outputA.contains("accepted") else {
            throw SmokeError(message: "server did not accept the first recap-recovery demo event: \(outputA)")
        }
        let outputB = try runShell("EVENT_TITLE='Recap recovery B' EXTERNAL_SESSION_ID='recap-recovery-b' scripts/send-event.sh")
        guard outputB.contains("accepted") else {
            throw SmokeError(message: "server did not accept the second recap-recovery demo event: \(outputB)")
        }
        // Both events' own per-event presentation also hits the usage-limit
        // mock and falls back to plain readback, which the next step's badge
        // assertion relies on (INF-254 spec item 2, exercised for free here
        // instead of a separate script).
    }

    run.step("f17-recap-recovery", "Play recap starts a background recap over both updates") {
        app.key(Key.i, command: true)
        let recapButton = try waitForElement("play recap button", in: try mainWindow(),
                                             role: kAXButtonRole as String, containing: "Play recap of everything waiting", timeout: 15)
        guard recapButton.press() else {
            throw SmokeError(message: "AXPress failed on play recap button: \(recapButton.summary); actions: \(recapButton.actionNames)")
        }
        // Pressing it closes the inbox palette immediately (INF-169 behavior,
        // unchanged); the recap itself runs against the failing mock in the
        // background from here.
    }

    run.step("f17-recap-recovery", "recap failure surfaces recovery and a plain-readback badge") {
        // The recap failed (deterministic digest fallback played, unchanged),
        // so neither demo card was archived. Re-open the inbox and follow up
        // on the first one (⌘⏎, no arrow key pressed so it defaults to the
        // first row) to reach the card detail panel: the same panel hosts
        // both the recap recovery banner (independent of card selection) and
        // this specific card's plain-readback badge.
        app.key(Key.i, command: true)
        _ = try waitForElement("recap recovery demo card in inbox", in: try mainWindow(), containing: "Recap recovery", timeout: 15)
        app.key(Key.returnKey, command: true)

        let badge = try waitForElement("plain-readback badge", in: try mainWindow(), containing: "Spoken plainly", timeout: 20)
        // `PresentationFallbackBadge` collapses its children into one AX
        // element and sets the notice text as its accessibility label, so the
        // label itself (not just some collapsed-away inner Text node) must
        // carry the notice.
        guard badge.axDescription.localizedCaseInsensitiveContains("Spoken plainly") else {
            throw SmokeError(message: "plain-readback badge's accessibility label does not carry the notice text: \(badge.summary)")
        }

        let switcher = try waitForElement("recap model recovery menu", in: try mainWindow(),
                                          exactly: "Switch recap model", timeout: 20)
        _ = switcher
        let retry = try waitForElement("recap retry action", in: try mainWindow(),
                                       role: kAXButtonRole as String, exactly: "Retry recap", timeout: 8)
        guard retry.isEnabled else { throw SmokeError(message: "recap retry action is disabled after a recoverable failure") }
    }

    run.step("f17-recap-recovery", "switching the recap model then retrying actually succeeds") {
        let switcher = try waitForElement("recap model recovery menu", in: try mainWindow(),
                                          exactly: "Switch recap model", timeout: 8)
        try selectPopup(switcher, item: recoveryModel)
        _ = try waitForElement("recap model-switch confirmation", in: try mainWindow(),
                               containing: "Switched recap to Ollama \(recoveryModel)", timeout: 8)

        let retry = try waitForElement("recap retry action", in: try mainWindow(),
                                       role: kAXButtonRole as String, exactly: "Retry recap", timeout: 8)
        guard retry.press() else {
            throw SmokeError(message: "AXPress failed on recap retry action: \(retry.summary); actions: \(retry.actionNames)")
        }
        // Unlike f16 (whose mock keeps failing every model), this recap's
        // mock actually answers once the request names the switched model
        // (INF-254's ATTACHE_SMOKE_PROVIDER_RECOVERY_MODEL), so a real recap
        // card gets created and played: proof retry-after-switch succeeds,
        // not just that it fired a second identical failing request.
        _ = try waitForElement("recap success status", in: try mainWindow(), containing: "Playing your recap of 2 update", timeout: 20)
        let logText = (try? String(contentsOfFile: providerLog, encoding: .utf8)) ?? ""
        guard logText.contains("\"model\": \"\(recoveryModel)\"") else {
            throw SmokeError(message: "retry did not use the selected recap model. Log:\n\(logText)")
        }
    }
}

// MARK: Flow 10: no-key first run stays local and operable

if enabled("f10") {
    run.step("f10-no-key-first-run", "fresh profile shows onboarding without cloud credentials") {
        _ = try waitForElement("first-run welcome", in: try mainWindow(), containing: "Welcome to Attaché", timeout: 15)
    }

    run.step("f10-no-key-first-run", "onboarding API keys can be revealed only on demand") {
        let getStarted = try waitForElement(
            "Get started button",
            in: try mainWindow(),
            role: kAXButtonRole as String,
            exactly: "Get started"
        )
        guard getStarted.press() else { throw SmokeError(message: "AXPress failed on \(getStarted.summary)") }

        for expectedTitle in ["Connect your agents", "Pick a voice"] {
            _ = try waitForElement("onboarding step \(expectedTitle)", in: try mainWindow(), containing: expectedTitle)
            let next = try waitForElement("Continue button", in: try mainWindow(), role: kAXButtonRole as String, exactly: "Continue")
            guard next.press() else { throw SmokeError(message: "AXPress failed on \(next.summary)") }
        }

        _ = try waitForElement("model integration step", in: try mainWindow(), containing: "Connect a model")
        let xai = try waitForElement("xAI provider card", in: try mainWindow(), role: kAXButtonRole as String, containing: "xAI")
        guard xai.press() else { throw SmokeError(message: "AXPress failed on \(xai.summary)") }
        let reveal = try waitForElement("reveal xAI API key", in: try mainWindow(), role: kAXButtonRole as String, exactly: "Reveal xAI API key")
        guard reveal.press() else { throw SmokeError(message: "AXPress failed on \(reveal.summary)") }
        _ = try waitForElement("hide xAI API key", in: try mainWindow(), role: kAXButtonRole as String, exactly: "Hide xAI API key")
    }

    run.step("f10-no-key-first-run", "onboarding exposes an explicit keyboard-operable memory choice") {
        let next = try waitForElement(
            "Continue to character step",
            in: try mainWindow(),
            role: kAXButtonRole as String,
            exactly: "Continue"
        )
        guard next.press() else { throw SmokeError(message: "AXPress failed on \(next.summary)") }
        _ = try waitForElement("character onboarding step", in: try mainWindow(), containing: "Pick your Attaché")
        _ = try waitForElement("first-run memory choice", in: try mainWindow(), containing: "First-run memory choice")
        let off = try waitForElement(
            "Off memory choice",
            in: try mainWindow(),
            role: kAXRadioButtonRole as String,
            exactly: "Off"
        )
        guard off.setFocused() else {
            throw SmokeError(message: "memory choice is not keyboard focusable: \(off.summary)")
        }
        app.key(Key.space)
        _ = try waitForElement("selected Off memory choice", in: try mainWindow(), containing: "Off")

        let finish = try waitForElement(
            "Finish welcome button",
            in: try mainWindow(),
            role: kAXButtonRole as String,
            exactly: "Finish welcome"
        )
        guard finish.isEnabled, finish.press() else {
            throw SmokeError(message: "Finish should enable after the explicit memory choice: \(finish.summary)")
        }
        try waitForElementGone("onboarding sheet", in: try mainWindow(), containing: "Pick your Attaché")
        _ = try waitForElement("voicemail dock button", in: try mainWindow(),
                               role: kAXButtonRole as String, containing: "Open inbox")
    }

    run.step("f10-no-key-first-run", "default character owns a local Ollama model with no paid key") {
        app.activate()
        app.key(Key.comma, command: true)
        try waitUntil("settings window", timeout: 10) { (try? settingsWindow()) != nil }
        try selectSettingsSection("Personalities", paneMarker: "New Attaché")
        _ = try waitForElement("active Attaché character", in: try settingsWindow(), containing: "Attaché", timeout: 8)
        _ = try waitForElement("default local model id", in: try settingsWindow(), containing: "qwen3:7b", timeout: 8)
    }

    run.step("f10-no-key-first-run", "context and memory controls remain usable at the minimum Settings size") {
        let window = try settingsWindow()
        guard window.setSize(CGSize(width: 740, height: 480)) else {
            throw SmokeError(message: "could not resize Settings for context-management narrow-layout verification")
        }
        try selectSettingsSection("Context", paneMarker: "Choose how Attaché balances evidence")
        _ = try waitForElement("default context strategy", in: window, containing: "Default context strategy")
        _ = try waitForElement("automatic context explanation", in: window, containing: "balances evidence and speed automatically")

        try selectSettingsSection("Memory", paneMarker: "Remembering")
        _ = try waitForElement("memory mode", in: window, containing: "Memory mode")
        _ = try waitForElement("local memory privacy explanation", in: window, containing: "Memory stays local by default")
        _ = try waitForElement("structured memory empty state", in: window, containing: "No structured memories yet")
        _ = try waitForElement("memory import action", in: window, role: kAXButtonRole as String, exactly: "Import structured memory")
        _ = try waitForElement("memory export action", in: window, role: kAXButtonRole as String, exactly: "Export structured memory")
    }

    run.step("f10-no-key-first-run", "cloud integration rows are present and no secret account is seeded") {
        try selectSettingsSection("Integrations", paneMarker: "Local agent sources")
        _ = try waitForElement("xAI integration row", in: try settingsWindow(), containing: "xAI / Grok")
        _ = try waitForElement("OpenAI-compatible integration row", in: try settingsWindow(), containing: "OpenAI-compatible")
        _ = try runShell("""
            if defaults read com.bryanlabs.attache attache.configuredSecretAccounts >/dev/null 2>&1; then
              exit 1
            fi
            test ! -s "$HOME/Library/Application Support/Attache/DevelopmentSecrets.json"
            """)
    }

    run.step("f10-no-key-first-run", "local event path still files a playable card") {
        app.key(Key.escape)
        let output = try runShell("scripts/send-event.sh")
        guard output.contains("accepted") else {
            throw SmokeError(message: "server did not accept a no-key event: \(output)")
        }
        app.key(Key.i, command: true)
        _ = try waitForElement("no-key demo card", in: try mainWindow(), containing: "Shell smoke update", timeout: 12)
        app.key(Key.escape)
    }
}

// MARK: Flow 11: macOS app lifecycle relaunch and local server recovery

if enabled("f11") {
    let nonce = ProcessInfo.processInfo.environment["ATTACHE_LIFECYCLE_NONCE"] ?? UUID().uuidString.prefix(8).description
    let firstTitle = "Lifecycle smoke before relaunch \(nonce)"
    let secondTitle = "Lifecycle smoke after relaunch \(nonce)"

    run.step("f11-macos-lifecycle", "fresh launch can be dismissed to idle") {
        try dismissOnboardingIfPresent()
        _ = try waitForElement("settings dock button", in: try mainWindow(),
                               role: kAXButtonRole as String, containing: "Open settings")
    }

    run.step("f11-macos-lifecycle", "event server accepts a card before relaunch") {
        let output = try runShell("EVENT_TITLE='\(firstTitle)' EVENT_TEXT='Attaché lifecycle smoke before relaunch.' EXTERNAL_SESSION_ID='lifecycle-\(nonce)-before' scripts/send-event.sh")
        guard output.contains("accepted") else {
            throw SmokeError(message: "before-relaunch event rejected: \(output)")
        }
        app.key(Key.i, command: true)
        _ = try waitForElement("before-relaunch card", in: try mainWindow(), containing: firstTitle, timeout: 12)
        app.key(Key.escape)
    }

    run.step("f11-macos-lifecycle", "quit and relaunch restores the main window") {
        app.terminateAndWait()
        try app.launch()
        try dismissOnboardingIfPresent()
        _ = try waitForElement("voicemail dock button after relaunch", in: try mainWindow(),
                               role: kAXButtonRole as String, containing: "Open inbox", timeout: 15)
    }

    run.step("f11-macos-lifecycle", "event server accepts a card after relaunch") {
        let output = try runShell("EVENT_TITLE='\(secondTitle)' EVENT_TEXT='Attaché lifecycle smoke after relaunch.' EXTERNAL_SESSION_ID='lifecycle-\(nonce)-after' scripts/send-event.sh")
        guard output.contains("accepted") else {
            throw SmokeError(message: "after-relaunch event rejected: \(output)")
        }
        app.key(Key.i, command: true)
        let field = try waitForElement("inbox search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search inbox",
                                       timeout: 15)
        _ = field.setFocused()
        if !field.setValue(secondTitle) { app.type(secondTitle) }
        _ = try waitForElement("after-relaunch card", in: try mainWindow(), containing: secondTitle, timeout: 12)
        app.key(Key.escape)
    }

    run.step("f11-macos-lifecycle", "settings still opens after relaunch") {
        app.key(Key.comma, command: true)
        try waitUntil("settings window after lifecycle relaunch", timeout: 10) {
            (try? settingsWindow()) != nil
        }
        app.key(Key.escape)
        try waitUntil("settings window to close", timeout: 5) {
            (try? settingsWindow()) == nil
        }
    }
}

// MARK: Flow 12: load with many cards and many indexed Codex sessions

if enabled("f12") {
    let env = ProcessInfo.processInfo.environment
    let nonce = env["ATTACHE_LOAD_SMOKE_NONCE"] ?? ""
    let sessionID = env["ATTACHE_LOAD_SMOKE_TARGET_SESSION_ID"] ?? ""
    let needle = env["ATTACHE_LOAD_SMOKE_NEEDLE"] ?? nonce
    let cardCount = Int(env["ATTACHE_LOAD_SMOKE_CARD_COUNT"] ?? "80") ?? 80
    let lastTitle = "Load smoke card \(nonce) \(String(format: "%03d", cardCount))"

    run.step("f12-load", "environment identifies the load target") {
        guard !nonce.isEmpty else { throw SmokeError(message: "ATTACHE_LOAD_SMOKE_NONCE is required") }
        guard !sessionID.isEmpty else { throw SmokeError(message: "ATTACHE_LOAD_SMOKE_TARGET_SESSION_ID is required") }
        guard !needle.isEmpty else { throw SmokeError(message: "ATTACHE_LOAD_SMOKE_NEEDLE is required") }
    }

    run.step("f12-load", "many local cards can be filed without losing responsiveness") {
        try dismissOnboardingIfPresent()
        let script = """
            for i in $(seq 1 \(cardCount)); do
              n=$(printf "%03d" "$i")
              EVENT_TITLE="Load smoke card \(nonce) $n" \
              EVENT_TEXT="Attaché load smoke card $n for \(nonce). This validates inbox rendering with a larger unread set." \
              EXTERNAL_SESSION_ID="load-card-\(nonce)-$n" \
                scripts/send-event.sh >/dev/null
            done
            echo accepted
            """
        let output = try runShell(script)
        guard output.contains("accepted") else {
            throw SmokeError(message: "load card injection failed: \(output)")
        }
    }

    run.step("f12-load", "inbox search remains responsive with many unread cards") {
        app.activate()
        app.key(Key.i, command: true)
        let field = try waitForElement("inbox search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search inbox",
                                       timeout: 15)
        _ = field.setFocused()
        if !field.setValue(lastTitle) { app.type(lastTitle) }
        _ = try waitForElement("last load card", in: try mainWindow(), containing: lastTitle, timeout: 15)
        app.key(Key.escape)
    }

    run.step("f12-load", "Command-K finds the target Codex session among many indexed sessions") {
        try focusSessionInCommandK(query: needle, sessionID: sessionID, timeout: 90)
        _ = try waitForElement("focused load session saved-call button", in: try mainWindow(),
                               role: kAXButtonRole as String, exactly: "Start saved call", timeout: 15)
        _ = try waitForElement("focused load session status", in: try mainWindow(),
                               containing: "Focused · Load smoke target \(nonce)", timeout: 15)
        guard (try mainWindow()).firstDescendant(containing: "Open send-to-agent composer") == nil else {
            throw SmokeError(message: "legacy off-call send-to-agent dock button is still exposed")
        }
    }
}

// MARK: Flow 13: upgrade candidate sees state created by the prior install

if enabled("f13") {
    let seededTitle = ProcessInfo.processInfo.environment["ATTACHE_UPGRADE_SEEDED_TITLE"] ?? ""

    run.step("f13-upgrade", "environment identifies the pre-upgrade card") {
        guard !seededTitle.isEmpty else {
            throw SmokeError(message: "ATTACHE_UPGRADE_SEEDED_TITLE is required")
        }
    }

    run.step("f13-upgrade", "candidate launches with pre-upgrade card still visible") {
        try dismissOnboardingIfPresent()
        app.activate()
        app.key(Key.i, command: true)
        let field = try waitForElement("inbox search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search inbox",
                                       timeout: 15)
        _ = field.setFocused()
        if !field.setValue(seededTitle) { app.type(seededTitle) }
        _ = try waitForElement("pre-upgrade card", in: try mainWindow(), containing: seededTitle, timeout: 20)
        app.key(Key.escape)
    }

    run.step("f13-upgrade", "candidate keeps persisted settings after replacement") {
        app.key(Key.comma, command: true)
        try waitUntil("settings window", timeout: 10) { (try? settingsWindow()) != nil }
        try selectSettingsSection("Appearance", paneMarker: "Text size")
        let slider = try waitForElement("Text size slider", in: try settingsWindow(),
                                        role: kAXSliderRole as String, containing: "Text size")
        let value = slider.doubleValue ?? 0
        guard Swift.abs(value - 1.2) < 0.04 else {
            throw SmokeError(message: "expected persisted text size near 1.2, got \(value)")
        }
        app.key(Key.escape)
    }
}

// MARK: Flow 6: the palettes share the open-and-type search pattern

if enabled("f6") {
    run.step("f6-palettes", "Command-I inbox palette filters as you type") {
        _ = try runShell("scripts/send-event.sh")
        app.activate()
        let field = try assertWithinLatencyBudget("opening the inbox palette") {
            app.key(Key.i, command: true)
            return try waitForElement("inbox search field", in: try mainWindow(),
                                      role: kAXTextFieldRole as String, containing: "Search inbox")
        }
        _ = field.setFocused()
        if !field.setValue("smoke") { app.type("smoke") }
        _ = try waitForElement("filtered inbox card", in: try mainWindow(), containing: "Shell smoke update")
        app.key(Key.escape)
        try waitForElementGone("inbox search field", in: try mainWindow(),
                               role: kAXTextFieldRole as String, containing: "Search inbox")
    }
    run.step("f6-palettes", "a needs-attention event files a distinct priority notice") {
        let output = try runShell("EVENT_TYPE=needs_attention EVENT_TEXT='Codex is waiting on your answer in Shell smoke update.' scripts/send-event.sh")
        guard output.contains("accepted") else {
            throw SmokeError(message: "needs_attention event rejected: \(output)")
        }
        app.key(Key.i, command: true)
        let field = try waitForElement("inbox search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search inbox")
        _ = field.setFocused()
        if !field.setValue("waiting on your answer") { app.type("waiting on your answer") }
        _ = try waitForElement("needs-you notice row", in: try mainWindow(),
                               containing: "needs decision")
        app.key(Key.escape)
        try waitForElementGone("inbox search field", in: try mainWindow(),
                               role: kAXTextFieldRole as String, containing: "Search inbox", timeout: 5)
    }
    run.step("f6-palettes", "Command-Y history palette opens, filters, closes") {
        app.activate()
        let field = try assertWithinLatencyBudget("opening the history palette") {
            app.key(Key.y, command: true)
            return try waitForElement("history search field", in: try mainWindow(),
                                      role: kAXTextFieldRole as String, containing: "Search history")
        }
        _ = field.setFocused()
        if !field.setValue("zzz-no-match") { app.type("zzz-no-match") }
        _ = try waitForElement("empty-state message", in: try mainWindow(), containing: "No history matches")
        app.key(Key.escape)
        try waitForElementGone("history search field", in: try mainWindow(),
                               role: kAXTextFieldRole as String, containing: "Search history")
    }
}

// MARK: Flow 10: mini attache window (INF-272)

if enabled("mini") {
    run.step("mini-window", "mini attache toggle opens the floating window") {
        app.activate()
        app.key(Key.comma, command: true)
        try waitUntil("settings window", timeout: 10) { (try? settingsWindow()) != nil }
        let toggle = try waitForElement("mini attache toggle", in: try settingsWindow(),
                                        role: kAXCheckBoxRole as String, containing: "Mini window")
        guard toggle.press() else { throw SmokeError(message: "AXPress failed on \(toggle.summary)") }
        try waitUntil("mini attache window to appear", timeout: 10) {
            app.axApp.windows.contains { $0.title.contains("Attaché Mini Window") }
        }
    }
    run.step("mini-window", "mini attache toggle closes it again") {
        let toggle = try waitForElement("mini attache toggle", in: try settingsWindow(),
                                        role: kAXCheckBoxRole as String, containing: "Mini window")
        guard toggle.press() else { throw SmokeError(message: "AXPress failed on \(toggle.summary)") }
        try waitUntil("mini attache window to close", timeout: 10) {
            !app.axApp.windows.contains { $0.title.contains("Attaché Mini Window") }
        }
        app.key(Key.escape)
        try waitUntil("settings window closes", timeout: 10) { (try? settingsWindow()) == nil }
    }
}

// MARK: Flow 5: settings changes persist across relaunch

var chosenTheme = "Cyberpunk"
var chosenTextScale = 1.15
// What the run found before mutating, so the last step can hand the app back
// looking exactly the way the user left it.
var originalTheme = ""
var originalEngine = ""
var originalTextScale = 1.0

if enabled("f5") {
    run.step("f5-settings", "settings overlay opens with Command-comma") {
        try assertWithinLatencyBudget("opening Settings") {
            app.activate()
            app.key(Key.comma, command: true)
            try waitUntil("settings window", timeout: 10) {
                (try? settingsWindow()) != nil
            }
        }
    }
    run.step("f5-settings", "theme switches to a different value") {
        let popup = try waitForElement("Theme picker", in: try settingsWindow(),
                                       role: kAXPopUpButtonRole as String, containing: "Theme")
        originalTheme = popup.stringValue
        chosenTheme = popup.stringValue == "Cyberpunk" ? "Aurora" : "Cyberpunk"
        try selectPopup(popup, item: chosenTheme)
        try waitUntil("theme picker to read \(chosenTheme)", timeout: 5) {
            popup.stringValue.contains(chosenTheme)
        }
    }
    // Voice engine moved into the personality (a personality owns its voice,
    // Personality Manager decision of record), so the engine assertion drives
    // the active character's studio, not a Settings-level control. The old
    // Settings-pane engine radio no longer exists by design; this step had
    // been failing against it since the v0.5.0 voice pane cleanup.
    run.step("f5-settings", "voice engine switches to On-device") {
        try selectSettingsSection("Personalities", paneMarker: "New Attaché")
        let edit = try waitForElement("active character edit button", in: try settingsWindow()) { element in
            element.role == kAXButtonRole as String
                && (element.matches("Edit") || element.matches("Customize"))
        }
        guard edit.press() else { throw SmokeError(message: "AXPress failed on \(edit.summary)") }
        try waitUntil("character studio for engine switch", timeout: 10) {
            (try? personalityStudioWindow()) != nil
        }
        let engineNames = ["On-device", "ElevenLabs", "xAI", "OpenAI"]
        if let selected = (try personalityStudioWindow()).descendants(where: { element in
            element.role == kAXRadioButtonRole as String && element.stringValue == "1"
                && engineNames.contains(where: element.matches)
        }, collectLimit: 1).first {
            originalEngine = engineNames.first(where: selected.matches) ?? ""
        }
        let onDevice = try waitForElement("On-device engine segment", in: try personalityStudioWindow(),
                                          role: kAXRadioButtonRole as String, containing: "On-device")
        guard onDevice.press() else { throw SmokeError(message: "AXPress failed on \(onDevice.summary)") }
        try waitUntil("On-device segment to be selected", timeout: 5) {
            onDevice.stringValue == "1"
        }
        let save = try waitForElement("studio save button", in: try personalityStudioWindow()) { element in
            element.role == kAXButtonRole as String
                && (element.matches("Save changes") || element.matches("Create Attaché"))
        }
        guard save.press() else { throw SmokeError(message: "AXPress failed on \(save.summary)") }
        try waitUntil("character studio closes after engine save", timeout: 10) {
            (try? personalityStudioWindow()) == nil
        }
    }
    run.step("f5-settings", "text size adjusts") {
        try selectSettingsSection("Appearance", paneMarker: "Text size")
        let slider = try waitForElement("Text size slider", in: try settingsWindow(),
                                        role: kAXSliderRole as String, containing: "Text size")
        let before = slider.doubleValue ?? 1.0
        // Walk away from whichever bound is closer so repeated runs never
        // strand the slider at a limit where a fixed direction no-ops.
        originalTextScale = before
        chosenTextScale = before >= 1.25 ? before - 0.15 : before + 0.15
        if !slider.setValue(chosenTextScale) {
            let action = chosenTextScale > before ? kAXIncrementAction : kAXDecrementAction
            for _ in 0..<3 { _ = slider.perform(action) }
        }
        try waitUntil("text size slider to move from \(before)", timeout: 5) {
            abs((slider.doubleValue ?? before) - before) > 0.04
        }
        chosenTextScale = slider.doubleValue ?? chosenTextScale
    }
    run.step("f5-settings", "theme, engine, and text size persist across relaunch") {
        app.terminateAndWait()
        try app.launch()
        app.activate()
        app.key(Key.comma, command: true)
        try waitUntil("settings window after relaunch", timeout: 10) {
            (try? settingsWindow()) != nil
        }
        let popup = try waitForElement("Theme picker", in: try settingsWindow(),
                                       role: kAXPopUpButtonRole as String, containing: "Theme")
        try waitUntil("persisted theme to read \(chosenTheme)", timeout: 5) {
            popup.stringValue.contains(chosenTheme)
        }
        try selectSettingsSection("Personalities", paneMarker: "New Attaché")
        let editAfterRelaunch = try waitForElement(
            "active character edit button after relaunch", in: try settingsWindow()
        ) { element in
            element.role == kAXButtonRole as String
                && (element.matches("Edit") || element.matches("Customize"))
        }
        guard editAfterRelaunch.press() else {
            throw SmokeError(message: "AXPress failed on \(editAfterRelaunch.summary)")
        }
        try waitUntil("character studio after relaunch", timeout: 10) {
            (try? personalityStudioWindow()) != nil
        }
        let onDevice = try waitForElement("On-device engine segment", in: try personalityStudioWindow(),
                                          role: kAXRadioButtonRole as String, containing: "On-device")
        try waitUntil("persisted engine to be On-device", timeout: 5) {
            onDevice.stringValue == "1"
        }
        let cancel = try waitForElement("studio cancel button", in: try personalityStudioWindow(),
                                        role: kAXButtonRole as String, exactly: "Cancel")
        guard cancel.press() else { throw SmokeError(message: "AXPress failed on \(cancel.summary)") }
        try waitUntil("character studio closes after engine check", timeout: 10) {
            (try? personalityStudioWindow()) == nil
        }
        try selectSettingsSection("Appearance", paneMarker: "Text size")
        let slider = try waitForElement("Text size slider", in: try settingsWindow(),
                                        role: kAXSliderRole as String, containing: "Text size")
        try waitUntil("persisted text size to match \(chosenTextScale)", timeout: 5) {
            abs((slider.doubleValue ?? 0) - chosenTextScale) < 0.03
        }
    }
    run.step("f5-settings", "theme, engine, and text size return to what the user had") {
        let slider = try waitForElement("Text size slider", in: try settingsWindow(),
                                        role: kAXSliderRole as String, containing: "Text size")
        if abs((slider.doubleValue ?? originalTextScale) - originalTextScale) > 0.02 {
            if !slider.setValue(originalTextScale) {
                let action = originalTextScale > (slider.doubleValue ?? 0) ? kAXIncrementAction : kAXDecrementAction
                for _ in 0..<3 { _ = slider.perform(action) }
            }
            try waitUntil("text size to return to \(originalTextScale)", timeout: 5) {
                abs((slider.doubleValue ?? 0) - originalTextScale) < 0.03
            }
        }
        let popup = try waitForElement("Theme picker", in: try settingsWindow(),
                                       role: kAXPopUpButtonRole as String, containing: "Theme")
        if !originalTheme.isEmpty, !popup.stringValue.contains(originalTheme) {
            try selectPopup(popup, item: originalTheme)
            try waitUntil("theme to return to \(originalTheme)", timeout: 5) {
                popup.stringValue.contains(originalTheme)
            }
        }
        if !originalEngine.isEmpty, originalEngine != "On-device" {
            try selectSettingsSection("Personalities", paneMarker: "New Attaché")
            let edit = try waitForElement(
                "active character edit button for engine restore", in: try settingsWindow()
            ) { element in
                element.role == kAXButtonRole as String
                    && (element.matches("Edit") || element.matches("Customize"))
            }
            guard edit.press() else { throw SmokeError(message: "AXPress failed on \(edit.summary)") }
            try waitUntil("character studio for engine restore", timeout: 10) {
                (try? personalityStudioWindow()) != nil
            }
            let engine = try waitForElement("original engine segment", in: try personalityStudioWindow(),
                                            role: kAXRadioButtonRole as String, containing: originalEngine)
            guard engine.press() else { throw SmokeError(message: "AXPress failed on \(engine.summary)") }
            try waitUntil("engine to return to \(originalEngine)", timeout: 5) {
                engine.stringValue == "1"
            }
            let save = try waitForElement(
                "studio save button for engine restore", in: try personalityStudioWindow()
            ) { element in
                element.role == kAXButtonRole as String
                    && (element.matches("Save changes") || element.matches("Create Attaché"))
            }
            guard save.press() else { throw SmokeError(message: "AXPress failed on \(save.summary)") }
            try waitUntil("character studio closes after engine restore", timeout: 10) {
                (try? personalityStudioWindow()) == nil
            }
        }
    }
    run.step("f5-settings", "Escape closes the settings overlay") {
        app.key(Key.escape)
        try waitUntil("settings window to close", timeout: 5) {
            (try? settingsWindow()) == nil
        }
    }
}

// The three negative-path flows below (INF-256/E4) share the same Tell Agent
// stage/enable/confirm sequence f14 established (INF-250); the difference is
// what happens to the confirmed instruction afterward. Kept as one helper so
// the three flows don't drift out of sync with f14's proven sequence.
func stageAndConfirmTellAgentInstruction(nonce: String, sessionID: String, prompt: String) throws {
    try dismissOnboardingIfPresent()
    try focusSessionInCommandK(query: nonce, sessionID: sessionID)
    app.key(Key.l, command: true)
    try selectConversationDestination("Tell Agent")
    _ = try waitForElement("visible frozen Tell Agent target", in: try mainWindow(), timeout: 8) { element in
        element.matches("Tell Codex") && element.matches(nonce)
    }
    try sendConversationPrompt(prompt)
    let enable = try waitForElement("Enable send-to-agent button", in: try mainWindow(),
                                    role: kAXButtonRole as String, exactly: "Enable send-to-agent",
                                    timeout: 15)
    guard enable.press() else {
        throw SmokeError(message: "AXPress failed on Enable send-to-agent: \(enable.summary); actions: \(enable.actionNames)")
    }
    let confirm = try waitForElement("Send to agent confirmation button", in: try mainWindow(),
                                     role: kAXButtonRole as String, exactly: "Send to agent",
                                     timeout: 12)
    guard confirm.press() else {
        throw SmokeError(message: "AXPress failed on Send to agent confirmation: \(confirm.summary); actions: \(confirm.actionNames)")
    }
    try waitForElementGone("confirmation sheet", in: try mainWindow(), containing: "Send this to", timeout: 8)
}

func instructionState(sessionID: String) throws -> String {
    let query = "SELECT state FROM instructions WHERE session_id='\(sessionID)' ORDER BY created_at DESC LIMIT 1;"
    let output = try runShell("sqlite3 \"$HOME/Library/Application Support/Attache/Attache.sqlite\" \"\(query)\"")
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: Flow 17: a delivery failure surfaces the stderr tail and fails the
// instruction (INF-256/E4). Uses the same fake Codex CLI as f14 (INF-250),
// this time in ATTACHE_FAKE_CODEX_MODE=exit_code so the resume genuinely
// fails, exercising B1's evidence-based .failed state end to end rather than
// only in a Swift unit test.

if enabled("f18") {
    let env = ProcessInfo.processInfo.environment
    let nonce = env["ATTACHE_TWO_WAY_FAILURE_NONCE"] ?? ""
    let sessionID = env["ATTACHE_TWO_WAY_FAILURE_SESSION_ID"] ?? ""
    let sessionFile = env["ATTACHE_TWO_WAY_FAILURE_SESSION_FILE"] ?? ""
    let instructionToken = env["ATTACHE_TWO_WAY_FAILURE_TOKEN"] ?? (nonce.isEmpty ? "" : "ATTACHE_TWO_WAY_FAILURE_\(nonce)")
    let prompt = env["ATTACHE_TWO_WAY_FAILURE_PROMPT"] ?? "reply exactly \(instructionToken) and do not use tools."
    let stderrTail = env["ATTACHE_TWO_WAY_FAILURE_STDERR"] ?? ""

    run.step("f18-delivery-failure", "environment identifies the disposable Codex session and fake failure text") {
        guard !nonce.isEmpty else { throw SmokeError(message: "ATTACHE_TWO_WAY_FAILURE_NONCE is required") }
        guard !sessionID.isEmpty else { throw SmokeError(message: "ATTACHE_TWO_WAY_FAILURE_SESSION_ID is required") }
        guard !sessionFile.isEmpty else { throw SmokeError(message: "ATTACHE_TWO_WAY_FAILURE_SESSION_FILE is required") }
        guard !stderrTail.isEmpty else { throw SmokeError(message: "ATTACHE_TWO_WAY_FAILURE_STDERR is required") }
        guard FileManager.default.fileExists(atPath: sessionFile) else {
            throw SmokeError(message: "session file does not exist: \(sessionFile)")
        }
    }

    run.step("f18-delivery-failure", "Tell Agent stages and confirms an instruction against the fake failing Codex CLI") {
        try stageAndConfirmTellAgentInstruction(nonce: nonce, sessionID: sessionID, prompt: prompt)
    }

    // Assertion 1: A2/CallStatusPresentation's `.failed` rendering shows the
    // exit-nonzero stderr tail verbatim (InstructionReplyEngine's
    // "Delivery failed: <stderr tail>"), via the same "Conversation status:"
    // AX label f14 checks for the delivered case.
    run.step("f18-delivery-failure", "delivery failure renders the stderr tail in the conversation status") {
        _ = try waitForElement("failed conversation status label", in: try mainWindow(), timeout: 60) { element in
            element.matches("Conversation status:") && element.matches("Delivery failed") && element.matches(stderrTail)
        }
    }

    // Assertion 2: the two-way log's instructions row shows state=failed with
    // the stderr tail recorded as the error, matching E3/f14's precedent for
    // querying SQLite directly.
    run.step("f18-delivery-failure", "two-way log records the failed instruction with the stderr tail") {
        let query = """
        SELECT COUNT(*) FROM instructions \
        WHERE session_id='\(sessionID)' AND state='failed' AND error LIKE '%\(stderrTail)%';
        """
        try waitUntil("failed instruction to land in the instructions table", timeout: 30, interval: 1) {
            guard let output = try? runShell("sqlite3 \"$HOME/Library/Application Support/Attache/Attache.sqlite\" \"\(query)\"") else {
                return false
            }
            return (Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) == 1
        }
    }
}

// MARK: Flow 18: a queued send visibly expires when its target session never
// goes quiet (INF-256/E4, INF-248/B3). The fixture session's transcript is
// kept "active" by a background appender started by the wrapper script, so
// the send can never look idle; ATTACHE_TWO_WAY_EXPIRY_SECONDS (also set by
// the wrapper) makes the 30-minute production window a few seconds instead.

if enabled("f19") {
    let env = ProcessInfo.processInfo.environment
    let nonce = env["ATTACHE_TWO_WAY_EXPIRY_NONCE"] ?? ""
    let sessionID = env["ATTACHE_TWO_WAY_EXPIRY_SESSION_ID"] ?? ""
    let sessionFile = env["ATTACHE_TWO_WAY_EXPIRY_SESSION_FILE"] ?? ""
    let instructionToken = env["ATTACHE_TWO_WAY_EXPIRY_TOKEN"] ?? (nonce.isEmpty ? "" : "ATTACHE_TWO_WAY_EXPIRY_\(nonce)")
    let prompt = env["ATTACHE_TWO_WAY_EXPIRY_PROMPT"] ?? "reply exactly \(instructionToken) and do not use tools."

    run.step("f19-expiry", "environment identifies the disposable, continuously active Codex session") {
        guard !nonce.isEmpty else { throw SmokeError(message: "ATTACHE_TWO_WAY_EXPIRY_NONCE is required") }
        guard !sessionID.isEmpty else { throw SmokeError(message: "ATTACHE_TWO_WAY_EXPIRY_SESSION_ID is required") }
        guard !sessionFile.isEmpty else { throw SmokeError(message: "ATTACHE_TWO_WAY_EXPIRY_SESSION_FILE is required") }
        guard FileManager.default.fileExists(atPath: sessionFile) else {
            throw SmokeError(message: "session file does not exist: \(sessionFile)")
        }
        guard ProcessInfo.processInfo.environment["ATTACHE_TWO_WAY_EXPIRY_SECONDS"] != nil else {
            throw SmokeError(message: "ATTACHE_TWO_WAY_EXPIRY_SECONDS is required for a fast expiry")
        }
    }

    run.step("f19-expiry", "Tell Agent stages and confirms an instruction against the never-quiet session") {
        try stageAndConfirmTellAgentInstruction(nonce: nonce, sessionID: sessionID, prompt: prompt)
    }

    // Assertion 1 (docs/two-way.md, INF-248/B3): the expiry message names the
    // window and the frozen target, rendered via the same "Conversation
    // status:" AX label f14/f17 check.
    run.step("f19-expiry", "the queued send visibly expires with a message naming the window and target") {
        _ = try waitForElement("expired conversation status label", in: try mainWindow(), timeout: 60) { element in
            element.matches("Conversation status:") && element.matches("Send expired after") && element.matches("to go quiet")
        }
    }

    // Assertion 2: the two-way log records the expiry as a failed instruction.
    run.step("f19-expiry", "two-way log records the expired instruction as failed") {
        let query = """
        SELECT COUNT(*) FROM instructions \
        WHERE session_id='\(sessionID)' AND state='failed' AND error LIKE '%expired%';
        """
        try waitUntil("expired instruction to land in the instructions table", timeout: 15, interval: 1) {
            guard let output = try? runShell("sqlite3 \"$HOME/Library/Application Support/Attache/Attache.sqlite\" \"\(query)\"") else {
                return false
            }
            return (Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) == 1
        }
    }
}

// MARK: Flow 19: a restart interrupts an in-flight send and fails it closed
// (INF-256/E4, docs/two-way.md "Restart fails closed"). The fake Codex CLI
// runs in ATTACHE_FAKE_CODEX_MODE=hang so a delivery attempt, if the pump gets
// that far before the kill, can never resolve to delivered/failed on its own.

if enabled("f20") {
    let env = ProcessInfo.processInfo.environment
    let nonce = env["ATTACHE_TWO_WAY_RESTART_NONCE"] ?? ""
    let sessionID = env["ATTACHE_TWO_WAY_RESTART_SESSION_ID"] ?? ""
    let sessionFile = env["ATTACHE_TWO_WAY_RESTART_SESSION_FILE"] ?? ""
    let instructionToken = env["ATTACHE_TWO_WAY_RESTART_TOKEN"] ?? (nonce.isEmpty ? "" : "ATTACHE_TWO_WAY_RESTART_\(nonce)")
    let prompt = env["ATTACHE_TWO_WAY_RESTART_PROMPT"] ?? "reply exactly \(instructionToken) and do not use tools."

    run.step("f20-restart-fails-closed", "environment identifies the disposable Codex session") {
        guard !nonce.isEmpty else { throw SmokeError(message: "ATTACHE_TWO_WAY_RESTART_NONCE is required") }
        guard !sessionID.isEmpty else { throw SmokeError(message: "ATTACHE_TWO_WAY_RESTART_SESSION_ID is required") }
        guard !sessionFile.isEmpty else { throw SmokeError(message: "ATTACHE_TWO_WAY_RESTART_SESSION_FILE is required") }
        guard FileManager.default.fileExists(atPath: sessionFile) else {
            throw SmokeError(message: "session file does not exist: \(sessionFile)")
        }
    }

    // `AppModel.intakeStatus` (which holds the recovery message) only renders
    // inside the Inbox's selected-card status line
    // (Sources/AttacheApp/Views/VoicemailOverlay.swift's cardControlPanel,
    // gated on `model.selectedCard != nil`); a fresh profile with zero cards
    // has nothing to select, so the message would have nowhere to show
    // regardless of whether it survives startup. Seed one unrelated card
    // first so a card exists to select after relaunch, matching realistic
    // usage (a user doing Tell Agent has almost always already received at
    // least one prior update).
    run.step("f20-restart-fails-closed", "a prior card exists so the Inbox has something to select after relaunch") {
        let output = try runShell(
            "EVENT_TITLE='Restart smoke prior card \(nonce)' " +
            "EVENT_TEXT='Attaché restart smoke prior card for \(nonce).' " +
            "EXTERNAL_SESSION_ID='restart-smoke-prior-\(nonce)' scripts/send-event.sh"
        )
        guard output.contains("accepted") else {
            throw SmokeError(message: "prior-card event rejected: \(output)")
        }
    }

    run.step("f20-restart-fails-closed", "Tell Agent stages and confirms an instruction against a hung delivery") {
        try stageAndConfirmTellAgentInstruction(nonce: nonce, sessionID: sessionID, prompt: prompt)
    }

    run.step("f20-restart-fails-closed", "the app is terminated and relaunched while the instruction is still in flight") {
        // Best-effort: give the confirmed instruction a chance to actually
        // reach `delivering` (the fake CLI hangs once it does), but a
        // `confirmed` instruction that was never delivered is an equally
        // valid interrupted state, so this never blocks on reaching a
        // specific one.
        _ = try? waitUntil("instruction to reach delivering", timeout: 20, interval: 1) {
            (try? instructionState(sessionID: sessionID)) == "delivering"
        }
        let state = (try? instructionState(sessionID: sessionID)) ?? ""
        guard state == "confirmed" || state == "delivering" else {
            throw SmokeError(message: "instruction was already terminal (\(state)) before the restart test could kill the app")
        }
        app.terminateAndWait()
        try app.launch()
        try dismissOnboardingIfPresent()
    }

    // Assertion 1 (docs/two-way.md, "Restart fails closed"): the startup
    // recovery message is surfaced in the app's status area on launch, not
    // just the audit row (TwoWayCoordinator.startupRecoveryMessage ->
    // AppModel.intakeStatus, rendered in the selected card's status line in
    // the full voicemail surface, `AttacheRootView.cardControlPanel`).
    // That surface is distinct from the Command-K-style "Open inbox" search
    // palette (`InboxOverlay`) the dock button / Cmd+I opens: reaching
    // `cardControlPanel` requires the palette's own "follow up" action
    // (Cmd+Return, `InboxOverlay.followUpSelection`), which posts
    // `.attacheOpenVoicemailSurface` (`surfaceMode = .voicemail`) for
    // whichever card is selected (the seeded prior card, here, since it is
    // the palette's only entry).
    run.step("f20-restart-fails-closed", "the startup recovery message is visible after relaunch") {
        let button = try waitForElement("voicemail dock button", in: try mainWindow(),
                                        role: kAXButtonRole as String, containing: "Open inbox", timeout: 15)
        guard button.press() else {
            throw SmokeError(message: "AXPress failed on \(button.summary); actions: \(button.actionNames)")
        }
        _ = try waitForElement("prior card in inbox palette", in: try mainWindow(),
                               containing: "Restart smoke prior card \(nonce)", timeout: 15)
        app.key(Key.returnKey, command: true)
        _ = try waitForElement("startup recovery message", in: try mainWindow(),
                               containing: "Review the frozen target and resend", timeout: 15)
        app.key(Key.escape)
    }

    // Assertion 2: the interrupted instruction is marked failed in the
    // two-way log (matching E3/f14's SQLite precedent).
    run.step("f20-restart-fails-closed", "the interrupted instruction is marked failed in the two-way log") {
        let query = """
        SELECT COUNT(*) FROM instructions \
        WHERE session_id='\(sessionID)' AND state='failed' AND error LIKE '%restarted%';
        """
        try waitUntil("interrupted instruction to be marked failed", timeout: 15, interval: 1) {
            guard let output = try? runShell("sqlite3 \"$HOME/Library/Application Support/Attache/Attache.sqlite\" \"\(query)\"") else {
                return false
            }
            return (Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) == 1
        }
    }
}

// MARK: Flow 21: real Claude Code watch plus send-to-agent round trip
// (INF-257/E2). The Claude analog of f7: the same off-call composer, the same
// enable/confirm sequence, and the same transcript + SQLite evidence, but
// against a real, disposable Claude Code session born via `claude -p`
// instead of Codex. Reply correlation is positional (INF-245/B2), so this
// gate also leaves presentation at its default rather than forcing plain
// readback, matching f7's precedent.

if enabled("f21") {
    let env = ProcessInfo.processInfo.environment
    let nonce = env["ATTACHE_CLAUDE_TWO_WAY_NONCE"] ?? ""
    let sessionID = env["ATTACHE_CLAUDE_TWO_WAY_SESSION_ID"] ?? ""
    let sessionFile = env["ATTACHE_CLAUDE_TWO_WAY_SESSION_FILE"] ?? ""
    let pongToken = env["ATTACHE_CLAUDE_TWO_WAY_PONG_TOKEN"] ?? (nonce.isEmpty ? "" : "ATTACHE_PONG_\(nonce)")
    let instruction = env["ATTACHE_CLAUDE_TWO_WAY_INSTRUCTION"] ?? "reply exactly \(pongToken) and do not use tools."
    var focusedSession = false
    var composerOpened = false
    var instructionStaged = false
    var enableConfirmed = false
    var sendConfirmed = false

    run.step("f21-claude-two-way", "environment identifies the disposable Claude Code session") {
        guard !nonce.isEmpty else { throw SmokeError(message: "ATTACHE_CLAUDE_TWO_WAY_NONCE is required") }
        guard !sessionID.isEmpty else { throw SmokeError(message: "ATTACHE_CLAUDE_TWO_WAY_SESSION_ID is required") }
        guard !sessionFile.isEmpty else { throw SmokeError(message: "ATTACHE_CLAUDE_TWO_WAY_SESSION_FILE is required") }
        guard !pongToken.isEmpty else { throw SmokeError(message: "ATTACHE_CLAUDE_TWO_WAY_PONG_TOKEN is required") }
        guard FileManager.default.fileExists(atPath: sessionFile) else {
            throw SmokeError(message: "session file does not exist: \(sessionFile)")
        }
    }

    run.step("f21-claude-two-way", "spawned Claude Code session appears in Command-K search") {
        try focusSessionInCommandK(query: nonce, sessionID: sessionID)
        focusedSession = true
    }

    run.step("f21-claude-two-way", "Tell Agent call composer opens for the focused session") {
        guard focusedSession else { throw SmokeError(message: "skipped: session was not focused") }
        _ = try openAgentCallComposer()
        composerOpened = true
    }

    run.step("f21-claude-two-way", "instruction is entered and staged for send-to-agent") {
        guard composerOpened else { throw SmokeError(message: "skipped: composer did not open") }
        try enterAgentCallInstruction(instruction, mustContain: pongToken)
        try pressAgentInstructionSend()
        instructionStaged = true
    }

    run.step("f21-claude-two-way", "first-use send-to-agent enable sheet confirms") {
        guard instructionStaged else { throw SmokeError(message: "skipped: instruction was not staged") }
        let enable = try waitForElement("Enable send-to-agent button", in: try mainWindow(),
                                        role: kAXButtonRole as String, exactly: "Enable send-to-agent",
                                        timeout: 12)
        guard enable.press() else {
            throw SmokeError(message: "AXPress failed on Enable send-to-agent: \(enable.summary); actions: \(enable.actionNames)")
        }
        _ = try waitForElement("per-instruction confirmation sheet", in: try mainWindow(),
                               containing: pongToken, timeout: 12)
        enableConfirmed = true
    }

    run.step("f21-claude-two-way", "per-instruction confirmation sends to Claude Code") {
        guard enableConfirmed else { throw SmokeError(message: "skipped: send-to-agent was not enabled") }
        let confirm = try waitForElement("Send to agent confirmation button", in: try mainWindow(),
                                         role: kAXButtonRole as String, exactly: "Send to agent",
                                         timeout: 12)
        guard confirm.press() else {
            throw SmokeError(message: "AXPress failed on Send to agent confirmation: \(confirm.summary); actions: \(confirm.actionNames)")
        }
        try waitForElementGone("confirmation sheet", in: try mainWindow(), containing: "Send this to", timeout: 8)
        sendConfirmed = true
    }

    run.step("f21-claude-two-way", "Claude Code transcript records the resumed instruction and pong reply") {
        guard sendConfirmed else { throw SmokeError(message: "skipped: instruction was not sent to Claude Code") }
        try waitForFile(sessionFile, toContain: "resumed Claude Code instruction and pong reply", timeout: 240, interval: 2) { text in
            text.contains("reply exactly \(pongToken)")
                && occurrenceCount(of: pongToken, in: text) >= 2
        }
    }

    run.step("f21-claude-two-way", "Attaché files the Claude Code pong as a watched-session card") {
        var resultingSummary = ""
        try waitUntil("delivered instruction to link its resulting card", timeout: 120, interval: 2) {
            let command = """
            sqlite3 "$HOME/Library/Application Support/Attache/Attache.sqlite" \
              "SELECT c.summary FROM instructions i JOIN cards c ON c.id=i.resulting_card_id WHERE i.session_id='\(sessionID)' AND i.state='delivered' ORDER BY i.created_at DESC LIMIT 1;"
            """
            guard let output = try? runShell(command) else { return false }
            resultingSummary = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return !resultingSummary.isEmpty
        }
        app.activate()
        app.key(Key.i, command: true)
        let field = try waitForElement("inbox search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search inbox",
                                       timeout: 15)
        _ = field.setFocused()
        if !field.setValue(resultingSummary) { app.type(resultingSummary) }
        _ = try waitForInboxCardRow(containing: resultingSummary, timeout: 30)
        app.key(Key.escape)
        try? waitForElementGone("inbox search field", in: try mainWindow(),
                                role: kAXTextFieldRole as String, containing: "Search inbox", timeout: 5)
    }
}


// MARK: Flow 23: real Grok Build two-way round trip (INF-394). The Grok Build
// analog of f7 (Codex) and f21 (Claude Code): a disposable Grok session created
// by scripts/grok-two-way-smoke.sh is resumed through the app's Tell Agent
// pipeline (`grok --resume <id> --output-format json -p`), and the pong reply is
// filed as a watched-session card. Opt-in only (gated by SMOKE_ONLY=f23), so it
// never runs without real Grok Build credentials and a spawned session.
if enabled("f23") {
    let env = ProcessInfo.processInfo.environment
    let nonce = env["ATTACHE_GROK_TWO_WAY_NONCE"] ?? ""
    let sessionID = env["ATTACHE_GROK_TWO_WAY_SESSION_ID"] ?? ""
    let sessionFile = env["ATTACHE_GROK_TWO_WAY_SESSION_FILE"] ?? ""
    let pongToken = env["ATTACHE_GROK_TWO_WAY_PONG_TOKEN"] ?? (nonce.isEmpty ? "" : "ATTACHE_PONG_\(nonce)")
    let instruction = env["ATTACHE_GROK_TWO_WAY_INSTRUCTION"] ?? "reply exactly \(pongToken) and do not use tools."
    var focusedSession = false
    var composerOpened = false
    var instructionStaged = false
    var enableConfirmed = false
    var sendConfirmed = false

    run.step("f23-grok-two-way", "environment identifies the disposable Grok Build session") {
        guard !nonce.isEmpty else { throw SmokeError(message: "ATTACHE_GROK_TWO_WAY_NONCE is required") }
        guard !sessionID.isEmpty else { throw SmokeError(message: "ATTACHE_GROK_TWO_WAY_SESSION_ID is required") }
        guard !sessionFile.isEmpty else { throw SmokeError(message: "ATTACHE_GROK_TWO_WAY_SESSION_FILE is required") }
        guard !pongToken.isEmpty else { throw SmokeError(message: "ATTACHE_GROK_TWO_WAY_PONG_TOKEN is required") }
        guard FileManager.default.fileExists(atPath: sessionFile) else {
            throw SmokeError(message: "session file does not exist: \(sessionFile)")
        }
    }

    run.step("f23-grok-two-way", "spawned Grok Build session appears in Command-K search") {
        try focusSessionInCommandK(query: nonce, sessionID: sessionID)
        focusedSession = true
    }

    run.step("f23-grok-two-way", "Tell Agent call composer opens for the focused session") {
        guard focusedSession else { throw SmokeError(message: "skipped: session was not focused") }
        _ = try openAgentCallComposer()
        composerOpened = true
    }

    run.step("f23-grok-two-way", "instruction is entered and staged for send-to-agent") {
        guard composerOpened else { throw SmokeError(message: "skipped: composer did not open") }
        try enterAgentCallInstruction(instruction, mustContain: pongToken)
        try pressAgentInstructionSend()
        instructionStaged = true
    }

    run.step("f23-grok-two-way", "first-use send-to-agent enable sheet confirms") {
        guard instructionStaged else { throw SmokeError(message: "skipped: instruction was not staged") }
        let enable = try waitForElement("Enable send-to-agent button", in: try mainWindow(),
                                        role: kAXButtonRole as String, exactly: "Enable send-to-agent",
                                        timeout: 12)
        guard enable.press() else {
            throw SmokeError(message: "AXPress failed on Enable send-to-agent: \(enable.summary); actions: \(enable.actionNames)")
        }
        _ = try waitForElement("per-instruction confirmation sheet", in: try mainWindow(),
                               containing: pongToken, timeout: 12)
        enableConfirmed = true
    }

    run.step("f23-grok-two-way", "per-instruction confirmation sends to Grok Build") {
        guard enableConfirmed else { throw SmokeError(message: "skipped: send-to-agent was not enabled") }
        let confirm = try waitForElement("Send to agent confirmation button", in: try mainWindow(),
                                         role: kAXButtonRole as String, exactly: "Send to agent",
                                         timeout: 12)
        guard confirm.press() else {
            throw SmokeError(message: "AXPress failed on Send to agent confirmation: \(confirm.summary); actions: \(confirm.actionNames)")
        }
        try waitForElementGone("confirmation sheet", in: try mainWindow(), containing: "Send this to", timeout: 8)
        sendConfirmed = true
    }

    run.step("f23-grok-two-way", "Grok Build transcript records the resumed instruction and pong reply") {
        guard sendConfirmed else { throw SmokeError(message: "skipped: instruction was not sent to Grok Build") }
        try waitForFile(sessionFile, toContain: "resumed Grok Build instruction and pong reply", timeout: 240, interval: 2) { text in
            text.contains("reply exactly \(pongToken)")
                && occurrenceCount(of: pongToken, in: text) >= 2
        }
    }

    run.step("f23-grok-two-way", "Attaché files the Grok Build pong as a watched-session card") {
        var resultingSummary = ""
        try waitUntil("delivered instruction to link its resulting card", timeout: 120, interval: 2) {
            let command = """
            sqlite3 "$HOME/Library/Application Support/Attache/Attache.sqlite" \
              "SELECT c.summary FROM instructions i JOIN cards c ON c.id=i.resulting_card_id WHERE i.session_id='\(sessionID)' AND i.state='delivered' ORDER BY i.created_at DESC LIMIT 1;"
            """
            guard let output = try? runShell(command) else { return false }
            resultingSummary = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return !resultingSummary.isEmpty
        }
        app.activate()
        app.key(Key.i, command: true)
        let field = try waitForElement("inbox search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search inbox",
                                       timeout: 15)
        _ = field.setFocused()
        if !field.setValue(resultingSummary) { app.type(resultingSummary) }
        _ = try waitForInboxCardRow(containing: resultingSummary, timeout: 30)
        app.key(Key.escape)
        try? waitForElementGone("inbox search field", in: try mainWindow(),
                                role: kAXTextFieldRole as String, containing: "Search inbox", timeout: 5)
    }
}

// MARK: Flow 24: opencode two-way round trip (INF-395)
// The opencode analog of f23 (Grok Build). opencode has no per-session
// transcript file: its sessions are rows in one shared SQLite database, so the
// wrapper (scripts/opencode-two-way-smoke.sh) points XDG_DATA_HOME at a
// disposable data home for both the app and its spawned `opencode run`, and
// this flow verifies delivery/readiness/correlation over that database instead
// of a JSONL file.

if enabled("f24") {
    let env = ProcessInfo.processInfo.environment
    let nonce = env["ATTACHE_OPENCODE_TWO_WAY_NONCE"] ?? ""
    let sessionID = env["ATTACHE_OPENCODE_TWO_WAY_SESSION_ID"] ?? ""
    let databasePath = env["ATTACHE_OPENCODE_TWO_WAY_DB"] ?? ""
    let pongToken = env["ATTACHE_OPENCODE_TWO_WAY_PONG_TOKEN"] ?? (nonce.isEmpty ? "" : "ATTACHE_PONG_\(nonce)")
    let instruction = env["ATTACHE_OPENCODE_TWO_WAY_INSTRUCTION"] ?? "reply exactly \(pongToken) and do not use tools."
    var focusedSession = false
    var composerOpened = false
    var instructionStaged = false
    var enableConfirmed = false
    var sendConfirmed = false

    run.step("f24-opencode-two-way", "environment identifies the disposable opencode session") {
        guard !nonce.isEmpty else { throw SmokeError(message: "ATTACHE_OPENCODE_TWO_WAY_NONCE is required") }
        guard !sessionID.isEmpty else { throw SmokeError(message: "ATTACHE_OPENCODE_TWO_WAY_SESSION_ID is required") }
        guard !databasePath.isEmpty else { throw SmokeError(message: "ATTACHE_OPENCODE_TWO_WAY_DB is required") }
        guard !pongToken.isEmpty else { throw SmokeError(message: "ATTACHE_OPENCODE_TWO_WAY_PONG_TOKEN is required") }
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw SmokeError(message: "opencode database does not exist: \(databasePath)")
        }
    }

    run.step("f24-opencode-two-way", "spawned opencode session appears in Command-K search") {
        try focusSessionInCommandK(query: nonce, sessionID: sessionID)
        focusedSession = true
    }

    run.step("f24-opencode-two-way", "Tell Agent call composer opens for the focused session") {
        guard focusedSession else { throw SmokeError(message: "skipped: session was not focused") }
        _ = try openAgentCallComposer()
        composerOpened = true
    }

    run.step("f24-opencode-two-way", "instruction is entered and staged for send-to-agent") {
        guard composerOpened else { throw SmokeError(message: "skipped: composer did not open") }
        try enterAgentCallInstruction(instruction, mustContain: pongToken)
        try pressAgentInstructionSend()
        instructionStaged = true
    }

    run.step("f24-opencode-two-way", "first-use send-to-agent enable sheet confirms") {
        guard instructionStaged else { throw SmokeError(message: "skipped: instruction was not staged") }
        let enable = try waitForElement("Enable send-to-agent button", in: try mainWindow(),
                                        role: kAXButtonRole as String, exactly: "Enable send-to-agent",
                                        timeout: 12)
        guard enable.press() else {
            throw SmokeError(message: "AXPress failed on Enable send-to-agent: \(enable.summary); actions: \(enable.actionNames)")
        }
        _ = try waitForElement("per-instruction confirmation sheet", in: try mainWindow(),
                               containing: pongToken, timeout: 12)
        enableConfirmed = true
    }

    run.step("f24-opencode-two-way", "per-instruction confirmation sends to opencode") {
        guard enableConfirmed else { throw SmokeError(message: "skipped: send-to-agent was not enabled") }
        let confirm = try waitForElement("Send to agent confirmation button", in: try mainWindow(),
                                         role: kAXButtonRole as String, exactly: "Send to agent",
                                         timeout: 12)
        guard confirm.press() else {
            throw SmokeError(message: "AXPress failed on Send to agent confirmation: \(confirm.summary); actions: \(confirm.actionNames)")
        }
        try waitForElementGone("confirmation sheet", in: try mainWindow(), containing: "Send this to", timeout: 8)
        sendConfirmed = true
    }

    run.step("f24-opencode-two-way", "opencode database records the resumed instruction and pong reply") {
        guard sendConfirmed else { throw SmokeError(message: "skipped: instruction was not sent to opencode") }
        // A completed assistant turn (finish == stop) carrying the pong token
        // must land in the isolated database's rows for this session. IMPORTANT:
        // the whole SQL is passed to `sqlite3` inside a double-quoted bash
        // argument (`sqlite3 "<db>" "<sql>"`), so the SQL itself must contain NO
        // double quotes or the shell string terminates early and sqlite3 gets a
        // mangled query (which `try?` then swallows as a 240s false-poll).
        // `json_extract(...,'$.finish')` matches the assistant `finish` marker
        // with only single quotes; a bare `$.` stays literal inside bash double
        // quotes. String literals use single quotes for the same reason.
        let query = "SELECT COUNT(*) FROM message m JOIN part p ON p.message_id=m.id WHERE m.session_id='\(sessionID)' AND json_extract(m.data,'$.finish')='stop' AND p.data LIKE '%\(pongToken)%';"
        try waitUntil("opencode reply to land in the session database", timeout: 240, interval: 2) {
            guard let output = try? runShell("sqlite3 \"\(databasePath)\" \"\(query)\"") else { return false }
            return (Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) >= 1
        }
    }

    run.step("f24-opencode-two-way", "Attaché files the opencode pong as a watched-session card") {
        var resultingSummary = ""
        try waitUntil("delivered instruction to link its resulting card", timeout: 120, interval: 2) {
            let command = """
            sqlite3 "$HOME/Library/Application Support/Attache/Attache.sqlite" \
              "SELECT c.summary FROM instructions i JOIN cards c ON c.id=i.resulting_card_id WHERE i.session_id='\(sessionID)' AND i.state='delivered' ORDER BY i.created_at DESC LIMIT 1;"
            """
            guard let output = try? runShell(command) else { return false }
            resultingSummary = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return !resultingSummary.isEmpty
        }
        app.activate()
        app.key(Key.i, command: true)
        let field = try waitForElement("inbox search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search inbox",
                                       timeout: 15)
        _ = field.setFocused()
        if !field.setValue(resultingSummary) { app.type(resultingSummary) }
        _ = try waitForInboxCardRow(containing: resultingSummary, timeout: 30)
        app.key(Key.escape)
        try? waitForElementGone("inbox search field", in: try mainWindow(),
                                role: kAXTextFieldRole as String, containing: "Search inbox", timeout: 5)
    }
}


// MARK: Flow 22: opt-in auto-fallback chain transparently continues a live
// call on the next configured/consented provider after a usage-limit failure
// (INF-258/D5), with no manual Switch model click. Two deterministic mock
// providers are used: the primary always returns HTTP 429 (the same
// `ATTACHE_SMOKE_PROVIDER_ERROR=usage_limit` mechanism f16 uses), the
// fallback always succeeds. `attache.conversationFallbackChainEnabled` and
// `attache.conversationFallbackChainProviders` are seeded via `defaults
// write` by the wrapper script (scripts/conversation-recovery-smoke.sh),
// matching how every other seeded preference in these flows is set.

if enabled("f22") {
    let env = ProcessInfo.processInfo.environment
    let prompt = env["ATTACHE_CONVERSATION_FALLBACK_PROMPT"] ?? "ATTACHE_CONVERSATION_FALLBACK"
    let primaryLog = env["ATTACHE_CONVERSATION_FALLBACK_PRIMARY_LOG"] ?? ""
    let fallbackLog = env["ATTACHE_CONVERSATION_FALLBACK_FALLBACK_LOG"] ?? ""

    run.step("f22-conversation-fallback", "environment identifies the two deterministic providers") {
        guard !prompt.isEmpty else { throw SmokeError(message: "ATTACHE_CONVERSATION_FALLBACK_PROMPT is required") }
        guard !primaryLog.isEmpty else { throw SmokeError(message: "ATTACHE_CONVERSATION_FALLBACK_PRIMARY_LOG is required") }
        guard FileManager.default.fileExists(atPath: primaryLog) else {
            throw SmokeError(message: "primary provider log does not exist: \(primaryLog)")
        }
        guard !fallbackLog.isEmpty else { throw SmokeError(message: "ATTACHE_CONVERSATION_FALLBACK_FALLBACK_LOG is required") }
        guard FileManager.default.fileExists(atPath: fallbackLog) else {
            throw SmokeError(message: "fallback provider log does not exist: \(fallbackLog)")
        }
    }

    run.step("f22-conversation-fallback", "a usage-limit failure is announced and transparently retried on the fallback") {
        try dismissOnboardingIfPresent()
        app.key(Key.l, command: true)
        try selectConversationDestination("Ask Attaché")
        let field = try waitForElement("call message field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, exactly: "Call message",
                                       timeout: 20)
        _ = field.setFocused()
        if !field.setValue(prompt) { app.type(prompt) }
        let send = try waitForElement("call send button", in: try mainWindow(),
                                      role: kAXButtonRole as String, exactly: "Send call message",
                                      timeout: 8)
        guard send.press() else {
            throw SmokeError(message: "AXPress failed on call send button: \(send.summary); actions: \(send.actionNames)")
        }

        // Spec item 3: announced in the status line, e.g. "... hit its usage
        // limit; using ... for now." The same "Conversation status:" AX label
        // f16/f18/f19 already read, so this is asserted with the identical
        // mechanism, just a different substring.
        _ = try waitForElement("fallback announcement status", in: try mainWindow(), timeout: 10) { element in
            element.matches("Conversation status:") && element.matches("hit its usage limit; using")
        }

        // No manual recovery affordance should ever appear: the call
        // continues transparently, with no Switch model click needed.
        try waitForElementGone("model recovery menu", in: try mainWindow(),
                               containing: "Switch conversation model", timeout: 3)

        // The retry actually reached the fallback provider (not a second call
        // to the still-failing primary, and not zero calls).
        try waitForFile(fallbackLog, toContain: "a request reaching the fallback provider", timeout: 20, interval: 0.5) { text in
            occurrenceCount(of: "\"event\": \"request\"", in: text) >= 1
        }

        let primaryText = (try? String(contentsOfFile: primaryLog, encoding: .utf8)) ?? ""
        guard occurrenceCount(of: "\"event\": \"request\"", in: primaryText) == 1 else {
            throw SmokeError(message: "expected exactly one request to the primary (failing) provider. Log:\n\(primaryText)")
        }
        let fallbackText = (try? String(contentsOfFile: fallbackLog, encoding: .utf8)) ?? ""
        guard occurrenceCount(of: "\"event\": \"request\"", in: fallbackText) == 1 else {
            throw SmokeError(message: "expected exactly one request to the fallback provider. Log:\n\(fallbackText)")
        }
        guard fallbackText.contains("\"last_user\": \"\(prompt)\"") else {
            throw SmokeError(message: "fallback request did not carry the original prompt. Log:\n\(fallbackText)")
        }
    }
}

// MARK: Personality creator studio. This stays in the default local suite: it
// uses only built-in prompts, the on-device voice, and a disposable profile.

if enabled("personality") {
    run.step("personality-studio", "the personality gallery opens from Settings") {
        try dismissOnboardingIfPresent()
        app.activate()
        app.key(Key.comma, command: true)
        try waitUntil("settings window", timeout: 10) { (try? settingsWindow()) != nil }
        try selectSettingsSection("Personalities", paneMarker: "New Attaché")
        _ = try waitForElement("active personality characters grid", in: try settingsWindow(), containing: "Your personalities")
    }

    run.step("personality-studio", "the creator exposes explicit presence, personality, voice, and model choices") {
        let create = try waitForElement(
            "Create character button",
            in: try settingsWindow(),
            role: kAXButtonRole as String,
            exactly: "New Attaché"
        )
        guard create.press() else { throw SmokeError(message: "AXPress failed on \(create.summary)") }
        try waitUntil("character studio window", timeout: 10) { (try? personalityStudioWindow()) != nil }
        let studio = try personalityStudioWindow()
        _ = try waitForElement("creator title", in: studio, containing: "Create your Attaché")
        _ = try waitForElement("explicit configuration promise", in: studio, containing: "Every Attaché owns its personality, voice, and model")
        _ = try waitForElement("character presence choice", in: studio, containing: "Choose Echo presence")
        _ = try waitForElement("personality prompt", in: studio, containing: "Personality instructions")
        _ = try waitForElement("personality starting point", in: studio, containing: "Starting point")
        _ = try waitForElement("new personality affordance", in: studio, containing: "Write a new personality")
        _ = try waitForElement("voice choice", in: studio, containing: "Attaché voice engine")
        _ = try waitForElement("model choice", in: studio, containing: "Attaché model provider")
        _ = try waitForElement("context strategy choice", in: studio, containing: "Attaché context strategy")
        _ = try waitForElement("sprite help", in: studio, containing: "Learn about custom sprites")
        try waitForElementGone("legacy follow app voice", in: studio, containing: "Follow the app voice", timeout: 1)
        try waitForElementGone("legacy follow app model", in: studio, containing: "Follow the app's main model", timeout: 1)
    }

    run.step("personality-studio", "a fourth custom Echo personality can be authored") {
        let bars = try waitForElement(
            "Echo presence",
            in: try personalityStudioWindow(),
            role: kAXButtonRole as String,
            containing: "Choose Echo presence"
        )
        guard bars.press() else { throw SmokeError(message: "AXPress failed on \(bars.summary)") }

        let newPersonality = try waitForElement(
            "write new personality",
            in: try personalityStudioWindow(),
            role: kAXButtonRole as String,
            containing: "Write a new personality"
        )
        guard newPersonality.press() else { throw SmokeError(message: "AXPress failed on \(newPersonality.summary)") }

        let name = try waitForElement(
            "character name",
            in: try personalityStudioWindow(),
            role: kAXTextFieldRole as String,
            containing: "Attaché name"
        )
        _ = name.setFocused()
        if !name.setValue("Smoke Character") { app.type("Smoke Character") }

        let prompt = try waitForElement(
            "personality instructions",
            in: try personalityStudioWindow(),
            containing: "Personality instructions"
        )
        _ = prompt.setFocused()
        let customPrompt = "Speak like a calm navigator. Lead with the outcome and keep every update to two sentences."
        if !prompt.setValue(customPrompt) { app.type(customPrompt) }

        let contextStrategy = try waitForElement(
            "character context strategy",
            in: try personalityStudioWindow(),
            containing: "Attaché context strategy"
        )
        try selectPopup(contextStrategy, item: "Efficient")

        let save = try waitForElement(
            "creator save button",
            in: try personalityStudioWindow(),
            role: kAXButtonRole as String,
            exactly: "Create Attaché"
        )
        guard save.press() else { throw SmokeError(message: "AXPress failed on \(save.summary)") }
        try waitUntil("character studio closes after save", timeout: 10) { (try? personalityStudioWindow()) == nil }
        _ = try waitForElement("created character", in: try settingsWindow(), containing: "Smoke Character")
        _ = try waitForElement("created Echo presence", in: try settingsWindow(), containing: "Echo voice bars")
    }

    run.step("personality-studio", "the voice picker opens, filters by search, and the row count shrinks") {
        let create = try waitForElement(
            "Create character button",
            in: try settingsWindow(),
            role: kAXButtonRole as String,
            exactly: "New Attaché"
        )
        guard create.press() else { throw SmokeError(message: "AXPress failed on \(create.summary)") }
        try waitUntil("character studio window for voice picker check", timeout: 10) { (try? personalityStudioWindow()) != nil }
        let studio = try personalityStudioWindow()

        let browseVoices = try waitForElement(
            "Browse voices button",
            in: studio,
            role: kAXButtonRole as String,
            containing: "Browse voices"
        )
        guard browseVoices.press() else { throw SmokeError(message: "AXPress failed on \(browseVoices.summary)") }
        try waitUntil("voice picker sheet", timeout: 10) {
            (try? personalityStudioWindow())?.firstDescendant(containing: "Voice picker") != nil
        }

        func rowCount() -> Int {
            (try? personalityStudioWindow())?.descendants(
                where: { $0.matches("Play sample of") },
                collectLimit: 200
            ).count ?? 0
        }
        try waitUntil("voice picker rows to populate", timeout: 5) { rowCount() > 0 }
        let before = rowCount()

        let search = try waitForElement(
            "voice search field",
            in: try personalityStudioWindow(),
            role: kAXTextFieldRole as String,
            containing: "Search voices"
        )
        _ = search.setFocused()
        if !search.setValue("zzz-no-such-voice-xyz") { app.type("zzz-no-such-voice-xyz") }
        try waitUntil("voice picker rows to shrink after search", timeout: 5) {
            rowCount() < before
        }
        let after = rowCount()
        guard after < before else {
            throw SmokeError(message: "voice picker row count did not shrink after search: before=\(before) after=\(after)")
        }

        let done = try waitForElement(
            "voice picker done button",
            in: try personalityStudioWindow(),
            role: kAXButtonRole as String,
            exactly: "Done"
        )
        guard done.press() else { throw SmokeError(message: "AXPress failed on \(done.summary)") }
        try waitUntil("voice picker sheet closes", timeout: 5) {
            (try? personalityStudioWindow())?.firstDescendant(containing: "Voice picker") == nil
        }

        // Discard this scratch draft rather than saving it.
        app.key(Key.escape)
        try waitUntil("character studio closes after voice picker check", timeout: 10) { (try? personalityStudioWindow()) == nil }
    }

    run.step("personality-studio", "a complete personality JSON imports through the app workflow") {
        let importButton = try waitForElement(
            "Import personality button",
            in: try settingsWindow(),
            role: kAXButtonRole as String,
            exactly: "Import"
        )
        guard importButton.press() else { throw SmokeError(message: "AXPress failed on \(importButton.summary)") }
        _ = try waitForElement("imported personality", in: try settingsWindow(), containing: "Imported Navigator")
        _ = try waitForElement("imported personality model", in: try settingsWindow(), containing: "qwen3:7b")
        app.key(Key.escape)
        try waitUntil("settings window closes", timeout: 10) { (try? settingsWindow()) == nil }
    }

    run.step("character-switcher", "the character switcher stays open and supports keyboard navigation") {
        app.key(Key.p, command: true, shift: true)
        _ = try waitForElement("character switcher", in: try mainWindow(), containing: "Attaché switcher")
        _ = try waitForElement(
            "character search",
            in: try mainWindow(),
            role: kAXTextFieldRole as String,
            containing: "Search personalities"
        )

        // The old native popover disappeared with the dock's roughly
        // three-second auto-hide. The app-owned palette must remain available.
        Thread.sleep(forTimeInterval: 3.5)
        // Refresh the window AX element on every poll. SwiftUI can replace the
        // window's accessibility subtree when background activity updates,
        // invalidating a previously captured AX root even though the palette
        // remains visible.
        try waitUntil("persistent character search", timeout: 2) {
            guard let window = try? mainWindow() else { return false }
            return window.firstDescendant(
                role: kAXTextFieldRole as String,
                containing: "Search personalities"
            ) != nil
        }

        app.key(Key.upArrow)
        app.key(Key.returnKey)
        try waitForElementGone("character switcher after arrow selection", in: try mainWindow(), containing: "Attaché switcher", timeout: 5)
    }

    run.step("character-switcher", "the palette opens the personality manager directly") {
        app.key(Key.p, command: true, shift: true)
        let edit = try waitForElement(
            "Edit personalities action",
            in: try mainWindow(),
            role: kAXButtonRole as String,
            exactly: "Edit personalities"
        )
        guard edit.press() else { throw SmokeError(message: "AXPress failed on \(edit.summary)") }
        try waitUntil("settings window from character palette", timeout: 10) { (try? settingsWindow()) != nil }
        _ = try waitForElement("personality manager from palette", in: try settingsWindow(), containing: "Your personalities")
        app.key(Key.escape)
        try waitUntil("settings window closes after palette navigation", timeout: 10) { (try? settingsWindow()) == nil }
    }

    run.step("character-switcher", "typing a character name and pressing Return switches the whole character") {
        app.key(Key.p, command: true, shift: true)
        let search = try waitForElement(
            "character search",
            in: try mainWindow(),
            role: kAXTextFieldRole as String,
            containing: "Search personalities"
        )
        _ = search.setFocused()
        if !search.setValue("Smoke Character") { app.type("Smoke Character") }
        _ = try waitForElement("filtered custom character", in: try mainWindow(), containing: "Attaché Smoke Character")
        _ = try waitForElement("character presence metadata", in: try mainWindow(), containing: "Echo voice bars")
        _ = try waitForElement("character model metadata", in: try mainWindow(), containing: "Ollama")
        app.key(Key.returnKey)
        try waitForElementGone("character switcher after named selection", in: try mainWindow(), containing: "Attaché switcher", timeout: 5)
        _ = try waitForElement("active character in dock", in: try mainWindow(), containing: "Active Attaché Smoke Character")
    }

    // INF-351: character cards used to stack a double-tap (edit) gesture over
    // the single-tap (switch) gesture, so the primary single-click switch
    // always waited out double-click disambiguation. A single AXPress on a
    // non-active card must now flip it to active immediately, with Edit
    // still reachable through the visible ellipsis Menu and the card's
    // context menu (not exercised by AXPress; see PersonalitiesPane.swift).
    run.step("personality-studio", "a single click on a non-active character card switches to it immediately") {
        app.key(Key.comma, command: true)
        try waitUntil("settings window reopens", timeout: 10) { (try? settingsWindow()) != nil }
        try selectSettingsSection("Personalities", paneMarker: "New Attaché")
        // The character-switcher steps above left "Smoke Character" active,
        // so the built-in "Attaché" card is available, not active.
        let card = try waitForElement(
            "non-active Attaché character card",
            in: try settingsWindow(),
            containing: "Attaché, available personality"
        )
        guard card.press() else { throw SmokeError(message: "AXPress failed on \(card.summary)") }
        _ = try waitForElement(
            "activated Attaché character card",
            in: try settingsWindow(),
            containing: "Attaché, active personality"
        )
        app.key(Key.escape)
        try waitUntil("settings window closes after single-click switch", timeout: 10) { (try? settingsWindow()) == nil }
    }
}

// MARK: Flow: dock right-click context menus (INF-354). Settings, Voicemail,
// Call, and Personality each expose a right-click menu; this drives one
// navigation item per menu via AXShowMenu and asserts the destination, the
// same "AX label only, never coordinates" discipline as every other flow.
// Runs by default (not in the opt-in blacklist above): none of these menu
// items need a live backend or extra environment.

if enabled("dock-menus") {
    run.step("dock-menus", "Settings control's right-click menu lists every pane and Personalities navigates there") {
        try dismissOnboardingIfPresent()
        app.activate()
        let settingsButton = try waitForElement("Open settings dock button", in: try mainWindow(),
                                                 role: kAXButtonRole as String, containing: "Open settings")
        let menu = try openContextMenu(settingsButton)
        let titles = contextMenuItemTitles(menu)
        for expected in ["Appearance", "Voice & Captions", "Personalities", "Context", "Integrations", "Memory"] {
            guard titles.contains(where: { $0.contains(expected) }) else {
                throw SmokeError(message: "Settings context menu missing \"\(expected)\"; saw \(titles)")
            }
        }
        try pressContextMenuItem(menu, item: "Personalities")
        try waitUntil("settings window opens to Personalities", timeout: 10) { (try? settingsWindow()) != nil }
        _ = try waitForElement("Personalities pane content", in: try settingsWindow(), containing: "New Attaché")
        app.key(Key.escape)
        try waitUntil("settings window closes", timeout: 10) { (try? settingsWindow()) == nil }
    }

    run.step("dock-menus", "Settings control's Option-held menu adds Open Support Folder") {
        let settingsButton = try waitForElement("Open settings dock button", in: try mainWindow(),
                                                 role: kAXButtonRole as String, containing: "Open settings")
        app.setOptionHeld(true)
        defer { app.setOptionHeld(false) }
        try waitUntil("Option-alternate items become live", timeout: 5) {
            guard let menu = try? openContextMenu(settingsButton) else { return false }
            let live = contextMenuItemTitles(menu).contains(where: { $0.contains("Open Support Folder") })
            app.key(Key.escape)
            return live
        }
    }

    run.step("dock-menus", "Voicemail control's right-click menu lists quick actions and Open Inbox navigates there") {
        let voicemailButton = try waitForElement("voicemail dock button", in: try mainWindow(),
                                                  role: kAXButtonRole as String, containing: "Open inbox")
        let menu = try openContextMenu(voicemailButton)
        let titles = contextMenuItemTitles(menu)
        for expected in ["Play Recap", "Play Latest", "Mark All Read", "Open Inbox"] {
            guard titles.contains(where: { $0.contains(expected) }) else {
                throw SmokeError(message: "Voicemail context menu missing \"\(expected)\"; saw \(titles)")
            }
        }
        try pressContextMenuItem(menu, item: "Open Inbox")
        _ = try waitForElement("inbox search field", in: try mainWindow(),
                               role: kAXTextFieldRole as String, containing: "Search inbox")
        app.key(Key.escape)
    }

    run.step("dock-menus", "Voicemail control's Option-held menu swaps Mark All Read for Archive All") {
        let voicemailButton = try waitForElement("voicemail dock button", in: try mainWindow(),
                                                  role: kAXButtonRole as String, containing: "Open inbox")
        app.setOptionHeld(true)
        defer { app.setOptionHeld(false) }
        try waitUntil("Archive All replaces Mark All Read", timeout: 5) {
            guard let menu = try? openContextMenu(voicemailButton) else { return false }
            let titles = contextMenuItemTitles(menu)
            let swapped = titles.contains(where: { $0.contains("Archive All") })
                && !titles.contains(where: { $0.contains("Mark All Read") })
            app.key(Key.escape)
            return swapped
        }
    }

    run.step("dock-menus", "Call control's right-click menu lists Start Call, Start Private Call, and Call as…") {
        let callButton = try waitForElement("call dock button", in: try mainWindow(),
                                            role: kAXButtonRole as String, containing: "Start saved call")
        let menu = try openContextMenu(callButton)
        let titles = contextMenuItemTitles(menu)
        for expected in ["Start Call", "Start Private Call", "Call as"] {
            guard titles.contains(where: { $0.contains(expected) }) else {
                throw SmokeError(message: "Call context menu missing \"\(expected)\"; saw \(titles)")
            }
        }
        try pressContextMenuItem(menu, item: "Start Call")
        let hangUp = try waitForElement("Hang up control", in: try mainWindow(),
                                        role: kAXButtonRole as String, exactly: "Hang up")
        guard hangUp.press() else { throw SmokeError(message: "AXPress failed on \(hangUp.summary)") }
        try waitForElementGone("Hang up control after ending the call", in: try mainWindow(),
                               role: kAXButtonRole as String, containing: "Hang up", timeout: 10)
    }

    run.step("dock-menus", "Personality control's right-click menu adds Previous/Next Personality and cycles the active character") {
        let personalityButton = try waitForElement("personality dock button", in: try mainWindow(),
                                                    role: kAXButtonRole as String, containing: "Switch Attaché")
        let before = try waitForElement("active character value", in: try mainWindow(), containing: "Active Attaché")
        let beforeText = before.title.isEmpty ? before.axDescription : before.title
        let menu = try openContextMenu(personalityButton)
        let titles = contextMenuItemTitles(menu)
        for expected in ["Switch Attaché", "Edit personalities", "Previous Personality", "Next Personality"] {
            guard titles.contains(where: { $0.contains(expected) }) else {
                throw SmokeError(message: "Personality context menu missing \"\(expected)\"; saw \(titles)")
            }
        }
        try pressContextMenuItem(menu, item: "Next Personality")
        try waitUntil("active character changes after Next Personality", timeout: 5) {
            guard let element = (try? mainWindow())?.firstDescendant(containing: "Active Attaché") else { return false }
            let text = element.title.isEmpty ? element.axDescription : element.title
            return text != beforeText
        }
    }

    run.step("dock-menus", "Personality control's Option-held menu adds Export Personality…") {
        let personalityButton = try waitForElement("personality dock button", in: try mainWindow(),
                                                    role: kAXButtonRole as String, containing: "Switch Attaché")
        app.setOptionHeld(true)
        defer { app.setOptionHeld(false) }
        try waitUntil("Export Personality becomes live", timeout: 5) {
            guard let menu = try? openContextMenu(personalityButton) else { return false }
            let live = contextMenuItemTitles(menu).contains(where: { $0.contains("Export Personality") })
            app.key(Key.escape)
            return live
        }
    }
}

// MARK: Context-management release surface. This flow is opt-in because it
// requires a disposable fake Codex home and ATTACHE_UI_TEST-only state seeded
// by scripts/context-ui-smoke.sh. The production-wiring XCTest remains a
// separate hard assertion, so these deterministic fixtures cannot conceal an
// unwired overflow or exhaustive-review path.

if enabled("context") {
    let environment = ProcessInfo.processInfo.environment
    let discoveryNonce = environment["ATTACHE_CONTEXT_SMOKE_NONCE"] ?? ""
    let discoverySessionID = environment["ATTACHE_CONTEXT_SMOKE_SESSION_ID"] ?? ""

    run.step("context-ui", "fixture and disposable discovery session are explicit") {
        guard environment["ATTACHE_CONTEXT_SMOKE_FIXTURES"] == "1" else {
            throw SmokeError(message: "ATTACHE_CONTEXT_SMOKE_FIXTURES=1 is required")
        }
        guard !discoveryNonce.isEmpty, !discoverySessionID.isEmpty else {
            throw SmokeError(message: "context smoke discovery identifiers are required")
        }
    }

    run.step("context-ui", "session discovery is searchable without granting focus") {
        try dismissOnboardingIfPresent()
        app.key(Key.k, command: true)
        let search = try waitForElement(
            "context session discovery search",
            in: try mainWindow(),
            role: kAXTextFieldRole as String,
            containing: "Search name"
        )
        _ = search.setFocused()
        if !search.setValue(discoveryNonce) { app.type(discoveryNonce) }
        _ = try waitForElement("discovered synthetic session", in: try mainWindow(), timeout: 30) { element in
            element.matches(discoverySessionID)
                && element.actionNames.contains(kAXPressAction as String)
        }
        app.key(Key.escape)
        try waitForElementGone(
            "context discovery search",
            in: try mainWindow(),
            role: kAXTextFieldRole as String,
            containing: "Search name"
        )
    }

    run.step("context-ui", "global strategy and capability controls are keyboard reachable") {
        app.key(Key.comma, command: true)
        try waitUntil("settings window", timeout: 10) { (try? settingsWindow()) != nil }
        try selectSettingsSection("Context", paneMarker: "Choose how Attaché balances evidence")
        let picker = try waitForElement(
            "default context strategy",
            in: try settingsWindow(),
            role: kAXPopUpButtonRole as String,
            exactly: "Default context strategy"
        )
        guard picker.stringValue.contains("Automatic") else {
            throw SmokeError(message: "fresh context strategy is not Automatic: \(picker.summary)")
        }
        let advanced = try waitForElement(
            "advanced context settings",
            in: try settingsWindow(),
            containing: "Advanced context settings"
        )
        guard advanced.press() else {
            throw SmokeError(message: "advanced context disclosure is not actionable: \(advanced.summary)")
        }
        _ = try waitForElement(
            "Automatic strategy plan",
            in: try settingsWindow(),
            containing: "Automatic context strategy plan"
        )
        _ = try waitForElement(
            "Automatic evidence allowance",
            in: try settingsWindow(),
            containing: "75% of capacity remaining after reserves"
        )
        guard advanced.press() else {
            throw SmokeError(message: "could not collapse advanced context settings: \(advanced.summary)")
        }

        let updatedPicker = try waitForElement(
            "updated default context strategy",
            in: try settingsWindow(),
            role: kAXPopUpButtonRole as String,
            exactly: "Default context strategy"
        )
        try selectPopup(updatedPicker, item: "Efficient")
        try waitUntil("Efficient context strategy selection", timeout: 5) {
            updatedPicker.stringValue.contains("Efficient")
        }
        let updatedAdvanced = try waitForElement(
            "updated advanced context settings",
            in: try settingsWindow(),
            containing: "Advanced context settings"
        )
        guard updatedAdvanced.press() else {
            throw SmokeError(message: "could not reopen advanced context settings: \(updatedAdvanced.summary)")
        }
        _ = try waitForElement(
            "Efficient strategy plan",
            in: try settingsWindow(),
            containing: "Efficient context strategy plan"
        )
        _ = try waitForElement(
            "Efficient evidence allowance",
            in: try settingsWindow(),
            containing: "50% of capacity remaining after reserves"
        )
        _ = try waitForElement(
            "context capability summary",
            in: try settingsWindow(),
            containing: "Context capability summary"
        )
        _ = try waitForElement(
            "strategy-independent model evidence",
            in: try settingsWindow(),
            containing: "Independent of strategy"
        )
    }

    run.step("context-ui", "memory review, correction, privacy, and deletion controls are labeled") {
        try selectSettingsSection("Memory", paneMarker: "Remembering")
        let window = try settingsWindow()
        _ = try waitForElement("memory mode", in: window, containing: "Memory mode")
        _ = try waitForElement("memory privacy promise", in: window, containing: "Memory stays local by default")
        _ = try waitForElement("pending memory", in: window, containing: "Pending Standing instruction memory")
        _ = try waitForElement("edit pending memory", in: window, exactly: "Edit suggested memory")
        _ = try waitForElement("save pending memory", in: window, role: kAXButtonRole as String, exactly: "Save suggested memory")
        _ = try waitForElement("dismiss pending memory", in: window, role: kAXButtonRole as String, exactly: "Dismiss suggested memory")
        _ = try waitForElement("never remember type", in: window, role: kAXButtonRole as String, containing: "Never suggest Standing instruction memories")
        _ = try waitForElement("saved memory", in: window, containing: "Saved Preference memory")
        _ = try waitForElement("forget saved memory", in: window, role: kAXButtonRole as String, exactly: "Forget saved memory")
        _ = try waitForElement("import structured memory", in: window, role: kAXButtonRole as String, exactly: "Import structured memory")
        _ = try waitForElement("export structured memory", in: window, role: kAXButtonRole as String, exactly: "Export structured memory")
        _ = try waitForElement("delete all structured memory", in: window, role: kAXButtonRole as String, exactly: "Delete all structured memory")
        app.key(Key.escape)
        try waitUntil("settings window closes", timeout: 8) { (try? settingsWindow()) == nil }
    }

    run.step("context-ui", "persisted fallback receipt expands to redacted details") {
        app.key(Key.y, command: true)
        let search = try waitForElement(
            "history search field",
            in: try mainWindow(),
            role: kAXTextFieldRole as String,
            containing: "Search history"
        )
        _ = search.setFocused()
        if !search.setValue("Context smoke receipt") { app.type("Context smoke receipt") }
        _ = try waitForElement("context receipt card", in: try mainWindow(), containing: "Context smoke receipt")
        let receipt = try waitForElement(
            "context receipt disclosure",
            in: try mainWindow(),
            exactly: "Show context receipt"
        )
        guard receipt.press() else {
            throw SmokeError(message: "context receipt disclosure is not actionable: \(receipt.summary)")
        }
        _ = try waitForElement("fallback receipt details", in: try mainWindow(), containing: "Fallback attempt 2")
        _ = try waitForElement(
            "redacted diagnostic action",
            in: try mainWindow(),
            role: kAXButtonRole as String,
            exactly: "Copy redacted context diagnostic"
        )
        // The first Escape belongs to the receipt popover; the second closes
        // History itself. Pressing only once made this assertion dependent on
        // whichever SwiftUI surface won Escape dispatch.
        app.key(Key.escape)
        app.key(Key.escape)
        try waitForElementGone(
            "history search field",
            in: try mainWindow(),
            role: kAXTextFieldRole as String,
            containing: "Search history"
        )
    }

    run.step("context-ui", "overflow recovery preserves explicit retry choices") {
        app.key(Key.l, command: true)
        _ = try waitForElement("context-free boundary", in: try mainWindow(), containing: "No work session context")
        _ = try waitForElement(
            "context overflow recovery",
            in: try mainWindow(),
            exactly: "Context limit reached. Your message is preserved and has not been retried."
        )
        _ = try waitForElement(
            "automatic context retry",
            in: try mainWindow(),
            role: kAXButtonRole as String,
            exactly: "Retry preserved message with Automatic context"
        )
        _ = try waitForElement(
            "efficient context retry",
            in: try mainWindow(),
            role: kAXButtonRole as String,
            exactly: "Retry preserved message with Efficient context"
        )
        _ = try waitForElement(
            "dismiss overflow recovery",
            in: try mainWindow(),
            role: kAXButtonRole as String,
            exactly: "Dismiss context overflow recovery"
        )
    }

    run.step("context-ui", "exhaustive review preview, cancel, and resume controls are reachable") {
        _ = try waitForElement(
            "exhaustive review preview",
            in: try mainWindow(),
            containing: "Exhaustive review for Synthetic context smoke session"
        )
        let start = try waitForElement(
            "start exhaustive review",
            in: try mainWindow(),
            role: kAXButtonRole as String,
            exactly: "Start exhaustive review"
        )
        guard start.press() else { throw SmokeError(message: "Start exhaustive review is not actionable") }
        let cancel = try waitForElement(
            "cancel exhaustive review",
            in: try mainWindow(),
            role: kAXButtonRole as String,
            exactly: "Cancel exhaustive review"
        )
        guard cancel.press() else { throw SmokeError(message: "Cancel exhaustive review is not actionable") }
        _ = try waitForElement(
            "resume exhaustive review",
            in: try mainWindow(),
            role: kAXButtonRole as String,
            exactly: "Resume exhaustive review"
        )
        let hangUp = try waitForElement(
            "hang up context smoke call",
            in: try mainWindow(),
            role: kAXButtonRole as String,
            containing: "Hang up"
        )
        _ = hangUp.press()
    }
}

app.terminateAndWait()
exit(Int32(run.summarize()))
