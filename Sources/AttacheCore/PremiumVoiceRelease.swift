import Foundation

/// The pinned descriptor for the Attaché Premium voice weights bundle: where to
/// download it, how to verify it, its version, and how much space it needs
/// unpacked. Pure and Codable so the download state machine and its tests never
/// touch the network. The download URL and checksum here are PLACEHOLDERS; the
/// release orchestrator uploads the real `premium-voice-int8.tar.gz`
/// (scripts/package-premium-voice-weights.sh) and pastes its sha256 + unpacked
/// size before shipping.
public struct PremiumVoiceRelease: Equatable, Codable, Sendable {

    /// Sentinel used until the real asset is uploaded. `isChecksumPlaceholder`
    /// keys off it so the download path fails closed rather than "verifying"
    /// against a fake digest.
    public static let checksumPlaceholder = "PLACEHOLDER_SHA256_REPLACE_AT_RELEASE"

    public let version: String
    public let bundleURL: URL
    public let sha256: String
    public let unpackedSizeBytes: Int64
    /// Size of the compressed download itself (the tarball), used for the
    /// consent copy and the "189 MB download" row suffix. Optional so older
    /// manifests that only carried the unpacked size still decode; the UI falls
    /// back to `unpackedSizeBytes` when this is absent.
    public let downloadSizeBytes: Int64?
    /// Human-facing description of what the tarball unpacks to, for provenance
    /// and so the UI can explain the download.
    public let contents: [String]

    public init(
        version: String,
        bundleURL: URL,
        sha256: String,
        unpackedSizeBytes: Int64,
        downloadSizeBytes: Int64? = nil,
        contents: [String]
    ) {
        self.version = version
        self.bundleURL = bundleURL
        self.sha256 = sha256
        self.unpackedSizeBytes = unpackedSizeBytes
        self.downloadSizeBytes = downloadSizeBytes
        self.contents = contents
    }

    /// The download size in bytes, falling back to the unpacked size when the
    /// manifest did not carry a distinct compressed size.
    public var effectiveDownloadSizeBytes: Int64 {
        downloadSizeBytes ?? unpackedSizeBytes
    }

    /// Short human-facing download size, e.g. "189 MB", for the row suffix and
    /// consent copy.
    public var downloadSizeDescription: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB]
        formatter.includesActualByteCount = false
        return formatter.string(fromByteCount: effectiveDownloadSizeBytes)
    }

    /// True while the checksum is still the placeholder sentinel. The manager
    /// refuses to install a placeholder-checksum download so a mis-shipped build
    /// cannot install unverified bytes.
    public var isChecksumPlaceholder: Bool {
        Self.normalizedSHA256(sha256) == nil
    }

    /// Lowercased 64-hex form of the checksum, or nil if it is not a real
    /// sha256 (placeholder, wrong length, or non-hex).
    public var normalizedSHA256: String? {
        Self.normalizedSHA256(sha256)
    }

    public static func normalizedSHA256(_ raw: String) -> String? {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lowered.count == 64 else { return nil }
        let hex = Set("0123456789abcdef")
        guard lowered.allSatisfy({ hex.contains($0) }) else { return nil }
        return lowered
    }

    /// Decode a descriptor from JSON (used by tests and any future remote
    /// manifest). Invalid JSON throws; a placeholder/invalid checksum is allowed
    /// through here and rejected later at install time.
    public static func parse(_ data: Data) throws -> PremiumVoiceRelease {
        try JSONDecoder().decode(PremiumVoiceRelease.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// The current pinned release: the premium-voice-v1 GitHub release asset,
    /// built by scripts/package-premium-voice-weights.sh from the pinned INT8
    /// export. Sizes are the measured tarball and unpacked footprints.
    public static let pinned = PremiumVoiceRelease(
        version: "v1",
        bundleURL: URL(string: "https://github.com/danbryan/attache/releases/download/premium-voice-v1/premium-voice-int8.tar.gz")!,
        sha256: "63c0c620bf80a82f1df31cc017d048fff331fc4762ada2c121c45a2a67031a5c",
        unpackedSizeBytes: 203_011_198,
        downloadSizeBytes: 113_179_974,
        contents: [
            "models/flow_lm_main_int8.onnx",
            "models/flow_lm_flow_int8.onnx",
            "models/mimi_decoder_int8.onnx",
            "models/mimi_encoder.onnx",
            "models/text_conditioner.onnx",
            "models/tokenizer.model",
            "voices/azelma.wav",
            "voices/.cache/azelma.emb",
            "voices/.cache/azelma.kv",
            "config/b6369a24.yaml"
        ]
    )
}
