import Foundation

/// The pinned license manifest for Attaché Premium voices. This is the single
/// source of truth for voice attribution shown in the About pane and rendered
/// into the bundled THIRD-PARTY-LICENSES file.
///
/// The `License` enum deliberately admits only the two permissive licenses the
/// shipped catalog is allowed to carry (`cc0`, `ccBy4`). Noncommercial licenses
/// are simply not representable here, so a noncommercial voice cannot be added
/// to the shipped manifest without failing to compile. A unit test also asserts
/// the known noncommercial catalog ids never appear in `shipped`.
///
/// Pure and `Codable` so the About pane, the generator script's JSON input, and
/// tests all agree with no network or bundle access.
public struct PremiumVoiceLicenseManifest: Equatable, Codable, Sendable {

    /// The only licenses a shipped voice may carry. Noncommercial is unrepresentable.
    public enum License: String, Codable, Sendable {
        case cc0
        case ccBy4
    }

    public struct Entry: Equatable, Codable, Sendable {
        /// Stable catalog id, e.g. "azelma".
        public let id: String
        /// Human-facing voice name shown in credits.
        public let displayName: String
        /// Provenance sentence: where the voice was derived from.
        public let sourceDescription: String
        public let license: License
        /// Required non-empty when `license == .ccBy4`; the full attribution
        /// sentence rendered verbatim in credits.
        public let attributionText: String
        /// The canonical license URL (e.g. the CC BY 4.0 legal code).
        public let licenseURL: URL

        public init(
            id: String,
            displayName: String,
            sourceDescription: String,
            license: License,
            attributionText: String,
            licenseURL: URL
        ) {
            self.id = id
            self.displayName = displayName
            self.sourceDescription = sourceDescription
            self.license = license
            self.attributionText = attributionText
            self.licenseURL = licenseURL
        }

        /// True when this entry violates the attribution contract: a CC BY 4.0
        /// voice with empty attribution text or an empty license URL.
        public var isMissingRequiredAttribution: Bool {
            guard license == .ccBy4 else { return false }
            let attribution = attributionText.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = licenseURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
            return attribution.isEmpty || url.isEmpty
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// Lookup by catalog id.
    public func entry(id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    /// Any entry that breaks the CC BY 4.0 attribution guarantee. Empty means
    /// the manifest is well formed.
    public var entriesMissingRequiredAttribution: [Entry] {
        entries.filter { $0.isMissingRequiredAttribution }
    }

    /// Decode a manifest from the JSON the generator script reads (its `voices`
    /// array). Used by tests to bind the shipped Swift manifest to the on-disk
    /// JSON so the two cannot drift.
    public static func parse(_ data: Data) throws -> PremiumVoiceLicenseManifest {
        try JSONDecoder().decode(PremiumVoiceLicenseManifest.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// The pinned manifest. Exactly one entry: "azelma". Adding a voice here is
    /// the only place a new attribution is introduced.
    public static let shipped = PremiumVoiceLicenseManifest(entries: [
        Entry(
            id: "azelma",
            displayName: "Azelma",
            sourceDescription: "Derived from the VCTK Corpus (speaker p303), CSTR, University of Edinburgh.",
            license: .ccBy4,
            attributionText: "Derived from the VCTK Corpus (speaker p303), CSTR, University of Edinburgh, licensed under CC BY 4.0. Voice embedding by Kyutai. Modified for use as an on-device synthesis voice.",
            licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")!
        )
    ])
}
