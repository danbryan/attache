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
    onlyFlows?.contains(flow.lowercased()) ?? true
}

let app = AppUnderTest(appURL: URL(fileURLWithPath: appPath))
let run = SmokeRun()

func mainWindow() throws -> AXElement {
    guard let window = app.axApp.windows.first(where: { !$0.title.contains("Settings") }) ?? app.axApp.windows.first else {
        throw SmokeError(message: "app has no windows")
    }
    return window
}

func settingsWindow() throws -> AXElement {
    guard let window = app.axApp.windows.first(where: { $0.title.contains("Settings") }) else {
        let titles = app.axApp.windows.map { "\"\($0.title)\"" }.joined(separator: ", ")
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
        let output = try runShell("scripts/send-event.sh")
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
        _ = try waitForElement("demo card in inbox", in: try mainWindow(), containing: "Shell smoke update")
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
                                     containing: "Play Shell smoke update")
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
    run.step("f3-transport", "captions are visible during playback") {
        // The caption layer and the speaking indicator are one AX element; the
        // caption text is exposed as its value.
        let layer = try waitForElement("caption layer", in: try mainWindow(), containing: "speaking")
        try waitUntil("caption layer to carry the spoken text", timeout: 5) {
            layer.stringValue.count > 10
        }
    }
}

// MARK: Flow 4: Command-K search opens, filters, and closes

if enabled("f4") {
    run.step("f4-commandk", "Command-K opens the switcher") {
        app.activate()
        app.key(Key.k, command: true)
        _ = try waitForElement("switcher search field", in: try mainWindow(),
                               role: kAXTextFieldRole as String, containing: "Search name")
    }
    run.step("f4-commandk", "search filters to the demo card") {
        let field = try waitForElement("switcher search field", in: try mainWindow(),
                                       role: kAXTextFieldRole as String, containing: "Search name")
        var attempts: [String] = []
        try waitUntil("query text to land in the search field", timeout: 12, interval: 0.8) {
            if field.stringValue.contains("smoke") { return true }
            app.activate()
            _ = field.setFocused()
            if !field.setValue("smoke") {
                app.type("smoke")
                attempts.append("typed (value now \"\(field.stringValue)\")")
            } else {
                attempts.append("set (value now \"\(field.stringValue)\")")
            }
            return field.stringValue.contains("smoke")
        }
        guard field.stringValue.contains("smoke") else {
            throw SmokeError(message: "search field never accepted text; attempts: \(attempts.joined(separator: ", "))")
        }
        _ = try waitForElement("filtered result", in: try mainWindow(), containing: "Shell smoke update")
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
    run.step("f5-settings", "theme and engine persist across relaunch") {
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

app.terminateAndWait()
exit(Int32(run.summarize()))
