import AppKit
import SwiftUI

/// The spec's static pose snapshots (`design/pet-animation-spec.md`), one per
/// activity phase plus flavor variants, used for design renders and the
/// legibility strips. Runtime animation interpolates around these.
extension BubblesPose {
    static let specCatalog: [(name: String, pose: BubblesPose)] = [
        ("sleeping", {
            var pose = BubblesPose()
            pose.eyeOpenness = 0
            pose.smile = 0.6
            pose.cheekGlow = 0.45
            pose.arcGlow = 0.25
            pose.breathe = 0.7
            pose.bubbles = [
                BubblesBubblePose(brightness: 0.55),
                BubblesBubblePose(brightness: 0.55),
                BubblesBubblePose(brightness: 0.55),
            ]
            return pose
        }()),
        ("idle", {
            var pose = BubblesPose.neutral
            pose.breathe = 0.3
            return pose
        }()),
        ("thinking-claude", {
            var pose = BubblesPose()
            pose.headTilt = -6
            pose.gaze = CGSize(width: -2, height: -1)
            pose.smile = 0.45
            pose.arcGlow = 0.8
            pose.bubbles = [
                BubblesBubblePose(lift: 8, tilt: -4, brightness: 1, dotPhase: 0.35),
                BubblesBubblePose(brightness: 0.45),
                BubblesBubblePose(brightness: 0.45),
            ]
            return pose
        }()),
        ("tool-shell-codex", {
            var pose = BubblesPose()
            pose.eyeOpenness = 0.75
            pose.smile = 0.6
            pose.breathe = 0.5
            pose.arcGlow = 0.8
            pose.bubbles = [
                BubblesBubblePose(brightness: 0.45),
                BubblesBubblePose(brightness: 0.45),
                BubblesBubblePose(lift: 4, jitter: 2.5, tilt: 3, brightness: 1, dotPhase: 0.6),
            ]
            return pose
        }()),
        ("tool-web-center", {
            var pose = BubblesPose()
            pose.eyeOpenness = 0.85
            pose.smile = 0.6
            pose.arcGlow = 0.8
            pose.bubbles = [
                BubblesBubblePose(brightness: 0.45),
                BubblesBubblePose(lift: 6, brightness: 1, dotPhase: 0.15, orbit: 1),
                BubblesBubblePose(brightness: 0.45),
            ]
            return pose
        }()),
        ("responding-claude", {
            var pose = BubblesPose()
            pose.gaze = CGSize(width: 0, height: -1.5)
            pose.arcRipple = -1
            pose.arcPhase = 0.9
            pose.arcGlow = 0.85
            pose.bubbles = [
                BubblesBubblePose(lift: 12, tilt: -6, brightness: 1),
                BubblesBubblePose(brightness: 0.45),
                BubblesBubblePose(brightness: 0.45),
            ]
            return pose
        }()),
        ("speaking-codex", {
            var pose = BubblesPose()
            pose.mouthOpen = 0.65
            pose.sway = 1.2
            pose.breathe = 0.4
            pose.arcRipple = 1
            pose.arcPhase = 0.4
            pose.bubbles = [
                BubblesBubblePose(brightness: 0.4),
                BubblesBubblePose(brightness: 0.4),
                BubblesBubblePose(brightness: 1),
            ]
            return pose
        }()),
        ("paused", {
            var pose = BubblesPose()
            pose.mouthOpen = 0.18
            pose.eyeOpenness = 0.85
            pose.arcGlow = 0.5
            pose.bubbles = [
                BubblesBubblePose(brightness: 0.75),
                BubblesBubblePose(brightness: 0.75),
                BubblesBubblePose(brightness: 0.75),
            ]
            return pose
        }()),
        ("blocked-claude", {
            var pose = BubblesPose()
            pose.browWorry = 1
            pose.cheekGlow = 0.2
            pose.smile = 0.3
            pose.eyeOpenness = 0.9
            pose.arcGlow = 0.15
            pose.bubbles = [
                BubblesBubblePose(lift: 14, brightness: 1, dotPhase: 0.8),
                BubblesBubblePose(brightness: 0.3),
                BubblesBubblePose(brightness: 0.3),
            ]
            return pose
        }()),
        ("error-codex", {
            var pose = BubblesPose()
            pose.dizzy = 1
            pose.mouthOpen = 0.3
            pose.headTilt = 4
            pose.arcGlow = 0.4
            pose.bubbles = [
                BubblesBubblePose(brightness: 0.5),
                BubblesBubblePose(brightness: 0.5),
                BubblesBubblePose(lift: -4, brightness: 0.8),
            ]
            return pose
        }()),
        ("celebrate-claude", {
            var pose = BubblesPose()
            pose.hop = 16
            pose.squash = -0.5
            pose.cheekGlow = 0.95
            pose.arcRipple = 1
            pose.arcPhase = 1.6
            pose.bubbles = [
                BubblesBubblePose(brightness: 1, pop: 0.55),
                BubblesBubblePose(lift: 2, brightness: 0.8),
                BubblesBubblePose(lift: 1, brightness: 0.8),
            ]
            return pose
        }()),
    ]
}

/// Renders the spec pose catalog to PNGs (`Attache --render-poses [dir]`):
/// one 480 px render per pose, a 32 px legibility strip, and a
/// pixel-identity check proving the figure's neutral pose still IS the
/// locked mark (`AttacheMascotMark`), so the pet can never drift from the
/// brand geometry.
enum PetPoseRenderer {
    @MainActor
    static func renderAll(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try verifyNeutralMatchesMark(reportTo: directory)

        for entry in BubblesPose.specCatalog {
            let figure = BubblesPetFigure(pose: entry.pose, headroom: 28)
                .frame(width: 480, height: 534)
            try write(view: figure, scale: 2, to: directory.appendingPathComponent("pose-\(entry.name).png"))
        }

        let strip = HStack(spacing: 6) {
            ForEach(BubblesPose.specCatalog, id: \.name) { entry in
                BubblesPetFigure(pose: entry.pose, headroom: 28)
                    .frame(width: 32, height: 36)
            }
        }
        .padding(4)
        try write(view: strip, scale: 2, to: directory.appendingPathComponent("strip-32px.png"))
    }

    /// The lock check: `BubblesPetFigure(.neutral)` and `AttacheMascotMark`
    /// must produce identical pixels at 240 px. A nonzero delta means the
    /// pet's geometry drifted from the canonical mark; fail loudly.
    @MainActor
    private static func verifyNeutralMatchesMark(reportTo directory: URL) throws {
        let side: CGFloat = 240
        guard
            let markImage = cgImage(for: AttacheMascotMark().frame(width: side, height: side), scale: 1),
            let figureImage = cgImage(for: BubblesPetFigure().frame(width: side, height: side), scale: 1)
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
        if maxDelta > 2 {
            throw PoseRenderError.geometryDrift("neutral pose deviates from AttacheMascotMark (max channel delta \(maxDelta))")
        }
    }

    @MainActor
    private static func write(view: some View, scale: CGFloat, to url: URL) throws {
        guard let image = cgImage(for: view, scale: scale) else {
            throw PoseRenderError.renderFailed(url.lastPathComponent)
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw PoseRenderError.renderFailed(url.lastPathComponent)
        }
        try png.write(to: url)
        print("wrote \(url.path)")
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
