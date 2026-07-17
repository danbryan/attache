import AttacheCore
import XCTest
@testable import AttacheApp

/// Covers INF-356 step 3: the private-mode window edge tint reuses each
/// theme's `accentStop` (the same source `ThemeContrastTests` already
/// verifies against `signatureColor`/`signatureForegroundColor`), so it
/// automatically holds the same WCAG floor as every other accent-driven
/// highlight in the app on all four built-in themes, in both color schemes.
final class PrivateModeWindowTintTests: XCTestCase {
    func testTintAccentHoldsTheContrastFloorOnAllBuiltInThemes() {
        // .macOS defers to the live system accent color (Apple's own
        // contrast guarantee, not ours); every other built-in theme's
        // accent stop must hold 4.5:1 against the plate it renders on,
        // exactly like ThemeContrastTests already enforces for text.
        for theme in AttacheTheme.allCases where theme != .macOS && theme != .custom {
            for darkScheme in [true, false] {
                let accent = theme.accentStop(darkScheme: darkScheme)
                let plate: Double = darkScheme ? 0 : 1
                let ratio = WCAGContrast.ratio(
                    red1: accent.red, green1: accent.green, blue1: accent.blue,
                    red2: plate, green2: plate, blue2: plate)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(theme.title) tint accent fails \(darkScheme ? "dark" : "light") plate: \(String(format: "%.2f", ratio)):1")
            }
        }
    }
}
