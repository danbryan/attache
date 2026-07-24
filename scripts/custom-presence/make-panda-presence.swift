import AppKit

// Draw a clean panda face on a 252x252 transparent canvas: white face, black
// ears + eye patches with WHITE eye areas (no pupils - the engine adds movable
// pupils), a nose, and a clear mouth area for the shared equalizer. This is a
// hand-authored example presence for the bring-your-own-presence framework.
let canvas = 252
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
// CoreGraphics is bottom-left origin; author in top-left "design" coords and flip.
func Y(_ y: CGFloat) -> CGFloat { CGFloat(canvas) - y }
func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: NSColor) {
    ctx.setFillColor(color.cgColor)
    ctx.fillEllipse(in: CGRect(x: cx - rx, y: Y(cy) - ry, width: rx * 2, height: ry * 2))
}
let black = NSColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1)
let white = NSColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)
let pink = NSColor(red: 0.96, green: 0.72, blue: 0.74, alpha: 1)

// Ears (behind the face).
ellipse(74, 96, 30, 30, black)
ellipse(178, 96, 30, 30, black)
ellipse(74, 96, 15, 15, NSColor(red: 0.32, green: 0.24, blue: 0.26, alpha: 1))
ellipse(178, 96, 15, 15, NSColor(red: 0.32, green: 0.24, blue: 0.26, alpha: 1))
// Face.
ellipse(126, 156, 80, 74, white)
// Cheeks.
ellipse(84, 182, 15, 11, pink)
ellipse(168, 182, 15, 11, pink)
// Eye patches (black), angled slightly inward toward the nose.
func patch(_ cx: CGFloat, _ cy: CGFloat, _ angle: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: cx, y: Y(cy)); ctx.rotate(by: angle); ctx.translateBy(x: -cx, y: -Y(cy))
    ctx.setFillColor(black.cgColor)
    ctx.fillEllipse(in: CGRect(x: cx - 22, y: Y(cy) - 27, width: 44, height: 54))
    ctx.restoreGState()
}
patch(101, 150, 0.32)
patch(151, 150, -0.32)
// Eye whites (the engine draws movable pupils on top of these; leave them BLANK).
ellipse(104, 152, 15, 15, white)
ellipse(148, 152, 15, 15, white)
// Nose.
ctx.setFillColor(black.cgColor)
let nose = CGMutablePath()
nose.addRoundedRect(in: CGRect(x: 126 - 12, y: Y(180) - 8, width: 24, height: 16), cornerWidth: 7, cornerHeight: 7)
ctx.addPath(nose); ctx.fillPath()
// Leave the muzzle below the nose blank white: the engine draws the shared
// equalizer mouth (navy bars) there, the same mouth the robot uses.

let outCG = ctx.makeImage()!
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let framesDir = "\(outDir)/frames"
try? FileManager.default.createDirectory(atPath: framesDir, withIntermediateDirectories: true)
let rep = NSBitmapImageRep(cgImage: outCG)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(framesDir)/neutral.png"))
print("wrote \(framesDir)/neutral.png")
