import AppKit
import ApplicationServices

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
    return !["f7", "f8", "f9", "f10", "f11", "f12", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20", "f21", "f22"].contains(key)
}

let app = AppUnderTest(appURL: URL(fileURLWithPath: appPath))
let run = SmokeRun()

func mainWindow() throws -> AXElement {
    guard let window = app.appWindows.first(where: { !$0.title.contains("Settings") }) ?? app.appWindows.first else {
        throw SmokeError(message: "app has no windows")
    }
    return window
}

func settingsWindow() throws -> AXElement {
    guard let window = app.appWindows.first(where: { $0.title.contains("Settings") }) else {
        let titles = app.appWindows.map { "\"\($0.title)\"" }.joined(separator: ", ")
        throw SmokeError(message: "no settings window found; open windows: [\(titles)]")
    }
    return window
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

/// Selects a settings sidebar section by title. SwiftUI outline rows expose
/// their label text in a nested cell, so the row is found by searching each
/// row's subtree, then selected; the pane switch is asserted via a marker
/// string unique to the target pane.
func selectSettingsSection(_ title: String, paneMarker: String) throws {
    let window = try settingsWindow()
    var row: AXElement?
    try waitUntil("sidebar row \"\(title)\"", timeout: 10) {
        let rows = window.descendants(where: { $0.role == "AXRow" })
        row = rows.first { $0.firstDescendant(containing: title) != nil }
        return row != nil
    }
    guard let row else {
        throw SmokeError(message: "sidebar row \"\(title)\" not found. AX tree:\n\(window.treeDump())")
    }
    if !row.setSelected(true) {
        _ = row.press()
    }
    _ = try waitForElement("\(title) pane content", in: try settingsWindow(), containing: paneMarker)
}

/// Opens the Model pane and expands the "Advanced: per-task models" disclosure
/// if it is collapsed (INF-253/D3). The disclosure's expanded state is
/// view-local, so navigating to another settings section and back collapses
/// it again; call this every time the row controls are needed. Returns the
/// Recap row's provider picker once expansion is confirmed.
@discardableResult
func expandAdvancedPerRoleModels() throws -> AXElement {
    try selectSettingsSection("Model", paneMarker: "Provider")
    let window = try settingsWindow()
    if let recapProvider = window.firstDescendant(role: kAXPopUpButtonRole as String, containing: "Recap provider") {
        return recapProvider
    }
    let disclosure = try waitForElement("Advanced per-task models disclosure", in: try settingsWindow(),
                                        containing: "Advanced: per-task models")
    guard disclosure.press() else {
        throw SmokeError(message: "AXPress failed on \(disclosure.summary); actions: \(disclosure.actionNames)")
    }
    return try waitForElement("Recap provider picker", in: try settingsWindow(),
                              role: kAXPopUpButtonRole as String, containing: "Recap provider", timeout: 8)
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

func openLiveInstructionComposer() throws -> AXElement {
    let open = try waitForElement("send composer dock button", in: try mainWindow(),
                                  role: kAXButtonRole as String, containing: "Open send-to-agent composer",
                                  timeout: 20)
    _ = open.press()
    return try waitForElement("live session instruction editor", in: try mainWindow(),
                              containing: "Live session instruction", timeout: 10)
}

func enterLiveInstruction(_ instruction: String, mustContain token: String? = nil) throws {
    let editor = try waitForElement("live session instruction editor", in: try mainWindow(),
                                    containing: "Live session instruction", timeout: 10)
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

// Pose mode: launch the app, arrange a named state, and hold it on screen so a
// human or screenshot tool can capture it. SMOKE_POSE=inbox|settings|live
// (comma-separated applies in order), SMOKE_TEXTSCALE=1.3 to set text size,
// SMOKE_POSE_SECONDS to change the hold time.
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
                try settingsWindow().descendants(where: { $0.subrole == "AXCloseButton" }, collectLimit: 1)
                    .first.map { _ = $0.press() }
            }
        }
        for state in pose.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch state {
            case "inbox":
                let button = try waitForElement("voicemail dock button", in: try mainWindow(),
                                                role: kAXButtonRole as String, containing: "Open inbox")
                _ = button.press()
            case "settings":
                app.activate()
                app.key(Key.comma, command: true)
                try waitUntil("settings window", timeout: 10) { (try? settingsWindow()) != nil }
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
            default:
                print("unknown pose state: \(state)")
            }
        }
        print("posing \(pose) for \(Int(holdSeconds))s")
        Thread.sleep(forTimeInterval: holdSeconds)
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

    run.step("f7-codex-two-way", "live send composer opens for the focused session") {
        guard focusedSession else { throw SmokeError(message: "skipped: session was not focused") }
        let open = try waitForElement("send composer dock button", in: try mainWindow(),
                                      role: kAXButtonRole as String, containing: "Open send-to-agent composer",
                                      timeout: 20)
        _ = open.press()
        _ = try waitForElement("live session instruction editor", in: try mainWindow(),
                               containing: "Live session instruction", timeout: 10)
        composerOpened = true
    }

    run.step("f7-codex-two-way", "instruction is entered and staged for send-to-agent") {
        guard composerOpened else { throw SmokeError(message: "skipped: composer did not open") }
        let editor = try waitForElement("live session instruction editor", in: try mainWindow(),
                                        containing: "Live session instruction", timeout: 10)
        _ = editor.setFocused()
        if !editor.setValue(instruction) { app.type(instruction) }
        try waitUntil("instruction text to land in the live composer", timeout: 8, interval: 0.5) {
            if editor.stringValue.contains(pongToken) { return true }
            _ = editor.setFocused()
            if !editor.setValue(instruction) { app.type(instruction) }
            return editor.stringValue.contains(pongToken)
        }
        try waitUntil("Send to Agent button to enable", timeout: 8, interval: 0.5) {
            (try? mainWindow())?
                .firstDescendant(role: kAXButtonRole as String, exactly: "Send to Agent")?
                .isEnabled == true
        }
        let send = try waitForElement("Send to Agent button", in: try mainWindow(),
                                      role: kAXButtonRole as String, exactly: "Send to Agent")
        guard send.press() else {
            throw SmokeError(message: "AXPress failed on Send to Agent: \(send.summary); actions: \(send.actionNames)")
        }
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

    run.step("f8-personality-codex-two-way", "enabled Ask Attaché handoff sends directly without a final sheet") {
        try sendConversationPrompt(directPrompt)
        Thread.sleep(forTimeInterval: 2)
        let confirmation = (try mainWindow()).firstDescendant(containing: "Send this to")
        guard confirmation == nil else {
            throw SmokeError(message: "direct personality handoff unexpectedly opened a final confirmation sheet")
        }
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

    run.step("f9-two-way-safety", "send-to-agent composer opens for the safety session") {
        guard sessionFocused else { throw SmokeError(message: "skipped: session was not focused") }
        _ = try openLiveInstructionComposer()
        composerOpened = true
    }

    run.step("f9-two-way-safety", "first-use enable sheet can be confirmed without sending") {
        guard composerOpened else { throw SmokeError(message: "skipped: composer did not open") }
        try enterLiveInstruction("first real instruction for enable gate")
        let send = try waitForElement("Send to Agent button", in: try mainWindow(),
                                      role: kAXButtonRole as String, exactly: "Send to Agent")
        guard send.press() else {
            throw SmokeError(message: "AXPress failed on Send to Agent: \(send.summary); actions: \(send.actionNames)")
        }
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
        try enterLiveInstruction(rejectedInstruction)
        let send = try waitForElement("Send to Agent button", in: try mainWindow(),
                                      role: kAXButtonRole as String, exactly: "Send to Agent")
        guard send.press() else {
            throw SmokeError(message: "AXPress failed on Send to Agent: \(send.summary); actions: \(send.actionNames)")
        }
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

    run.step("f10-no-key-first-run", "skip path reaches the idle dock") {
        try dismissOnboardingIfPresent()
        _ = try waitForElement("voicemail dock button", in: try mainWindow(),
                               role: kAXButtonRole as String, containing: "Open inbox")
    }

    run.step("f10-no-key-first-run", "default personality model is local Ollama with no paid key") {
        app.activate()
        app.key(Key.comma, command: true)
        try waitUntil("settings window", timeout: 10) { (try? settingsWindow()) != nil }
        try selectSettingsSection("Model", paneMarker: "Provider")
        _ = try waitForElement("Ollama provider", in: try settingsWindow(), containing: "Ollama", timeout: 8)
        _ = try waitForElement("local data residency caption", in: try settingsWindow(),
                               containing: "Local provider: nothing leaves this Mac", timeout: 8)
        _ = try waitForElement("default local model id", in: try settingsWindow(), containing: "qwen3:7b", timeout: 8)
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
        _ = try waitForElement("focused load session send button", in: try mainWindow(),
                               role: kAXButtonRole as String, containing: "Open send-to-agent composer",
                               timeout: 15)
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
        app.key(Key.i, command: true)
        let field = try waitForElement("inbox search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search inbox")
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
        app.key(Key.y, command: true)
        let field = try waitForElement("history search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search history")
        _ = field.setFocused()
        if !field.setValue("zzz-no-match") { app.type("zzz-no-match") }
        _ = try waitForElement("empty-state message", in: try mainWindow(), containing: "No history matches")
        app.key(Key.escape)
        try waitForElementGone("history search field", in: try mainWindow(),
                               role: kAXTextFieldRole as String, containing: "Search history")
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
    run.step("f5-settings", "settings window opens with Command-comma") {
        app.activate()
        app.key(Key.comma, command: true)
        try waitUntil("settings window", timeout: 10) {
            (try? settingsWindow()) != nil
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
    run.step("f5-settings", "voice engine switches to On-device") {
        try selectSettingsSection("Voice & Captions", paneMarker: "Voice engine")
        let engineNames = ["On-device", "ElevenLabs", "xAI", "OpenAI"]
        if let selected = (try settingsWindow()).descendants(where: { element in
            element.role == kAXRadioButtonRole as String && element.stringValue == "1"
                && engineNames.contains(where: element.matches)
        }, collectLimit: 1).first {
            originalEngine = engineNames.first(where: selected.matches) ?? ""
        }
        let onDevice = try waitForElement("On-device engine segment", in: try settingsWindow(),
                                          role: kAXRadioButtonRole as String, containing: "On-device")
        guard onDevice.press() else { throw SmokeError(message: "AXPress failed on \(onDevice.summary)") }
        try waitUntil("On-device segment to be selected", timeout: 5) {
            onDevice.stringValue == "1"
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
    run.step("f5-settings", "recap model override switches to LM Studio") {
        let recapProvider = try expandAdvancedPerRoleModels()
        guard recapProvider.stringValue.contains("Use main model") else {
            throw SmokeError(message: "expected recap provider to start on \"Use main model\", found \"\(recapProvider.stringValue)\"")
        }
        try selectPopup(recapProvider, item: "LM Studio")
        try waitUntil("recap provider to read LM Studio", timeout: 5) {
            recapProvider.stringValue.contains("LM Studio")
        }
        // A per-role override reveals that role's own Model row once a real
        // provider (not "Use main model") is chosen (INF-253/D3).
        _ = try waitForElement("Recap model control", in: try settingsWindow(), containing: "Recap model")
    }
    run.step("f5-settings", "an un-keyed provider on a role shows the existing key-required state without crashing") {
        // Conversation is the first Advanced row, so its on-screen position
        // never shifts regardless of whether a later row (recap, just set to
        // LM Studio above) has grown taller with its own Model/Reasoning/Speed
        // controls. Groq requires an API key and is not configured in this
        // profile; picking it for conversation must show the same
        // key-required notice the main picker already uses, not crash
        // (INF-253/D3 spec item 5).
        _ = try expandAdvancedPerRoleModels()
        let conversationProvider = try waitForElement("Conversation provider picker", in: try settingsWindow(),
                                                       role: kAXPopUpButtonRole as String, containing: "Conversation provider")
        // selectPopup's menu-item wait is a fixed 5s; under shared-machine
        // load the popup's menu can occasionally take longer to attach, so
        // retry once rather than fail the whole step on a single slow open.
        do {
            try selectPopup(conversationProvider, item: "Groq")
        } catch {
            try selectPopup(conversationProvider, item: "Groq")
        }
        // Groq also sends data to the cloud, so unless this profile already
        // consented, the shared CloudConsentSheet (same one the main picker
        // uses) appears before the selection applies; enable it to reach the
        // un-keyed state this step is actually testing.
        if let enable = (try? waitForElement("cloud consent Enable button", in: try settingsWindow(),
                                             role: kAXButtonRole as String, exactly: "Enable", timeout: 3)) {
            guard enable.press() else {
                throw SmokeError(message: "AXPress failed on cloud consent Enable button: \(enable.summary)")
            }
        }
        try waitUntil("conversation provider to read Groq", timeout: 5) {
            conversationProvider.stringValue.contains("Groq")
        }
        _ = try waitForElement("Groq key-required notice", in: try settingsWindow(), containing: "needs an", timeout: 5)
        // Rendered as a link-style button (`.buttonStyle(.link)`), so it's an
        // AXLink, not an AXButton; match on text only.
        _ = try waitForElement("key-required Integrations link", in: try settingsWindow(),
                               exactly: "API key", timeout: 5)
        guard (try? settingsWindow()) != nil else {
            throw SmokeError(message: "settings window disappeared after selecting an un-keyed provider")
        }
        // Clean up so this role doesn't leave stray state for the rest of the suite.
        try selectPopup(conversationProvider, item: "Use main model")
        try waitUntil("conversation provider to read Use main model again", timeout: 5) {
            conversationProvider.stringValue.contains("Use main model")
        }
    }
    run.step("f5-settings", "theme, engine, and recap model override persist across relaunch") {
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
        try selectSettingsSection("Voice & Captions", paneMarker: "Voice engine")
        let onDevice = try waitForElement("On-device engine segment", in: try settingsWindow(),
                                          role: kAXRadioButtonRole as String, containing: "On-device")
        try waitUntil("persisted engine to be On-device", timeout: 5) {
            onDevice.stringValue == "1"
        }
        try selectSettingsSection("Appearance", paneMarker: "Text size")
        let slider = try waitForElement("Text size slider", in: try settingsWindow(),
                                        role: kAXSliderRole as String, containing: "Text size")
        try waitUntil("persisted text size to match \(chosenTextScale)", timeout: 5) {
            abs((slider.doubleValue ?? 0) - chosenTextScale) < 0.03
        }
        let recapProvider = try expandAdvancedPerRoleModels()
        try waitUntil("persisted recap provider to read LM Studio", timeout: 5) {
            recapProvider.stringValue.contains("LM Studio")
        }
        let defaultsOutput = try runShell("defaults read com.bryanlabs.attache attache.presentationLLM.recap.provider")
        guard defaultsOutput.contains("lmStudio") else {
            throw SmokeError(message: "expected persisted recap provider default to be lmStudio, found: \(defaultsOutput)")
        }
    }
    run.step("f5-settings", "recap model override resets to Use main model and clears the per-role key") {
        let recapProvider = try expandAdvancedPerRoleModels()
        try selectPopup(recapProvider, item: "Use main model")
        try waitUntil("recap provider to read Use main model", timeout: 5) {
            recapProvider.stringValue.contains("Use main model")
        }
        // The role's Model row only shows while an override is set; resetting
        // to "Use main model" must hide it again, not leave it dangling.
        try waitForElementGone("Recap model control", in: try settingsWindow(), containing: "Recap model", timeout: 5)
        _ = try runShell("""
            for field in provider model reasoningEffort serviceTier; do
              if defaults read com.bryanlabs.attache "attache.presentationLLM.recap.$field" >/dev/null 2>&1; then
                echo "recap.$field key still present after reset" >&2
                exit 1
              fi
            done
            """)
        // Fallback restored, not just a coincidentally-matching leftover: with
        // every recap.* key gone, `CompanionPresentationSettings.load(role:
        // .recap, ...)` re-resolves purely from the main/global keys (see
        // PerRoleModelPaneTests.testResettingToUseMainModelClearsEveryRoleKeyAndRestoresFallback,
        // which changes the global provider *between* setting and clearing
        // the override to rule out a stale coincidental match). Here in the
        // UI we confirm the main row itself still reads normally, i.e.
        // clearing recap's override left the main model control unaffected.
        let mainProvider = try waitForElement("Main model provider picker", in: try settingsWindow(),
                                              role: kAXPopUpButtonRole as String, containing: "Main model provider")
        guard !mainProvider.stringValue.isEmpty else {
            throw SmokeError(message: "could not read the main provider value after clearing recap's override")
        }
        // The next step assumes it's still looking at Appearance's Text size
        // slider (that's where the pre-existing relaunch step left it); hand
        // settings back on that section since this step navigated to Model.
        try selectSettingsSection("Appearance", paneMarker: "Text size")
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
            try selectSettingsSection("Voice & Captions", paneMarker: "Voice engine")
            let engine = try waitForElement("original engine segment", in: try settingsWindow(),
                                            role: kAXRadioButtonRole as String, containing: originalEngine)
            guard engine.press() else { throw SmokeError(message: "AXPress failed on \(engine.summary)") }
            try waitUntil("engine to return to \(originalEngine)", timeout: 5) {
                engine.stringValue == "1"
            }
        }
    }
    run.step("f5-settings", "Escape closes the settings window") {
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
    // the full voicemail surface, `CompanionRootView.cardControlPanel`).
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

    run.step("f21-claude-two-way", "live send composer opens for the focused session") {
        guard focusedSession else { throw SmokeError(message: "skipped: session was not focused") }
        _ = try openLiveInstructionComposer()
        composerOpened = true
    }

    run.step("f21-claude-two-way", "instruction is entered and staged for send-to-agent") {
        guard composerOpened else { throw SmokeError(message: "skipped: composer did not open") }
        try enterLiveInstruction(instruction, mustContain: pongToken)
        try waitUntil("Send to Agent button to enable", timeout: 8, interval: 0.5) {
            (try? mainWindow())?
                .firstDescendant(role: kAXButtonRole as String, exactly: "Send to Agent")?
                .isEnabled == true
        }
        let send = try waitForElement("Send to Agent button", in: try mainWindow(),
                                      role: kAXButtonRole as String, exactly: "Send to Agent")
        guard send.press() else {
            throw SmokeError(message: "AXPress failed on Send to Agent: \(send.summary); actions: \(send.actionNames)")
        }
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

app.terminateAndWait()
exit(Int32(run.summarize()))
