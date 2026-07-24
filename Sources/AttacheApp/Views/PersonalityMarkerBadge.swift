import SwiftUI

struct PersonalityMarkerBadge: View {
    var marker: CardPersonalityMarker
    var accent: Color
    var compact = false
    // Used only to give the compact hover label the app's solid reading plate
    // (fully opaque under High Contrast) so it matches the other popovers.
    var theme: AttacheTheme = .macOS
    @State private var hovering = false

    var body: some View {
        // Compact rows show just the mark in the same quiet gray as the play
        // button; the name appears instantly on hover instead of a delayed
        // system tooltip.
        if compact {
            Image(systemName: marker.isUnavailable ? "questionmark.circle" : "theatermasks")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.secondary.opacity(hovering ? 0.9 : 0.6))
                .padding(3)
                .background(Circle().fill(Color.secondary.opacity(0.08)))
                .overlay(Circle().stroke(Color.secondary.opacity(0.24), lineWidth: 1))
                .overlay(alignment: .top) {
                    if hovering {
                        // Styled to match the app's popover surface (material
                        // over a solid reading plate, hairline stroke, soft
                        // shadow, small rounded rectangle) rather than a bare
                        // translucent pill, so it reads like the receipt
                        // popover and the command palettes.
                        Text(marker.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                            .readingPlate(theme: theme, cornerRadius: 7, minimumOpacity: 0.9)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
                            .offset(y: -28)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .zIndex(hovering ? 50 : 0)
                .onHover { hovering = $0 }
                .accessibilityLabel(marker.displayName)
        } else {
            Label {
                Text(marker.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: marker.isUnavailable ? "questionmark.circle" : "theatermasks")
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(marker.isUnavailable ? Color.secondary.opacity(0.88) : accent.opacity(0.94))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill((marker.isUnavailable ? Color.secondary : accent).opacity(0.14))
            )
            .overlay(
                Capsule().stroke((marker.isUnavailable ? Color.secondary : accent).opacity(0.26), lineWidth: 1)
            )
            .help(marker.displayName)
        }
    }
}
