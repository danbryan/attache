import AppKit
import SwiftUI

/// The spec's static pose snapshots (`design/attache-animation-spec.md`), one per
/// activity phase plus flavor variants, used for design renders and the
/// legibility strips. Runtime animation interpolates around these.
extension AttachePose {
    static let specCatalog: [(name: String, pose: AttachePose)] = [
        ("sleeping", {
            var pose = AttachePose()
            pose.eyeOpenness = 0
            pose.smile = 0.6
            pose.cheekGlow = 0.45
            pose.arcGlow = 0.25
            pose.breathe = 0.7
            pose.agentSignals = [
                AgentSignalPose(brightness: 0.55),
                AgentSignalPose(brightness: 0.55),
                AgentSignalPose(brightness: 0.55),
            ]
            return pose
        }()),
        ("idle", {
            var pose = AttachePose.neutral
            pose.breathe = 0.3
            return pose
        }()),
        ("thinking-claude", {
            var pose = AttachePose()
            pose.headTilt = -6
            pose.gaze = CGSize(width: -2, height: -1)
            pose.smile = 0.45
            pose.arcGlow = 0.8
            pose.agentSignals = [
                AgentSignalPose(lift: 8, tilt: -4, brightness: 1, dotPhase: 0.35),
                AgentSignalPose(brightness: 0.45),
                AgentSignalPose(brightness: 0.45),
            ]
            return pose
        }()),
        ("tool-shell-codex", {
            var pose = AttachePose()
            pose.eyeOpenness = 0.75
            pose.smile = 0.6
            pose.breathe = 0.5
            pose.arcGlow = 0.8
            pose.agentSignals = [
                AgentSignalPose(brightness: 0.45),
                AgentSignalPose(brightness: 0.45),
                AgentSignalPose(lift: 4, jitter: 2.5, tilt: 3, brightness: 1, dotPhase: 0.6),
            ]
            return pose
        }()),
        ("tool-web-center", {
            var pose = AttachePose()
            pose.eyeOpenness = 0.85
            pose.smile = 0.6
            pose.arcGlow = 0.8
            pose.agentSignals = [
                AgentSignalPose(brightness: 0.45),
                AgentSignalPose(lift: 6, brightness: 1, dotPhase: 0.15, orbit: 1),
                AgentSignalPose(brightness: 0.45),
            ]
            return pose
        }()),
        ("responding-claude", {
            var pose = AttachePose()
            pose.gaze = CGSize(width: 0, height: -1.5)
            pose.arcRipple = -1
            pose.arcPhase = 0.9
            pose.arcGlow = 0.85
            pose.agentSignals = [
                AgentSignalPose(lift: 12, tilt: -6, brightness: 1),
                AgentSignalPose(brightness: 0.45),
                AgentSignalPose(brightness: 0.45),
            ]
            return pose
        }()),
        ("speaking-codex", {
            var pose = AttachePose()
            pose.mouthOpen = 0.65
            pose.sway = 1.2
            pose.breathe = 0.4
            pose.arcRipple = 1
            pose.arcPhase = 0.4
            pose.agentSignals = [
                AgentSignalPose(brightness: 0.4),
                AgentSignalPose(brightness: 0.4),
                AgentSignalPose(brightness: 1),
            ]
            return pose
        }()),
        ("paused", {
            var pose = AttachePose()
            pose.mouthOpen = 0.18
            pose.eyeOpenness = 0.85
            pose.arcGlow = 0.5
            pose.agentSignals = [
                AgentSignalPose(brightness: 0.75),
                AgentSignalPose(brightness: 0.75),
                AgentSignalPose(brightness: 0.75),
            ]
            return pose
        }()),
        ("blocked-claude", {
            var pose = AttachePose()
            pose.browWorry = 1
            pose.cheekGlow = 0.2
            pose.smile = 0.3
            pose.eyeOpenness = 0.9
            pose.arcGlow = 0.15
            pose.agentSignals = [
                AgentSignalPose(lift: 14, brightness: 1, dotPhase: 0.8),
                AgentSignalPose(brightness: 0.3),
                AgentSignalPose(brightness: 0.3),
            ]
            return pose
        }()),
        ("error-codex", {
            var pose = AttachePose()
            pose.dizzy = 1
            pose.mouthOpen = 0.3
            pose.headTilt = 4
            pose.arcGlow = 0.4
            pose.agentSignals = [
                AgentSignalPose(brightness: 0.5),
                AgentSignalPose(brightness: 0.5),
                AgentSignalPose(lift: -4, brightness: 0.8),
            ]
            return pose
        }()),
        ("celebrate-claude", {
            var pose = AttachePose()
            pose.hop = 16
            pose.squash = -0.5
            pose.cheekGlow = 0.95
            pose.arcRipple = 1
            pose.arcPhase = 1.6
            pose.agentSignals = [
                AgentSignalPose(brightness: 1, pop: 0.55),
                AgentSignalPose(lift: 2, brightness: 0.8),
                AgentSignalPose(lift: 1, brightness: 0.8),
            ]
            return pose
        }()),
    ]
}

