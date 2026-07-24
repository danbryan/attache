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

    enum ImportError: LocalizedError, Equatable {
        case invalidManifest
        case unreadableFrame(String)
        case unsafePath(String)
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidManifest:
                return "That folder is not a valid Attaché appearance (no readable manifest.json with a neutral frame)."
            case .unreadableFrame(let path):
                return "The appearance references an image that could not be read: \(path)."
            case .unsafePath(let path):
                return "The appearance references an unsafe file path: \(path)."
            case .copyFailed(let reason):
                return "Could not import the appearance: \(reason)."
            }
        }
    }

    /// Import a `*.attache-character` package from anywhere on disk (a folder the
    /// user downloaded, cloned from GitHub, or authored) into the app's Characters
    /// directory, and return its stored reference (the destination directory name).
    ///
    /// Untrusted input, so this validates rather than trusts: the manifest must
    /// decode and validate, every referenced frame must be a normal relative path
    /// (no absolute paths, no `..` traversal) that decodes as an image, and only
    /// the manifest and its referenced frames are copied, never arbitrary files
    /// that happen to sit in the source folder. Name collisions get a numeric
    /// suffix so an import never overwrites an existing appearance.
    @discardableResult
    static func importPackage(from source: URL, into dir: URL = charactersDirectory()) throws -> String {
        let manifestURL = source.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(AttacheCharacterManifest.self, from: data),
              (try? manifest.validate()) != nil else {
            throw ImportError.invalidManifest
        }
        // Validate every referenced frame is a safe relative path that decodes.
        for rel in manifest.frames.values {
            if rel.hasPrefix("/") || rel.split(separator: "/").contains("..") {
                throw ImportError.unsafePath(rel)
            }
            let frameURL = source.appendingPathComponent(rel)
            guard let ns = NSImage(contentsOf: frameURL),
                  ns.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil else {
                throw ImportError.unreadableFrame(rel)
            }
        }

        let rawBase = source.pathExtension == "attache-character"
            ? source.deletingPathExtension().lastPathComponent
            : manifest.name
        let base = safeDirectoryName(rawBase)
        var dest = dir.appendingPathComponent("\(base).attache-character", isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) \(suffix).attache-character", isDirectory: true)
            suffix += 1
        }

        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            try data.write(to: dest.appendingPathComponent("manifest.json"))
            for rel in Set(manifest.frames.values) {
                let dst = dest.appendingPathComponent(rel)
                try FileManager.default.createDirectory(
                    at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source.appendingPathComponent(rel), to: dst)
            }
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw ImportError.copyFailed(error.localizedDescription)
        }
        cache.removeValue(forKey: dest.lastPathComponent)
        return dest.lastPathComponent
    }

    /// Reduce an arbitrary name to a safe single path component (no separators or
    /// traversal), so an import can never write outside the Characters directory.
    static func safeDirectoryName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(raw.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Imported" : cleaned
    }
}
