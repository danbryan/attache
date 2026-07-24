import AppKit
import AttacheCore
import Foundation

/// Loaded, drawable artwork for a "bring your own presence" package
/// (`<name>.attache-character/`). Holds the manifest and lazily decodes frame
/// bitmaps, caching each so the per-frame draw in `AttacheCharacterFigure` never
/// re-reads disk. Reference type so it is cheap to thread through the views and
/// share from the store's cache. See docs/byo-presence.md.
final class AtlasArtwork {
    let manifest: AttacheCharacterManifest
    let baseURL: URL
    private var frameCache: [String: CGImage] = [:]

    init(manifest: AttacheCharacterManifest, baseURL: URL) {
        self.manifest = manifest
        self.baseURL = baseURL
    }

    var displayName: String { manifest.name }

    /// The bitmap to draw for a given face state (Tier 0 resolves to neutral).
    func image(for state: AtlasFaceState) -> CGImage? {
        image(relativePath: AttacheCharacterAtlas.framePath(for: state, in: manifest))
    }

    /// The neutral frame, used by static previews.
    func neutralImage() -> CGImage? {
        guard let rel = manifest.neutralPath else { return nil }
        return image(relativePath: rel)
    }

    private func image(relativePath: String) -> CGImage? {
        if relativePath.isEmpty { return nil }
        if let cached = frameCache[relativePath] { return cached }
        // User art lives outside the app bundle; load by explicit file URL with
        // a graceful nil (never Bundle.module, per AGENTS.md Gotchas).
        let url = baseURL.appendingPathComponent(relativePath)
        guard let ns = NSImage(contentsOf: url),
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        frameCache[relativePath] = cg
        return cg
    }
}

/// Discovers and loads custom-presence packages from
/// `~/Library/Application Support/Attache/Characters/`, caching loaded artwork
/// by directory so repeated resolves are free.
enum AttacheCustomPresenceStore {
    static func charactersDirectory() -> URL {
        AttacheAppSupport.supportDirectory()
            .appendingPathComponent("Characters", isDirectory: true)
    }

    /// All `*.attache-character` package directories, sorted by name.
    static func packageURLs() -> [URL] {
        let dir = charactersDirectory()
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .filter { $0.pathExtension == "attache-character" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Load and validate one package into drawable artwork, or nil if its
    /// manifest is missing/invalid (a dangling reference falls back this way).
    static func load(_ packageURL: URL) -> AtlasArtwork? {
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(AttacheCharacterManifest.self, from: data),
              (try? manifest.validate()) != nil else {
            return nil
        }
        return AtlasArtwork(manifest: manifest, baseURL: packageURL)
    }

    private static var cache: [String: AtlasArtwork] = [:]

    /// Resolve a package by its directory name (the personality's
    /// `customPresenceRef`), cached across calls.
    static func artwork(forRef ref: String) -> AtlasArtwork? {
        if let cached = cache[ref] { return cached }
        let url = charactersDirectory().appendingPathComponent(ref, isDirectory: true)
        guard let art = load(url) else { return nil }
        cache[ref] = art
        return art
    }

    /// MVP convenience: the first available package (used until per-personality
    /// selection is wired), and the package directory name that would be stored
    /// as a `customPresenceRef`.
    static func firstArtwork() -> AtlasArtwork? {
        packageURLs().first.flatMap(load)
    }

    static func firstRef() -> String? {
        packageURLs().first?.lastPathComponent
    }
}