/// The marketing pose set (INF-274): expressive Attaché moments for the
/// site, README hero, and promo, rendered from the same rig so they can
/// never drift from the canonical geometry. Hero is deliberately the exact
/// neutral mark: the logo does not change, it just comes alive around it.
extension AttachePose {
    static let brandCatalog: [(name: String, pose: AttachePose)] = [
        ("hero", .neutral),
        ("celebrate", {
            var pose = AttachePose()
            pose.hop = 16
            pose.squash = -0.5
            pose.cheekGlow = 0.95
            pose.arcRipple = 1
            pose.arcPhase = 1.6
            pose.agentSignals = [
                AgentSignalPose(brightness: 1, pop: 0.55),
                AgentSignalPose(lift: 2, brightness: 0.8),
                AgentSignalPose(lift: 1, brightness: 0.8),
            ]
            return pose
        }()),
        ("sleeping", {
            var pose = AttachePose()
            pose.eyeOpenness = 0
            pose.smile = 0.6
            pose.cheekGlow = 0.45
            pose.arcGlow = 0.25
            pose.breathe = 0.7
            pose.agentSignals = [
                AgentSignalPose(brightness: 0.55),
                AgentSignalPose(brightness: 0.55),
                AgentSignalPose(brightness: 0.55),
            ]
            return pose
        }()),
        ("thinking", {
            var pose = AttachePose()
            pose.headTilt = -6
            pose.gaze = CGSize(width: -2, height: -1)
            pose.smile = 0.45
            pose.arcGlow = 0.8
            pose.agentSignals = [
                AgentSignalPose(lift: 8, tilt: -4, brightness: 1, dotPhase: 0.35),
                AgentSignalPose(brightness: 0.45),
                AgentSignalPose(brightness: 0.45),
            ]
            return pose
        }()),
        ("greeting", {
            var pose = AttachePose()
            pose.headTilt = 4
            pose.gaze = CGSize(width: 2, height: -1)
            pose.cheekGlow = 0.75
            pose.agentSignals = [
                AgentSignalPose(brightness: 0.8),
                AgentSignalPose(brightness: 0.8),
                AgentSignalPose(lift: 16, tilt: 12, brightness: 1),
            ]
            return pose
        }()),
    ]
}

