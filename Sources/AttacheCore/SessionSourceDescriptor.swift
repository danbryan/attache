import Foundation

/// A single registered agent source: the directories its live watcher polls,
/// the transcript format its lines parse as, and the metadata needed to build
/// a `SessionScanner` for background indexing. Before this type existed, the
/// live watchers (`CodexSessionWatcher`, `SessionActivityWatcher`) and the
/// indexer/toggle wiring (`SessionIndexer`, `AppModel`) each hardcoded a
/// binary claude-or-codex branch; this makes source registration data so a
/// third source is a new descriptor, not a new `if`/ternary at every call site
/// (INF-360).
///
/// `watchedDirectories` is a closure, not a stored `[URL]`, so a caller that
/// wants environment overrides honored (`CODEX_HOME`, `CLAUDE_CONFIG_DIR`)
/// re-resolves them on every call instead of freezing a value captured once at
/// registry construction time.
public struct SessionSourceDescriptor {
    public let sourceKind: SourceKind
    /// Nil for a source with no line/text transcript shape `TranscriptParser`
    /// can parse (opencode, INF-362: SQLite rows, not JSONL lines). Reading
    /// this as nil is exactly `TwoWayCoordinator.transcriptFormat(for:)`'s
    /// "no delivery adapter, fail closed" signal, the same outcome Grok
    /// Build reaches via having no `InstructionDeliveryAdapter` registered;
    /// opencode reaches it one layer earlier because there is no format to
    /// even attempt correlation or readiness classification against.
    public let transcriptFormat: TranscriptFormat?
    public let watchedDirectories: () -> [URL]
    /// Whether a file found under one of `watchedDirectories` belongs to this
    /// source. Both production sources currently just check the extension;
    /// a future source with a different on-disk shape can narrow this.
    public let fileMatch: (URL) -> Bool
    /// The `event.metadata["adapter"]` tag this source's watcher-emitted
    /// events carry. Kept explicit (not derived from `sourceKind.rawValue`,
    /// which would change `claude_code-session-file` to a new literal) so the
    /// existing "codex-session-file" / "claude-session-file" values stay
    /// byte-identical.
    public let adapterTag: String
    /// Builds the `SessionScanner` background indexing uses for this source.
    public let makeScanner: () -> SessionScanner

    public var displayName: String { sourceKind.displayName }
    public var shortLabel: String { sourceKind.shortLabel }

    public init(
        sourceKind: SourceKind,
        transcriptFormat: TranscriptFormat?,
        watchedDirectories: @escaping () -> [URL],
        adapterTag: String,
        makeScanner: @escaping () -> SessionScanner,
        fileMatch: @escaping (URL) -> Bool = { $0.pathExtension == "jsonl" }
    ) {
        self.sourceKind = sourceKind
        self.transcriptFormat = transcriptFormat
        self.watchedDirectories = watchedDirectories
        self.fileMatch = fileMatch
        self.adapterTag = adapterTag
        self.makeScanner = makeScanner
    }
}

/// The set of registered session sources. Production holds exactly Codex and
/// Claude Code (no new `SourceKind` cases in INF-360); tests build their own
/// registry, including a synthetic descriptor, to prove that classification,
/// format selection, and directory watching are purely data-driven rather
/// than special-cased in the watchers.
public final class SessionSourceRegistry {
    public let descriptors: [SessionSourceDescriptor]

    public init(descriptors: [SessionSourceDescriptor]) {
        self.descriptors = descriptors
    }

