import SwiftUI

// Semantic type scale (INF-149). All user-readable text goes through these
// tokens so the floor (nothing below caption at 11pt) and the user's text size
// setting apply everywhere at once. Captions have their own independent size
// system and do not use these tokens.

enum AttacheTypeScale {
    static let caption: CGFloat = 11
    static let label: CGFloat = 12
    static let body: CGFloat = 13
    static let section: CGFloat = 15
    static let title: CGFloat = 18

    static let minimumScale: Double = 0.9
    static let maximumScale: Double = 1.4

    static func clamp(_ scale: Double) -> Double {
        min(maximumScale, max(minimumScale, scale))
    }
}

private struct AttacheTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var attacheTextScale: CGFloat {
        get { self[AttacheTextScaleKey.self] }
        set { self[AttacheTextScaleKey.self] = newValue }
    }
}

private struct TypoFont: ViewModifier {
    @Environment(\.attacheTextScale) private var scale
    var size: CGFloat
    var weight: Font.Weight
    var design: Font.Design
    var monoDigit: Bool

    func body(content: Content) -> some View {
        var font = Font.system(size: size * scale, weight: weight, design: design)
        if monoDigit { font = font.monospacedDigit() }
        return content.font(font)
    }
}

extension View {
    /// Smallest allowed text: timestamps, badges, fine print. 11pt at 1x.
    func typoCaption(_ weight: Font.Weight = .regular,
                     design: Font.Design = .default,
                     monoDigit: Bool = false) -> some View {
        modifier(TypoFont(size: AttacheTypeScale.caption, weight: weight, design: design, monoDigit: monoDigit))
    }

    /// Secondary labels and chips. 12pt at 1x.
    func typoLabel(_ weight: Font.Weight = .regular,
                   design: Font.Design = .default,
                   monoDigit: Bool = false) -> some View {
        modifier(TypoFont(size: AttacheTypeScale.label, weight: weight, design: design, monoDigit: monoDigit))
    }

    /// Primary reading text. 13pt at 1x, matching macOS body.
    func typoBody(_ weight: Font.Weight = .regular,
                  design: Font.Design = .default,
                  monoDigit: Bool = false) -> some View {
        modifier(TypoFont(size: AttacheTypeScale.body, weight: weight, design: design, monoDigit: monoDigit))
    }

    /// Section headers and prominent field text. 15pt at 1x.
    func typoSection(_ weight: Font.Weight = .semibold,
                     design: Font.Design = .default) -> some View {
        modifier(TypoFont(size: AttacheTypeScale.section, weight: weight, design: design, monoDigit: false))
    }

    /// Pane and window titles. 18pt at 1x.
    func typoTitle(_ weight: Font.Weight = .semibold,
                   design: Font.Design = .default) -> some View {
        modifier(TypoFont(size: AttacheTypeScale.title, weight: weight, design: design, monoDigit: false))
    }

    /// Display-level text above the title size. Scales, no floor semantics.
    func typoDisplay(size: CGFloat,
                     _ weight: Font.Weight = .regular,
                     design: Font.Design = .default) -> some View {
        modifier(TypoFont(size: size, weight: weight, design: design, monoDigit: false))
    }

    /// SF Symbol and decorative glyph sizing. Scales with the text setting but
    /// keeps its designed base size (glyphs are exempt from the 11pt floor).
    func typoIcon(size: CGFloat, _ weight: Font.Weight = .regular,
                  design: Font.Design = .default) -> some View {
        modifier(TypoFont(size: size, weight: weight, design: design, monoDigit: false))
    }

    /// Injects the user's text size multiplier for the whole subtree.
    func attacheTextScale(_ scale: Double) -> some View {
        environment(\.attacheTextScale, CGFloat(AttacheTypeScale.clamp(scale)))
    }
}
