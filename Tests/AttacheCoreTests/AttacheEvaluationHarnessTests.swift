import AttacheCore
import XCTest
import Foundation

final class AttacheEvaluationHarnessTests: XCTestCase {

    // Criterion: all synthetic profiles stay within their hard limits.
    func testAllProfilesStayWithinHardLimits() {
        for profile in AttacheEvaluationHarness.profiles {
            let result = AttacheEvaluationHarness.scenarioBudgetCompliance(profile: profile)
            XCTAssertTrue(result.passed, "\(profile.name) should stay within hard limits: \(result.violations)")
        }
    }

    // Criterion: no-focus requests leak zero unauthorized source IDs.
    func testNoFocusLeakage() {
        let result = AttacheEvaluationHarness.scenarioNoFocusLeakage()
        XCTAssertTrue(result.passed, "no-focus should not leak unauthorized sources: \(result.violations)")
    }

    // Criterion: Maximum >= Automatic >= Efficient for evidence.
    func testStrategyMonotonicity() {
        let result = AttacheEvaluationHarness.scenarioStrategyMonotonicity()
        XCTAssertTrue(result.passed, "strategy monotonicity should hold: \(result.violations)")
    }

    // Criterion: large profiles not held to universal small cap.
    func testLargeProfileNotCapped() {
        let result = AttacheEvaluationHarness.scenarioLargeProfileNotCapped()
        XCTAssertTrue(result.passed, "large profile should not be capped to small limit: \(result.violations)")
    }

    // Criterion: effectful tools execute at most once.
    func testEffectfulOnce() {
        let result = AttacheEvaluationHarness.scenarioEffectfulOnce()
        XCTAssertTrue(result.passed, "effectful tool replay should be prohibited: \(result.violations)")
    }

    // Criterion: memory scope/egress and session authorization separate.
    func testMemoryScopeEgressSeparate() {
        let result = AttacheEvaluationHarness.scenarioMemoryScopeEgressSeparate()
        XCTAssertTrue(result.passed, "local-only memory should not leak to remote: \(result.violations)")
    }

    // Criterion: incomplete or failed coverage never scores as complete.
    func testIncompleteNeverComplete() {
        let result = AttacheEvaluationHarness.scenarioIncompleteNeverComplete()
        XCTAssertTrue(result.passed, "incomplete should not score as complete: \(result.violations)")
    }

    // Criterion: reports contain no secret literals.
    func testReportNoSecrets() {
        let results = AttacheEvaluationHarness.runAllScenarios()
        let result = AttacheEvaluationHarness.scenarioReportNoSecrets(results: results)
        XCTAssertTrue(result.passed, "reports should contain no secrets: \(result.violations)")
    }

    // Criterion: repeated runs are deterministic.
    func testDeterminism() {
        let run1 = AttacheEvaluationHarness.runAllScenarios()
        let run2 = AttacheEvaluationHarness.runAllScenarios()
        let result = AttacheEvaluationHarness.scenarioDeterminism(run1: run1, run2: run2)
        XCTAssertTrue(result.passed, "repeated runs should be deterministic: \(result.violations)")
    }

    // Full harness run produces a report.
    func testFullRunProducesReport() {
        let report = AttacheEvaluationHarness.run()
        XCTAssertGreaterThan(report.totalScenarios, 0)
        XCTAssertEqual(report.totalScenarios, report.passedCount + report.failedCount)
        XCTAssertTrue(report.allPassed, "all scenarios should pass: \(report.humanReport())")
    }

    // Human report is content-free.
    func testHumanReportContentFree() {
        let report = AttacheEvaluationHarness.run()
        let human = report.humanReport()
        XCTAssertFalse(human.contains("api_key"))
        XCTAssertFalse(human.contains("password"))
        XCTAssertFalse(human.contains("private_key"))
    }

    // JSON report is machine-readable.
    func testJSONReportMachineReadable() {
        let report = AttacheEvaluationHarness.run()
        let json = report.jsonReport()
        XCTAssertTrue(json.hasPrefix("{"))
        XCTAssertTrue(json.hasSuffix("}"))
    }

    // Profiles include 8K, 64K, 1M, 10M, and unknown.
    func testProfilesCoverAllSizes() {
        let names = AttacheEvaluationHarness.profiles.map { $0.name }
        XCTAssertTrue(names.contains { $0.hasPrefix("8K") })
        XCTAssertTrue(names.contains { $0.hasPrefix("64K") })
        XCTAssertTrue(names.contains { $0.hasPrefix("1M") })
        XCTAssertTrue(names.contains { $0.hasPrefix("10M") })
        XCTAssertTrue(names.contains { $0.hasPrefix("unknown") })
    }
}