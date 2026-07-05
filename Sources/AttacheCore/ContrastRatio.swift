import Foundation

/// WCAG 2.x relative luminance and contrast ratio for sRGB colors (INF-150).
/// Used by the theme contrast floor: no text color may pair with its backing
/// plate below 4.5:1.
public enum WCAGContrast {
    public static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }

    public static func ratio(red1: Double, green1: Double, blue1: Double,
                             red2: Double, green2: Double, blue2: Double) -> Double {
        let first = relativeLuminance(red: red1, green: green1, blue: blue1)
        let second = relativeLuminance(red: red2, green: green2, blue: blue2)
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func linearize(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}
