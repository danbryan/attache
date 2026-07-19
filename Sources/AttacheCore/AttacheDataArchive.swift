import Foundation

/// Pure manifest, inclusion/exclusion, and version-gating logic for the in-app
/// "back up / restore / reset" data archive (INF-391).
///
/// The App layer performs the impure work (enumerating the app-support
/// directory, exporting the app's own defaults domain, packing the archive with
/// `ditto`, and swapping the live directory). Everything decidable WITHOUT
/// touching the filesystem or the keychain lives here so it can be unit tested:
/// what belongs in an archive, which defaults keys are stripped as sensitive,
/// and whether a given archive is safe to restore into this app version.
///
/// The archive never contains keychain material. Provider API keys live in the
/// keychain, not the profile directory, so they are structurally absent from
/// the copied app-support entries. As defense in depth the exported defaults
/// dictionary is additionally scrubbed of any key whose NAME matches a
/// sensitive pattern (see `redactingSensitiveKeys`).
public enum AttacheDataArchive {
    /// Bumped only when the on-disk archive layout changes in a way an older app
    /// cannot read. A restore of a NEWER `formatVersion` is refused (see
    /// `validateRestorable`).
    public static let currentFormatVersion = 1

    /// Name of the manifest JSON inside an archive.
    public static let manifestFileName = "manifest.json"
    /// Name of the exported defaults plist inside an archive.
    public static let defaultsFileName = "defaults.plist"
    /// Directory inside the archive holding the copied app-support entries.
    public static let supportDirectoryName = "support"

    /// Top-level app-support entries that are NEVER copied into an archive.
    /// - `event-token`: the per-launch bearer token for the local event server;
    ///   secret and meaningless after this launch.
    /// - `AudioCache`: a regenerable cache of recap audio, not user state.
    public static let alwaysExcludedEntryNames: Set<String> = [
        "event-token",
        "AudioCache"
    ]

    /// A cache of a public, re-downloadable on-device voice asset. Excluded by
    /// default (it bloats the archive with a public download) but the user may
    /// opt to include it.
    public static let premiumVoiceEntryName = "PremiumVoice"

    /// Versioned archive manifest. `createdAt` and `appVersion` are supplied by
    /// the App layer at pack time; `contents` lists the archived top-level
    /// app-support entries plus the defaults export.
    public struct Manifest: Codable, Equatable {
        public var formatVersion: Int
        public var createdAt: Date
        public var appVersion: String
        public var contents: [String]

        public init(
            formatVersion: Int = AttacheDataArchive.currentFormatVersion,
            createdAt: Date,
            appVersion: String,
            contents: [String]
        ) {
            self.formatVersion = formatVersion
            self.createdAt = createdAt
            self.appVersion = appVersion
            self.contents = contents
        }
    }

    public enum ArchiveError: Error, Equatable, CustomStringConvertible {
        /// The archive was written by a newer app than this one.
        case unsupportedFutureFormat(found: Int, supported: Int)
        /// The manifest could not be decoded.
        case malformedManifest

        public var description: String {
            switch self {
            case let .unsupportedFutureFormat(found, supported):
                return "This backup was made by a newer version of Attaché "
                    + "(format \(found)). This app supports up to format "
                    + "\(supported). Update Attaché, then try again."
            case .malformedManifest:
                return "This backup is missing or has an unreadable manifest and cannot be restored."
            }
        }
    }

    // MARK: - Filesystem inclusion

    /// Whether a top-level app-support entry is copied into the archive.
    public static func includesEntry(named name: String, includePremiumVoice: Bool) -> Bool {
        if alwaysExcludedEntryNames.contains(name) { return false }
        if name == premiumVoiceEntryName { return includePremiumVoice }
        return true
    }

    /// Whether the "include downloaded voice" backup option should be offered.
    /// There is nothing to include unless the premium voice is actually
    /// installed, so the checkbox is hidden otherwise.
    public static func showsIncludePremiumVoiceOption(isPremiumVoiceInstalled: Bool) -> Bool {
        isPremiumVoiceInstalled
    }

    /// Resolves the effective `includePremiumVoice` flag for a backup. The voice
    /// is packed only when it is installed AND the user opted in, so a checked
    /// box can never smuggle in a non-existent entry when nothing is installed.
    public static func resolvedIncludePremiumVoice(
        isPremiumVoiceInstalled: Bool,
        userRequestedInclusion: Bool
    ) -> Bool {
        isPremiumVoiceInstalled && userRequestedInclusion
    }

    /// Filters and sorts top-level app-support entry names down to those that
    /// belong in an archive, applying the exclusion rules.
    public static func plannedContents(
        fromEntryNames names: [String],
        includePremiumVoice: Bool
    ) -> [String] {
        names
            .filter { includesEntry(named: $0, includePremiumVoice: includePremiumVoice) }
            .sorted()
    }

    // MARK: - Sensitive defaults redaction

    /// Case-insensitive substrings that mark a defaults key as sensitive.
    /// Provider secrets live in the keychain, but the defaults domain has
    /// historically carried an inline-key entry and a secret-reference entry, so
    /// the export strips anything matching by name.
    public static let sensitiveKeySubstrings: [String] = [
        "apikey",
        "secret",
        "token",
        "password",
        "credential",
        "bearer"
    ]

    public static func isSensitiveDefaultsKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return sensitiveKeySubstrings.contains { lower.contains($0) }
    }

    /// Splits a defaults dictionary into the keys safe to archive and the sorted
    /// names of the sensitive keys that were stripped. Generic over value type
    /// so it can be tested with plain `[String: String]` fixtures.
    public static func redactingSensitiveKeys<Value>(
        _ dictionary: [String: Value]
    ) -> (kept: [String: Value], stripped: [String]) {
        var kept: [String: Value] = [:]
        var stripped: [String] = []
        for (key, value) in dictionary {
            if isSensitiveDefaultsKey(key) {
                stripped.append(key)
            } else {
                kept[key] = value
            }
        }
        return (kept, stripped.sorted())
    }

    // MARK: - Restore gating

    /// Throws `ArchiveError.unsupportedFutureFormat` when the manifest was
    /// written by a newer app than this one. Older or equal formats restore.
    public static func validateRestorable(manifest: Manifest) throws {
        guard manifest.formatVersion <= currentFormatVersion else {
            throw ArchiveError.unsupportedFutureFormat(
                found: manifest.formatVersion,
                supported: currentFormatVersion
            )
        }
    }

    // MARK: - Manifest coding

    public static func encodeManifest(_ manifest: Manifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    /// Decodes a manifest, throwing `ArchiveError.malformedManifest` on failure.
    public static func decodeManifest(from data: Data) throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(Manifest.self, from: data) else {
            throw ArchiveError.malformedManifest
        }
        return manifest
    }
}
