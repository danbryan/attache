import Foundation

/// The manifest for a "bring your own presence" custom-artwork package
/// (`<name>.attache-character/manifest.json`). See `docs/byo-presence.md`.
///
/// Pure and `Codable` so package validation and frame selection are
/// unit-testable without AppKit or a real image on disk. The App-side renderer
/// maps an `AttachePose` into `AtlasFaceState` and asks `AttacheCharacterAtlas`
/// which frame to draw.
public struct AttacheCharacterManifest: Codable, Equatable, Sendable {
    /// Manifest format version. 1 = the five-frame expression set; 2 adds the
    /// optional `gaze` and `visemes` arrays. A reader of a higher format must
    /// read a lower one, and unknown keys are ignored so the format can grow.
    public var format: Int
    public var name: String
    /// Canvas edge in design units; every frame is a transparent square of this
    /// size (`requiredCanvas`).
    public var canvas: Int
    /// The silhouette safe-area box inside the canvas (`requiredSafeArea`).
    public var safeArea: Int
    /// Named expression frames, relative paths within the package. Only
    /// `neutralKey` is required; any other may be absent and degrades to neutral.
    public var frames: [String: String]
    /// Optional gaze grid (format >= 2). Each entry is a normalized eye/face
    /// offset in [-1, 1] per axis.
    public var gaze: [GazeFrame]?
    /// Optional mouth-open levels (format >= 2), each keyed by openness in [0, 1].
    public var visemes: [VisemeFrame]?
    /// Optional eye anchors (format >= 3). A still photo can't move its own
    /// eyes, so the renderer draws procedural eyes over these positions to get
    /// continuous gaze, blink, worry, and error. Positions/sizes are normalized
    /// to the canvas [0, 1]. See docs/byo-presence.md.
    public var eyes: EyeAnchors?

    public struct EyeAnchors: Codable, Equatable, Sendable {
        public struct Eye: Codable, Equatable, Sendable {
            public var x: Double
            public var y: Double
            public var w: Double
            public var h: Double
            public init(x: Double, y: Double, w: Double, h: Double) {
                self.x = x; self.y = y; self.w = w; self.h = h
            }
        }
        /// The image-left eye (the subject's right) and image-right eye.
        public var left: Eye
        public var right: Eye
        /// Sampled iris color, linear RGB in [0, 1].
        public var irisColor: [Double]
        /// Sampled skin tone near the eye, used to paint over the real eye when
        /// the synthetic eye is closed (asleep/blink). Optional for back-compat.
        public var skinColor: [Double]?
        public init(left: Eye, right: Eye, irisColor: [Double], skinColor: [Double]? = nil) {
            self.left = left; self.right = right; self.irisColor = irisColor
            self.skinColor = skinColor
        }
    }

    public struct GazeFrame: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var path: String
        public init(x: Double, y: Double, path: String) {
            self.x = x
            self.y = y
            self.path = path
        }
    }

    public struct VisemeFrame: Codable, Equatable, Sendable {
        public var open: Double
        public var path: String
        public init(open: Double, path: String) {
            self.open = open
            self.path = path
        }
    }

    public static let neutralKey = "neutral"
    public static let requiredCanvas = 252
    public static let requiredSafeArea = 240

    public init(
        format: Int = 1,
        name: String,
        canvas: Int = AttacheCharacterManifest.requiredCanvas,
        safeArea: Int = AttacheCharacterManifest.requiredSafeArea,
        frames: [String: String],
        gaze: [GazeFrame]? = nil,
        visemes: [VisemeFrame]? = nil,
        eyes: EyeAnchors? = nil
    ) {
        self.format = format
        self.name = name
        self.canvas = canvas
        self.safeArea = safeArea
        self.frames = frames
        self.gaze = gaze
        self.visemes = visemes
        self.eyes = eyes
    }

    /// The relative path of the always-required neutral frame, if present.
    public var neutralPath: String? { frames[Self.neutralKey] }

    public enum ValidationError: Error, Equatable {
        case missingNeutral
    }

    /// A package is only valid if it has a neutral frame to fall back to; every
    /// other frame is optional (see `AttacheCharacterAtlas`).
    public func validate() throws {
        guard neutralPath != nil else { throw ValidationError.missingNeutral }
    }
}

