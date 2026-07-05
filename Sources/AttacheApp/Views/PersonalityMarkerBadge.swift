import SwiftUI

struct PersonalityMarkerBadge: View {
    var marker: CardPersonalityMarker
    var accent: Color
    var compact = false
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
                        Text(marker.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.primary.opacity(0.14), lineWidth: 1))
                            .offset(y: -24)
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