    /// Codex + Claude Code, built from the same `CodexPaths`/`ClaudePaths`
    /// helpers the watchers and scanners used directly before this registry
    /// existed. The optional overrides let a live watcher pass its own
    /// explicit directories (as its `init` already accepted) while
    /// `makeScanner` still resolves the real, environment-aware home: scanner
    /// construction and live-watch directory overrides were always separate
    /// concerns and stay that way here.
    public static func production(
        codexSessionsDirectory: URL? = nil,
        codexArchivedSessionsDirectory: URL? = nil,
        claudeProjectsDirectory: URL? = nil,
        grokSessionsDirectory: URL? = nil,
        opencodeDataDirectory: URL? = nil
    ) -> SessionSourceRegistry {
        SessionSourceRegistry(descriptors: [
            SessionSourceDescriptor(
                sourceKind: .codex,
                transcriptFormat: .codex,
                watchedDirectories: {
                    let home = CodexPaths.home()
                    return [
                        codexSessionsDirectory ?? home.appendingPathComponent("sessions", isDirectory: true),
                        codexArchivedSessionsDirectory ?? home.appendingPathComponent("archived_sessions", isDirectory: true)
                    ]
                },
                adapterTag: "codex-session-file",
                makeScanner: { CodexSessionScanner() }
            ),
            SessionSourceDescriptor(
                sourceKind: .claudeCode,
                transcriptFormat: .claude,
                watchedDirectories: {
                    [claudeProjectsDirectory ?? ClaudePaths.projectsDirectory()]
                },
                adapterTag: "claude-session-file",
                makeScanner: { ClaudeCodeSessionScanner() }
            ),
            // Grok Build (INF-361): watching/indexing/narration only. No
            // `InstructionDeliveryAdapter` is registered for `grok_build` in
            // `TwoWayCoordinator`, so two-way delivery fails closed with "No
            // delivery adapter for grok_build" (InstructionReplyEngine's
            // existing fail-safe) rather than a silent send.
            SessionSourceDescriptor(
                sourceKind: .grokBuild,
                transcriptFormat: .grokBuild,
                watchedDirectories: {
                    [grokSessionsDirectory ?? GrokPaths.sessionsDirectory()]
                },
                adapterTag: "grok-build-session-file",
                makeScanner: { GrokBuildSessionScanner() }
            ),
            // opencode (INF-362): watching/indexing/narration only. Sessions
            // live as rows in one shared SQLite database, not one file per
            // session, so `transcriptFormat` is nil here (see the field's
            // doc comment) rather than a JSONL-oriented case: there is no
            // line/text shape for `TranscriptParser` to parse, which is
            // exactly the signal `TwoWayCoordinator.transcriptFormat(for:)`
            // needs to fail Tell Agent closed instead of attempting
            // correlation or readiness classification against SQL rows.
            SessionSourceDescriptor(
                sourceKind: .opencode,
                transcriptFormat: nil,
                watchedDirectories: {
                    [opencodeDataDirectory ?? OpencodePaths.dataHome()]
                },
                adapterTag: "opencode-session-db",
                makeScanner: { OpencodeSessionScanner() },
                fileMatch: { $0.lastPathComponent == "opencode.db" }
            )
        ])
    }

    public func descriptor(for sourceKind: SourceKind) -> SessionSourceDescriptor? {
        descriptors.first { $0.sourceKind == sourceKind }
    }

    /// Every watched directory across every descriptor, deduplicated by
    /// standardized path, for building a live watcher's file-search set.
    public func allWatchedDirectories() -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for descriptor in descriptors {
            for url in descriptor.watchedDirectories() {
                let key = url.standardizedFileURL.path
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(url)
            }
        }
        return result
    }

    /// Classify a file by the longest matching watched-directory prefix, with
    /// both sides symlink-resolved so a `/tmp` vs `/private/tmp` asymmetry
    /// never causes a false negative (INF-261). Returns nil when no
    /// descriptor's directory contains the file; callers decide the fallback.
    public func classify(fileURL: URL) -> SourceKind? {
        let resolvedFile = fileURL.resolvingSymlinksInPath().path
        var best: (kind: SourceKind, length: Int)?
        for descriptor in descriptors {
            for directory in descriptor.watchedDirectories() {
                let resolvedDirectory = directory.resolvingSymlinksInPath().path
                guard resolvedFile.hasPrefix(resolvedDirectory) else { continue }
                if best == nil || resolvedDirectory.count > best!.length {
                    best = (descriptor.sourceKind, resolvedDirectory.count)
                }
            }
        }
        return best?.kind
    }

    /// The transcript format registered for a source kind, or nil for an
    /// unregistered kind. Two-way delivery's fail-safe (refuse to deliver to
    /// an unrecognized source) is unchanged: it just reads this instead of
    /// switching on `SourceKind` directly.
    public func transcriptFormat(for sourceKind: SourceKind) -> TranscriptFormat? {
        descriptor(for: sourceKind)?.transcriptFormat
    }

    /// The `event.metadata["adapter"]` tag for a source kind, or nil for an
    /// unregistered kind.
    public func adapterTag(for sourceKind: SourceKind) -> String? {
        descriptor(for: sourceKind)?.adapterTag
    }
}
