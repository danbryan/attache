import SwiftUI

// Backing plates for reading surfaces (INF-150). Text never sits directly on
// the visualizer: every reading surface gets a minimum-opacity solid plate
// under its material, independent of the user's window surface opacity.
// High Contrast makes the plate fully solid.

private struct ReadingPlate: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var theme: AttacheTheme
    var cornerRadius: CGFloat
    var minimumOpacity: Double

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(plateColor)
        )
    }

    private var plateColor: Color {
        let opacity = theme.wantsSolidPlates ? 1.0 : minimumOpacity
        return scheme == .dark
            ? Color.black.opacity(opacity)
            : Color.white.opacity(opacity)
    }
}

extension View {
    /// Applies after any material background so the solid plate sits beneath
    /// it, guaranteeing a readable base even at minimum surface opacity.
    func readingPlate(theme: AttacheTheme,
                      cornerRadius: CGFloat = 14,
                      minimumOpacity: Double = 0.75) -> some View {
        modifier(ReadingPlate(theme: theme, cornerRadius: cornerRadius, minimumOpacity: minimumOpacity))
    }
}
