import AppKit
import AttacheCore
import SwiftUI

/// Tiny source indicator: the official mark where we bundle one (Anthropic's
/// wordmark glyph for Claude Code, OpenAI's blossom for Codex), used
/// nominatively to say where a session came from. Falls back to the text chip
/// for sources without a mark or if the asset fails to load. The name always
/// lives on hover.
struct SourceBadge: View {
    let sourceKind: String
    let displayName: String

    private static let marks: [String: NSImage] = {
        var loaded: [String: NSImage] = [:]
        let names = [
            SourceKind.claudeCode.rawValue: "source-claude",
            SourceKind.codex.rawValue: "source-codex"
        ]
        for (kind, resource) in names {
            guard let url = sourceMarkURL(resource),
                  let image = NSImage(contentsOf: url), image.isValid else { continue }
            image.isTemplate = true
            loaded[kind] = image
        }
        return loaded
    }()

    /// Locate a bundled source mark WITHOUT touching `Bundle.module`. Its
    /// generated accessor calls `fatalError` when it cannot resolve the SwiftPM
    /// resource bundle, and on a clean install (macOS 26, quarantined) that
    /// lookup failed on the unsigned nested resource bundle and crashed the
    /// whole app the first time a SourceBadge rendered. We read the file by
    /// path and return nil (text-chip fallback) if it is absent, never crash.
    private static func sourceMarkURL(_ resource: String) -> URL? {
        if let url = Bundle.main.url(forResource: resource, withExtension: "svg") {
            return url
        }
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            let url = base
                .appendingPathComponent("Attache_AttacheApp.bundle", isDirectory: true)
                .appendingPathComponent("\(resource).svg")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    var body: some View {
        if let mark = Self.marks[sourceKind] {
            Image(nsImage: mark)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 11, height: 11)
                .foregroundStyle(.secondary)
                .help(displayName)
                .accessibilityLabel(displayName)
        } else {
            Text(displayName)
                .typoCaption(.heavy)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                .help(displayName)
                .accessibilityLabel(displayName)
        }
    }
}