/// The face fields an atlas renderer selects on, normalized and decoupled from
/// the App's `AttachePose` units. The renderer builds one of these per frame
/// (gaze mapped from ±3 pose units into [-1, 1]) and asks for a frame path.
public struct AtlasFaceState: Equatable, Sendable {
    public var gazeX: Double
    public var gazeY: Double
    public var eyeOpenness: Double
    public var mouthOpen: Double
    public var browWorry: Double
    public var dizzy: Double

    public init(
        gazeX: Double = 0,
        gazeY: Double = 0,
        eyeOpenness: Double = 1,
        mouthOpen: Double = 0,
        browWorry: Double = 0,
        dizzy: Double = 0
    ) {
        self.gazeX = gazeX
        self.gazeY = gazeY
        self.eyeOpenness = eyeOpenness
        self.mouthOpen = mouthOpen
        self.browWorry = browWorry
        self.dizzy = dizzy
    }
}

/// Pure frame selection for a custom-artwork presence. Given a face state and a
/// manifest, returns the relative path of the best available frame, always
/// non-nil (every rule degrades to neutral), so a one-frame package is valid
/// and a partial package simply skips the rules it cannot satisfy. This is the
/// "progressive" property: more frames, finer selection, never a hard failure.
public enum AttacheCharacterAtlas {
    public static let blinkThreshold = 0.15
    public static let mouthThreshold = 0.2
    public static let worryThreshold = 0.4
    public static let dizzyThreshold = 0.5
    /// Below this normalized gaze distance the eyes read as centered, so we
    /// prefer neutral over snapping to a gaze frame.
    public static let gazeCenterDeadzone = 0.25

    /// The relative frame path to draw for `state`. Never nil: falls back to the
    /// neutral frame (or, defensively, any frame the manifest has).
    public static func framePath(
        for state: AtlasFaceState,
        in manifest: AttacheCharacterManifest
    ) -> String {
        let neutral = manifest.neutralPath
            ?? manifest.frames[manifest.frames.keys.sorted().first ?? ""]
            ?? ""

        if state.dizzy > dizzyThreshold, let f = manifest.frames["error"] { return f }
        if state.browWorry > worryThreshold, let f = manifest.frames["worried"] { return f }
        if state.eyeOpenness < blinkThreshold, let f = manifest.frames["blink"] { return f }
        if state.mouthOpen > mouthThreshold {
            if let v = nearestViseme(open: state.mouthOpen, in: manifest) { return v }
            if let f = manifest.frames["speaking"] { return f }
        }
        if let g = nearestGaze(x: state.gazeX, y: state.gazeY, in: manifest) { return g }
        return neutral
    }

    /// Nearest viseme by openness, or nil if the manifest has none.
    public static func nearestViseme(
        open: Double,
        in manifest: AttacheCharacterManifest
    ) -> String? {
        guard let visemes = manifest.visemes, !visemes.isEmpty else { return nil }
        return visemes.min(by: { abs($0.open - open) < abs($1.open - open) })?.path
    }

    /// Nearest gaze frame by Euclidean distance, or nil if the manifest has none
    /// or the gaze is within the center deadzone (prefer neutral there).
    public static func nearestGaze(
        x: Double,
        y: Double,
        in manifest: AttacheCharacterManifest
    ) -> String? {
        guard let gaze = manifest.gaze, !gaze.isEmpty else { return nil }
        guard (x * x + y * y).squareRoot() > gazeCenterDeadzone else { return nil }
        return gaze.min(by: {
            hypot($0.x - x, $0.y - y) < hypot($1.x - x, $1.y - y)
        })?.path
    }
}