/// Renders the spec pose catalog to PNGs (`Attache --render-character-poses [dir]`):
/// one 480 px render per pose, a 32 px legibility strip, and a
/// pixel-identity check proving the figure's neutral pose still IS the
/// locked mark (`AttacheMascotMark`), so the character can never drift from the
/// brand geometry.
enum CharacterPoseRenderer {
    /// Brand exports (INF-274): the five marketing poses at 2048 px into
    /// `design/poses/`, plus a seamless 6.4 s idle hero loop (192 frames,
    /// two full breathing periods with one scripted blink) written as
    /// numbered frames for ffmpeg assembly. Runs the same neutral-vs-mark
    /// pixel check first; the hero still IS the logo.
    @MainActor
    static func renderBrand(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try verifyNeutralMatchesMark(reportTo: directory)

        for entry in AttachePose.brandCatalog {
            let figure = AttacheCharacterFigure(pose: entry.pose, headroom: 28)
                .frame(width: 1024, height: 1139)
            try write(view: figure, scale: 2, to: directory.appendingPathComponent("\(entry.name).png"))
        }

        let framesDirectory = directory.appendingPathComponent("hero-loop-frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        let frameCount = 192
        for frame in 0..<frameCount {
            let t = Double(frame) / 30.0
            var pose = AttachePose.neutral
            pose.breathe = 0.5 + 0.5 * sin(t * 2 * .pi / 3.2 - .pi / 2)
            pose.arcGlow = 0.92 + 0.08 * sin(t * 2 * .pi / 3.2)
            pose.eyeOpenness = blinkOpenness(at: t, blinkStart: 2.5)
            for index in 0..<3 {
                pose.agentSignals[index].lift = CGFloat(1.5 * sin(t * 2 * .pi / 3.2 + Double(index) * 0.9))
            }
            let figure = AttacheCharacterFigure(pose: pose, headroom: 28)
                .frame(width: 480, height: 534)
            try write(
                view: figure,
                scale: 2,
                to: framesDirectory.appendingPathComponent(String(format: "frame-%03d.png", frame)),
                quiet: true
            )
        }
        print("wrote \(frameCount) hero loop frames to \(framesDirectory.path)")
    }

    /// The spec blink (120 ms close, 90 ms hold, 140 ms open) at a fixed
    /// time, so the loop is deterministic and seam-free.
    private static func blinkOpenness(at t: Double, blinkStart: Double) -> Double {
        let phase = t - blinkStart
        if phase < 0 || phase >= 0.35 { return 1 }
        if phase < 0.12 { return 1 - phase / 0.12 }
        if phase < 0.21 { return 0 }
        return (phase - 0.21) / 0.14
    }
    @MainActor
    static func renderAll(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try verifyNeutralMatchesMark(reportTo: directory)

        for entry in AttachePose.specCatalog {
            let figure = AttacheCharacterFigure(pose: entry.pose, headroom: 28)
                .frame(width: 480, height: 534)
            try write(view: figure, scale: 2, to: directory.appendingPathComponent("pose-\(entry.name).png"))
        }

        let strip = HStack(spacing: 6) {
            ForEach(AttachePose.specCatalog, id: \.name) { entry in
                AttacheCharacterFigure(pose: entry.pose, headroom: 28)
                    .frame(width: 32, height: 36)
            }
        }
        .padding(4)
        try write(view: strip, scale: 2, to: directory.appendingPathComponent("strip-32px.png"))
    }

    /// Offline preview of a custom "bring your own presence" package: renders
    /// the live `.head` composition (crown + fleet-less head) at a few poses so
    /// placement and appearance can be checked without launching the app. No
    /// geometry lock (that binds only the robot). See docs/byo-presence.md.
    @MainActor
    static func renderCustomPresence(packageURL: URL, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let artwork = AttacheCustomPresenceStore.load(packageURL) else {
            throw PoseRenderError.renderFailed("could not load package \(packageURL.lastPathComponent)")
        }

        func pose(_ build: (inout AttachePose) -> Void) -> AttachePose {
            var p = AttachePose.neutral
            build(&p)
            return p
        }
        // gaze.height is positive-down, so up = negative.
        let poses: [(String, AttachePose, AttacheCharacterAnatomy)] = [
            ("neutral", .neutral, .head),
            ("gaze-left", pose { $0.gaze = CGSize(width: -3, height: 0) }, .head),
            ("gaze-right", pose { $0.gaze = CGSize(width: 3, height: 0) }, .head),
            ("gaze-up", pose { $0.gaze = CGSize(width: 0, height: -3) }, .head),
            ("gaze-down", pose { $0.gaze = CGSize(width: 0, height: 3) }, .head),
            ("gaze-upleft", pose { $0.gaze = CGSize(width: -2.2, height: -2.2) }, .head),
            ("half", pose { $0.eyeOpenness = 0.5 }, .head),
            ("blink", pose { $0.eyeOpenness = 0.06 }, .head),
            // Sleeping with gaze set: the eyes must stay closed and NOT track.
            ("sleep", pose { $0.overhead = .sleeping; $0.eyeOpenness = 0; $0.gaze = CGSize(width: 3, height: -1) }, .head),
            ("error", pose { $0.dizzy = 1 }, .head),
            ("mouth-mid", pose { $0.mouthOpen = 0.4 }, .head),
            ("speaking", pose { $0.mouthOpen = 0.7; $0.sway = 4 }, .head),
            ("mouth-wide", pose { $0.mouthOpen = 1.0 }, .head),
        ]
        for (name, pose, anatomy) in poses {
            let figure = AttacheCharacterFigure(
                pose: pose,
                headroom: anatomy == .full ? 28 : 0,
                anatomy: anatomy,
                character: .customAtlas,
                customArtwork: artwork
            )
            .frame(width: 480, height: 534)
            try write(view: figure, scale: 2, to: directory.appendingPathComponent("custom-\(name).png"))
        }

        // The robot at the same .head composition, for a direct size/placement
        // comparison while tuning the custom presence.
        let robot = AttacheCharacterFigure(pose: .neutral, anatomy: .head, character: .robot)
            .frame(width: 480, height: 534)
        try write(view: robot, scale: 2, to: directory.appendingPathComponent("robot-neutral-head.png"))
        print("wrote custom presence previews to \(directory.path)")
    }

    /// The lock check: `AttacheCharacterFigure(.neutral)` and `AttacheMascotMark`
    /// must produce identical pixels at 240 px. A nonzero delta means the
    /// character's geometry drifted from the canonical mark; fail loudly.
    @MainActor
    private static func verifyNeutralMatchesMark(reportTo directory: URL) throws {
        let side: CGFloat = 240
        guard
            let markImage = cgImage(for: AttacheMascotMark().frame(width: side, height: side), scale: 1),
            let figureImage = cgImage(for: AttacheCharacterFigure().frame(width: side, height: side), scale: 1)
        else {
            throw PoseRenderError.renderFailed("neutral comparison render")
        }
        let markPixels = rgbaBytes(markImage)
        let figurePixels = rgbaBytes(figureImage)
        guard markPixels.count == figurePixels.count else {
            throw PoseRenderError.geometryDrift("pixel buffers differ in size")
        }
        var maxDelta = 0
        for index in markPixels.indices {
            maxDelta = max(maxDelta, abs(Int(markPixels[index]) - Int(figurePixels[index])))
        }
        print("neutral-vs-mark max channel delta: \(maxDelta)")
        if maxDelta != 0 {
            throw PoseRenderError.geometryDrift("neutral pose differs from the mark by \(maxDelta) channel values")
        }
    }

    @MainActor
    private static func write(view: some View, scale: CGFloat, to url: URL, quiet: Bool = false) throws {
        guard let image = cgImage(for: view, scale: scale) else {
            throw PoseRenderError.renderFailed(url.lastPathComponent)
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw PoseRenderError.renderFailed(url.lastPathComponent)
        }
        try png.write(to: url)
        if !quiet {
            print("wrote \(url.path)")
        }
    }

    @MainActor
    private static func cgImage(for view: some View, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.cgImage
    }

    private static func rgbaBytes(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return []
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    enum PoseRenderError: Error, CustomStringConvertible {
        case renderFailed(String)
        case geometryDrift(String)

        var description: String {
            switch self {
            case .renderFailed(let what): return "could not render \(what)"
            case .geometryDrift(let why): return "geometry drift: \(why)"
            }
        }
    }
}
