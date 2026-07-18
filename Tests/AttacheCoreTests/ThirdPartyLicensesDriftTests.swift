import XCTest
@testable import AttacheCore

/// The checked-in THIRD-PARTY-LICENSES must match what the generator produces,
/// so a stale acknowledgements file fails the suite instead of shipping. Runs
/// the generator's `--verify` mode, which regenerates in memory and diffs.
final class ThirdPartyLicensesDriftTests: XCTestCase {

    func testCheckedInLicensesMatchRegeneration() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AttacheCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let script = repoRoot
            .appendingPathComponent("scripts")
            .appendingPathComponent("generate-third-party-licenses.sh")

        guard FileManager.default.fileExists(atPath: script.path) else {
            return XCTFail("generator script missing at \(script.path)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--verify"]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let message = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTFail("THIRD-PARTY-LICENSES is stale; regenerate with scripts/generate-third-party-licenses.sh.\n\(message)")
        }
    }
}
