import AppKit

// A fox: an INVERTED-TRIANGLE face (wide brow with tall pointed ears, narrowing
// to a pointed chin) to prove the bring-your-own-presence framework is shape
// agnostic. Eyes and mouth are placed by explicit anchors, not derived from the
// silhouette, so a pointed head works the same as the round panda / square robot.
// The narrow muzzle is the real test: the shared equalizer mouth just uses a
// smaller mouth anchor. Eye areas are left blank white; the engine adds pupils.
let canvas = 252
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
func Y(_ y: CGFloat) -> CGFloat { CGFloat(canvas) - y }
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: Y(y)) }
func fill(_ pts: [CGPoint], _ color: NSColor, close: Bool = true) {
    let path = CGMutablePath()
    path.move(to: pts[0]); for p in pts.dropFirst() { path.addLine(to: p) }
    if close { path.closeSubpath() }
    ctx.setFillColor(color.cgColor); ctx.addPath(path); ctx.fillPath()
}
func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: NSColor) {
    ctx.setFillColor(color.cgColor)
    ctx.fillEllipse(in: CGRect(x: cx - rx, y: Y(cy) - ry, width: rx * 2, height: ry * 2))
}
let orange = NSColor(red: 0.90, green: 0.45, blue: 0.20, alpha: 1)
let darkOrange = NSColor(red: 0.72, green: 0.33, blue: 0.14, alpha: 1)
let white = NSColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)
let black = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)

// --- Ears (behind head): clean triangles pointing up-and-out ---
fill([P(56, 128), P(104, 120), P(70, 58)], orange)       // left ear
fill([P(196, 128), P(148, 120), P(182, 58)], orange)     // right ear
fill([P(70, 116), P(98, 112), P(78, 72)], darkOrange)    // left inner
fill([P(182, 116), P(154, 112), P(174, 72)], darkOrange) // right inner
fill([P(70, 58), P(60, 84), P(80, 82)], black)           // left tip
fill([P(182, 58), P(192, 84), P(172, 82)], black)        // right tip

// --- Head: clean rounded inverted triangle (wide brow -> pointed chin) ---
let head = CGMutablePath()
head.move(to: P(58, 126))
head.addQuadCurve(to: P(194, 126), control: P(126, 122)) // gently bowed brow
head.addQuadCurve(to: P(126, 220), control: P(190, 168)) // right side -> chin
head.addQuadCurve(to: P(58, 126), control: P(62, 168))   // chin -> left side
head.closeSubpath()
ctx.setFillColor(orange.cgColor); ctx.addPath(head); ctx.fillPath()

// --- Eyes: blank white almond areas on the orange (engine adds pupils) ---
ellipse(101, 150, 13, 11, white)
ellipse(151, 150, 13, 11, white)

// --- White muzzle: a small rounded diamond low on the face, below the eyes ---
let muzzle = CGMutablePath()
muzzle.move(to: P(126, 168))
muzzle.addQuadCurve(to: P(150, 190), control: P(148, 172)) // right shoulder
muzzle.addQuadCurve(to: P(126, 214), control: P(142, 206)) // -> chin point
muzzle.addQuadCurve(to: P(102, 190), control: P(110, 206))
muzzle.addQuadCurve(to: P(126, 168), control: P(104, 172)) // -> top
muzzle.closeSubpath()
ctx.setFillColor(white.cgColor); ctx.addPath(muzzle); ctx.fillPath()

// --- Nose: black rounded triangle at the top of the muzzle ---
let nose = CGMutablePath()
nose.move(to: P(126, 172))
nose.addLine(to: P(135, 182))
nose.addQuadCurve(to: P(117, 182), control: P(126, 188))
nose.closeSubpath()
ctx.setFillColor(black.cgColor); ctx.addPath(nose); ctx.fillPath()

let outCG = ctx.makeImage()!
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let framesDir = "\(outDir)/frames"
try? FileManager.default.createDirectory(atPath: framesDir, withIntermediateDirectories: true)
let rep = NSBitmapImageRep(cgImage: outCG)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(framesDir)/neutral.png"))
print("wrote \(framesDir)/neutral.png")
