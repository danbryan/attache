import Foundation

/// Pure formatter for the About pane's "Voices & speech" credit lines. Kept in
/// Core, free of SwiftUI, so the exact wording and the tappable-link markup can
/// be unit tested without rendering a view.
///
/// The engine credit lines are fixed facts about the shipped runtime. The Azelma
/// line is derived from the license manifest so it can never disagree with the
/// bundled THIRD-PARTY-LICENSES.
public enum PremiumVoiceCredits {

    /// Primary speech-engine credit line.
    public static let engineCredit = "Speech engine: pocket-tts by Kyutai, MIT License."

    /// Secondary one-liner shown beneath the engine credit.
    public static let engineSubcredit = "Includes ONNX Runtime and SentencePiece, MIT and Apache 2.0 licensed."

    /// In-app updates credit line.
    public static let updatesCredit = "In-app updates: Sparkle, MIT License."

    /// Plain-text credit line for a voice entry, e.g.
    /// "Azelma voice: Derived from the VCTK Corpus ...".
    public static func voiceCreditPlain(_ entry: PremiumVoiceLicenseManifest.Entry) -> String {
        "\(entry.displayName) voice: \(entry.attributionText)"
    }

    /// The same credit line as SwiftUI-compatible Markdown, with the license
    /// name rendered as a tappable link to `licenseURL`. Falls back to the plain
    /// line if the expected license phrase is not present (so the copy can change
    /// without silently dropping the link into the wrong place).
    public static func voiceCreditMarkdown(_ entry: PremiumVoiceLicenseManifest.Entry) -> String {
        let plain = voiceCreditPlain(entry)
        let phrase = licensePhrase(entry.license)
        guard plain.contains(phrase) else { return plain }
        let link = "[\(phrase)](\(entry.licenseURL.absoluteString))"
        return plain.replacingOccurrences(of: phrase, with: link)
    }

    /// Human-facing license name used in the credit copy and as the link text.
    public static func licensePhrase(_ license: PremiumVoiceLicenseManifest.License) -> String {
        switch license {
        case .cc0: return "CC0 1.0"
        case .ccBy4: return "CC BY 4.0"
        }
    }
}
