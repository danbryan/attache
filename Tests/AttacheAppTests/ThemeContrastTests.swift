import XCTest
import AttacheCore
@testable import AttacheApp

/// Enforces the INF-150 contrast floor: every theme's accent must hold 4.5:1
/// against the plate it renders on in each scheme, and High Contrast targets
/// AAA (7:1). Plates are black in dark scheme and white in light scheme.
final class ThemeContrastTests: XCTestCase {
    func testAccentsHoldTheFloorOnTheirPlates() {
        // .macOS defers to the live system accent (Apple's contrast, not ours).
        for theme in CompanionTheme.allCases where theme != .macOS {
            for darkScheme in [true, false] {
                let accent = theme.accentStop(darkScheme: darkScheme)
                let plate: Double = darkScheme ? 0 : 1
                let ratio = WCAGContrast.ratio(
                    red1: accent.red, green1: accent.green, blue1: accent.blue,
                    red2: plate, green2: plate, blue2: plate)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(theme.title) accent fails \(darkScheme ? "dark" : "light") plate: \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    func testHighContrastTargetsAAA() {
        for darkScheme in [true, false] {
            let accent = CompanionTheme.highContrast.accentStop(darkScheme: darkScheme)
            let plate: Double = darkScheme ? 0 : 1
            let ratio = WCAGContrast.ratio(
                red1: accent.red, green1: accent.green, blue1: accent.blue,
                red2: plate, green2: plate, blue2: plate)
            XCTAssertGreaterThanOrEqual(ratio, 7.0)
        }
    }

    func testPrimaryTextHoldsTheFloorOnPlates() {
        // Primary text is near-white on the dark plate and near-black on the
        // light plate (system label colors at full alpha are stronger still).
        let darkRatio = WCAGContrast.ratio(red1: 0.92, green1: 0.92, blue1: 0.92,
                                           red2: 0, green2: 0, blue2: 0)
        let lightRatio = WCAGContrast.ratio(red1: 0.10, green1: 0.10, blue1: 0.10,
                                            red2: 1, green2: 1, blue2: 1)
        XCTAssertGreaterThan(darkRatio, 4.5)
        XCTAssertGreaterThan(lightRatio, 4.5)
    }
}
