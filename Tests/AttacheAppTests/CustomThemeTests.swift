import XCTest
import AttacheCore
@testable import AttacheApp

final class CustomThemeTests: XCTestCase {
    private func sampleSpec() -> CompanionThemeSpec {
        CompanionThemeSpec(
            id: "test.sample",
            name: "Sample",
            stops: [
                CompanionThemeStop(red: 0.1, green: 0.2, blue: 0.3),
                CompanionThemeStop(red: 0.4, green: 0.5, blue: 0.6),
                CompanionThemeStop(red: 0.7, green: 0.8, blue: 0.9)
            ],
            accentDark: CompanionThemeStop(red: 0.9, green: 0.9, blue: 0.9),
            accentLight: CompanionThemeStop(red: 0.1, green: 0.1, blue: 0.1)
        )
    }

    func testSpecRoundTripsThroughJSON() throws {
        let spec = sampleSpec()
        let decoded = try CustomThemeStore.decode(CustomThemeStore.encode(spec))
        XCTAssertEqual(decoded, spec)
    }

    func testContrastFloorEnforcementFixesBadAccents() {
        // Deliberately unreadable: near-black on the dark plate, near-white on
        // the light plate.
        var spec = sampleSpec()
        spec.accentDark = CompanionThemeStop(red: 0.05, green: 0.05, blue: 0.08)
        spec.accentLight = CompanionThemeStop(red: 0.97, green: 0.97, blue: 0.95)
        let enforced = spec.enforcingContrastFloor()
        XCTAssertGreaterThanOrEqual(
            CompanionThemeSpec.contrastRatio(enforced.accentDark, onDarkPlate: true), 4.5)
        XCTAssertGreaterThanOrEqual(
            CompanionThemeSpec.contrastRatio(enforced.accentLight, onDarkPlate: false), 4.5)
    }

    func testEnforcementLeavesGoodAccentsAlone() {
        let spec = sampleSpec()
        let enforced = spec.enforcingContrastFloor()
        XCTAssertEqual(enforced.accentDark, spec.accentDark)
        XCTAssertEqual(enforced.accentLight, spec.accentLight)
    }

    func testCustomCaseFallsBackToCyberpunkWithoutSpec() {
        let previous = CustomThemeStore.activeSpec
        defer { CustomThemeStore.activeSpec = previous }
        CustomThemeStore.activeSpec = nil
        XCTAssertEqual(CompanionTheme.custom.stops, CompanionTheme.cyberpunk.stops)
        XCTAssertEqual(CompanionTheme.custom.accentStop(darkScheme: true),
                       CompanionTheme.cyberpunk.accentStop(darkScheme: true))
    }

    func testCustomCaseReadsActiveSpec() {
        let previous = CustomThemeStore.activeSpec
        defer { CustomThemeStore.activeSpec = previous }
        let spec = sampleSpec()
        CustomThemeStore.activeSpec = spec
        XCTAssertEqual(CompanionTheme.custom.stops, spec.stops)
        XCTAssertEqual(CompanionTheme.custom.accentStop(darkScheme: true), spec.accentDark)
        XCTAssertEqual(CompanionTheme.custom.accentStop(darkScheme: false), spec.accentLight)
        XCTAssertEqual(CompanionTheme.custom.title, "Sample")
    }

    /// Every seed theme shipped in themes/ must decode and hold the same
    /// contrast floor the built-ins are tested against.
    func testSeedThemesDecodeAndHoldTheFloor() throws {
        let seedsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AttacheAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("themes", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: seedsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertGreaterThanOrEqual(files.count, 3, "expected the pruned seed set in themes/ (cyberpunk, paper, high-contrast)")
        for file in files {
            let spec = try CustomThemeStore.decode(Data(contentsOf: file))
            XCTAssertEqual(spec.stops.count, 3, "\(spec.name) needs 3 gradient stops")
            XCTAssertGreaterThanOrEqual(
                CompanionThemeSpec.contrastRatio(spec.accentDark, onDarkPlate: true), 4.5,
                "\(spec.name) dark accent fails the floor")
            XCTAssertGreaterThanOrEqual(
                CompanionThemeSpec.contrastRatio(spec.accentLight, onDarkPlate: false), 4.5,
                "\(spec.name) light accent fails the floor")
        }
    }
}
