import AppKit
import ApplicationServices

struct SmokeError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

/// Launches and owns the packaged app under test. The binary inside the .app
/// bundle is spawned directly so environment variables pass through without
/// launchctl, while Bundle.main still resolves to the bundle (defaults domain,
/// Info.plist) because the executable path is inside it.
final class AppUnderTest {
    let appURL: URL
    private var process: Process?
    private(set) var pid: pid_t = 0

    init(appURL: URL) {
        self.appURL = appURL
    }

    var axApp: AXElement { AXElement.application(pid: pid) }
    var appWindows: [AXElement] {
        axApp.windows.filter { $0.role == kAXWindowRole as String }
    }

    func launch() throws {
        let binary = appURL
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent("Attache")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw SmokeError(message: "app binary not found at \(binary.path); run SIGN_APP=0 scripts/package-app.sh first")
        }
        let process = Process()
        process.executableURL = binary
        var environment = ProcessInfo.processInfo.environment
        environment["ATTACHE_UI_TEST"] = "1"
        // Keep headed smokes silent without changing the Mac's system volume.
        // Audio still decodes, plays, advances captions, and drives the bars.
        environment["ATTACHE_UI_TEST_MUTE_AUDIO"] = "1"
        process.environment = environment
        try process.run()
        self.process = process
        pid = process.processIdentifier

        try waitUntil("app exposes at least one window", timeout: 20) {
            !self.appWindows.isEmpty
        }
        activate()
    }

    func activate() {
        NSRunningApplication(processIdentifier: pid)?
            .activate(options: [.activateIgnoringOtherApps])
        appWindows.first?.raiseWindow()
    }

    func terminateAndWait(timeout: TimeInterval = 10) {
        guard let process, process.isRunning else { return }
        // Ask politely first so state is flushed the same way a user quit would.
        NSRunningApplication(processIdentifier: pid)?.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        self.process = nil
    }

    // MARK: Keyboard

    /// Posts a key chord directly to the app's event queue, so it works without
    /// the app being frontmost systemwide.
    func key(_ keyCode: CGKeyCode, command: Bool = false) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            if command { event.flags = .maskCommand }
            event.postToPid(pid)
            Thread.sleep(forTimeInterval: 0.03)
        }
    }

    /// Types text as real key events into the focused control. Fallback for
    /// SwiftUI fields that ignore a programmatic AXValue set.
    func type(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for character in text.unicodeScalars {
            var utf16 = Array(String(character).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                event.postToPid(pid)
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }
}

enum Key {
    static let l: CGKeyCode = 37
    static let returnKey: CGKeyCode = 36
    static let k: CGKeyCode = 40
    static let i: CGKeyCode = 34
    static let y: CGKeyCode = 16
    static let comma: CGKeyCode = 43
    static let escape: CGKeyCode = 53
}

// MARK: Waiting

func waitUntil(_ what: String,
               timeout: TimeInterval = 10,
               interval: TimeInterval = 0.25,
               condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        Thread.sleep(forTimeInterval: interval)
    }
    throw SmokeError(message: "timed out after \(Int(timeout))s waiting for \(what)")
}

/// Waits for an element matching the query to exist, returning it. On timeout
/// the failure names the query and dumps the nearest tree so the missing or
/// mislabeled AX element is identifiable from the message alone.
func waitForElement(_ what: String,
                    in root: @autoclosure () throws -> AXElement,
                    role: String? = nil,
                    containing query: String,
                    timeout: TimeInterval = 10) throws -> AXElement {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let found = (try? root())?.firstDescendant(role: role, containing: query) {
            return found
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    let dump = (try? root())?.treeDump() ?? "(no root element available)"
    throw SmokeError(message: """
        could not find \(what): no element\(role.map { " with role \($0)" } ?? "") \
        matching "\(query)" appeared within \(Int(timeout))s. AX tree at failure:
        \(dump)
        """)
}

func waitForElement(_ what: String,
                    in root: @autoclosure () throws -> AXElement,
                    role: String? = nil,
                    exactly query: String,
                    timeout: TimeInterval = 10) throws -> AXElement {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let found = (try? root())?.firstDescendant(role: role, exactly: query) {
            return found
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    let dump = (try? root())?.treeDump() ?? "(no root element available)"
    throw SmokeError(message: """
        could not find \(what): no element\(role.map { " with role \($0)" } ?? "") \
        exactly matching "\(query)" appeared within \(Int(timeout))s. AX tree at failure:
        \(dump)
        """)
}

func waitForElement(_ what: String,
                    in root: @autoclosure () throws -> AXElement,
                    timeout: TimeInterval = 10,
                    matching predicate: (AXElement) -> Bool) throws -> AXElement {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let found = (try? root())?.descendants(where: predicate, collectLimit: 1).first {
            return found
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    let dump = (try? root())?.treeDump() ?? "(no root element available)"
    throw SmokeError(message: """
        could not find \(what): no matching element appeared within \(Int(timeout))s. AX tree at failure:
        \(dump)
        """)
}

func waitForElementGone(_ what: String,
                        in root: @autoclosure () throws -> AXElement,
                        role: String? = nil,
                        containing query: String,
                        timeout: TimeInterval = 10) throws {
    try waitUntil("\(what) to disappear", timeout: timeout) {
        (try? root())?.firstDescendant(role: role, containing: query) == nil
    }
}

// MARK: Step runner

struct StepResult {
    var flow: String
    var step: String
    var error: SmokeError?
    var passed: Bool { error == nil }
}

final class SmokeRun {
    private(set) var results: [StepResult] = []

    func step(_ flow: String, _ name: String, _ body: () throws -> Void) {
        do {
            try body()
            results.append(StepResult(flow: flow, step: name, error: nil))
            print("  PASS  \(flow) / \(name)")
        } catch let error as SmokeError {
            results.append(StepResult(flow: flow, step: name, error: error))
            print("  FAIL  \(flow) / \(name)\n        \(error.message)")
        } catch {
            let wrapped = SmokeError(message: String(describing: error))
            results.append(StepResult(flow: flow, step: name, error: wrapped))
            print("  FAIL  \(flow) / \(name)\n        \(wrapped.message)")
        }
    }

    /// Runs a step whose failure makes the rest of the flow meaningless.
    /// Returns false so the flow can bail out early.
    func requiredStep(_ flow: String, _ name: String, _ body: () throws -> Void) -> Bool {
        step(flow, name, body)
        return results.last?.passed == true
    }

    func summarize() -> Int {
        let failures = results.filter { !$0.passed }
        print("")
        print("UI smoke: \(results.count - failures.count)/\(results.count) steps passed")
        for failure in failures {
            print("  FAILED: \(failure.flow) / \(failure.step)")
        }
        return failures.isEmpty ? 0 : 1
    }
}
