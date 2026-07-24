import AppKit
import Vision
import CoreImage

// Build a custom-presence package from a photo: background-removed neutral frame
// fit to the 252 canvas, PLUS detected eye anchors (in 252-canvas normalized
// coords) and a sampled iris color, written into manifest.json so the renderer
// can overdraw procedural eyes. Usage: make-presence2 <in> <outDir> <name>
let args = CommandLine.arguments
guard args.count >= 4 else { fputs("usage: make-presence2 <in> <outDir> <name>\n", stderr); exit(2) }
let inPath = args[1], outDir = args[2], name = args[3]
let canvas = 252, safeTop = 40
let targetMax: CGFloat = 208

guard let nsimg = NSImage(contentsOfFile: inPath),
      let cg = nsimg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("cannot load image\n", stderr); exit(1)
}
let W = cg.width, H = cg.height
let ci = CIImage(cgImage: cg)

// --- eye landmarks (photo pixels, top-down) ---
let lmReq = VNDetectFaceLandmarksRequest()
try VNImageRequestHandler(cgImage: cg, options: [:]).perform([lmReq])
guard let face = (lmReq.results?.first as? VNFaceObservation), let lm = face.landmarks else {
    fputs("no landmarks\n", stderr); exit(1)
}
func pts(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] {
    guard let r else { return [] }
    let bb = face.boundingBox
    return r.normalizedPoints.map { CGPoint(x: (bb.origin.x + $0.x*bb.size.width)*CGFloat(W),
                                            y: (1 - (bb.origin.y + $0.y*bb.size.height))*CGFloat(H)) }
}
func box(_ ps: [CGPoint]) -> CGRect {
    guard let f = ps.first else { return .zero }
    var a = f, b = f
    for p in ps { a.x=min(a.x,p.x); a.y=min(a.y,p.y); b.x=max(b.x,p.x); b.y=max(b.y,p.y) }
    return CGRect(x:a.x, y:a.y, width:b.x-a.x, height:b.y-a.y)
}
let lBox = box(pts(lm.leftEye)), rBox = box(pts(lm.rightEye))

// --- segmentation -> cutout ---
let segReq = VNGeneratePersonSegmentationRequest(); segReq.qualityLevel = .accurate
segReq.outputPixelFormat = kCVPixelFormatType_OneComponent8
try VNImageRequestHandler(cgImage: cg, options: [:]).perform([segReq])
guard let mask = segReq.results?.first?.pixelBuffer else { fputs("no seg\n", stderr); exit(1) }
var maskCI = CIImage(cvPixelBuffer: mask)
maskCI = maskCI.transformed(by: CGAffineTransform(scaleX: CGFloat(W)/maskCI.extent.width, y: CGFloat(H)/maskCI.extent.height))
let blend = CIFilter(name: "CIBlendWithMask")!
blend.setValue(ci, forKey: kCIInputImageKey)
blend.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
blend.setValue(maskCI, forKey: kCIInputMaskImageKey)
let cictx = CIContext()
guard let cutoutCG = cictx.createCGImage(blend.outputImage!.cropped(to: ci.extent), from: ci.extent) else {
    fputs("cutout failed\n", stderr); exit(1)
}

// --- alpha bbox (top-down) ---
let bpr = W*4
var buf = [UInt8](repeating: 0, count: bpr*H)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let sctx = CGContext(data:&buf,width:W,height:H,bitsPerComponent:8,bytesPerRow:bpr,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
sctx.draw(cutoutCG, in: CGRect(x:0,y:0,width:W,height:H))
var minX=W,minY=H,maxX=0,maxY=0
for y in 0..<H { for x in 0..<W { if buf[y*bpr+x*4+3] > 24 { minX=min(minX,x);maxX=max(maxX,x);minY=min(minY,y);maxY=max(maxY,y) } } }
let bbX=minX, bbY=minY, bbW=maxX-minX+1, bbH=maxY-minY+1
let trimmed = cutoutCG.cropping(to: CGRect(x:bbX, y:H-bbY-bbH, width:bbW, height:bbH))!

// --- fit into canvas ---
let scale = targetMax/CGFloat(max(bbW,bbH))
let dw = CGFloat(bbW)*scale, dh = CGFloat(bbH)*scale
let dx = (CGFloat(canvas)-dw)/2
let topY = CGFloat(safeTop)
let dyBL = CGFloat(canvas) - topY - dh
let out = CGContext(data:nil,width:canvas,height:canvas,bitsPerComponent:8,bytesPerRow:0,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
out.clear(CGRect(x:0,y:0,width:canvas,height:canvas)); out.interpolationQuality = .high
out.draw(trimmed, in: CGRect(x:dx, y:dyBL, width:dw, height:dh))
let outCG = out.makeImage()!

// --- eye anchors: detect on the FINAL canvas image (upscaled) so the
// coordinates are ground-truth canvas-normalized, with no photo->canvas
// transform to get the y-flip wrong. ---
let up = 4, upW = canvas*up
let upCtx=CGContext(data:nil,width:upW,height:upW,bitsPerComponent:8,bytesPerRow:0,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
upCtx.interpolationQuality = .high
upCtx.setFillColor(CGColor(gray:0.5,alpha:1)); upCtx.fill(CGRect(x:0,y:0,width:upW,height:upW))
upCtx.draw(outCG, in: CGRect(x:0,y:0,width:upW,height:upW))
let upCG = upCtx.makeImage()!
let lm2Req = VNDetectFaceLandmarksRequest()
try VNImageRequestHandler(cgImage: upCG, options: [:]).perform([lm2Req])
guard let face2 = lm2Req.results?.first as? VNFaceObservation, let lm2 = face2.landmarks else {
    fputs("no landmarks on canvas image\n", stderr); exit(1)
}
func pts2(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] {
    guard let r else { return [] }
    let bb = face2.boundingBox
    return r.normalizedPoints.map { CGPoint(x:(bb.origin.x+$0.x*bb.size.width)*CGFloat(upW),
                                            y:(1-(bb.origin.y+$0.y*bb.size.height))*CGFloat(upW)) }
}
let lB = box(pts2(lm2.leftEye)), rB = box(pts2(lm2.rightEye))
let lx = Double(lB.midX)/Double(upW), ly = Double(lB.midY)/Double(upW)
let rx = Double(rB.midX)/Double(upW), ry = Double(rB.midY)/Double(upW)
let ew = Double(lB.width)/Double(upW)
let eh = Double(lB.height)/Double(upW)
// Mouth anchor from the outer-lip landmarks on the final canvas image.
let mB = box(pts2(lm2.outerLips))
let mx = Double(mB.midX)/Double(upW), my = Double(mB.midY)/Double(upW)
let mw = Double(mB.width)/Double(upW), mh = Double(mB.height)/Double(upW)

// --- iris color: ring sample around each eye center (avoid pupil) ---
func ringColor(_ c: CGPoint, eyeH: CGFloat) -> [Double] {
    let rr = Int(eyeH*0.33)
    var rs=[Int](),gs=[Int](),bs=[Int]()
    for ang in stride(from:0.0,to:6.28,by:0.4) {
        let x = Int(c.x + CGFloat(cos(ang))*CGFloat(rr)), y = Int(c.y + CGFloat(sin(ang))*CGFloat(rr))
        guard x>=0,x<W,y>=0,y<H else { continue }
        let i=y*bpr+x*4; rs.append(Int(buf[i]));gs.append(Int(buf[i+1]));bs.append(Int(buf[i+2]))
    }
    func med(_ a:[Int])->Double{ a.isEmpty ?0.5:Double(a.sorted()[a.count/2])/255.0 }
    return [med(rs),med(gs),med(bs)]
}
// sample from ORIGINAL (opaque) buffer via a fresh draw
var obuf=[UInt8](repeating:0,count:bpr*H)
let octx=CGContext(data:&obuf,width:W,height:H,bitsPerComponent:8,bytesPerRow:bpr,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
octx.draw(cg,in:CGRect(x:0,y:0,width:W,height:H))
func ring2(_ c:CGPoint,_ eyeH:CGFloat)->[Double]{
    // Sample a grid across the iris (roughly the eye-height-diameter disc),
    // dropping near-black (pupil, lashes) and near-white (sclera, highlight)
    // pixels so the median lands on the actual iris hue.
    var samples:[(Int,Int,Int)]=[]
    let R = eyeH*0.55
    var r = R*0.30
    while r <= R {
        for ang in stride(from:0.0,to:6.28,by:0.25){
            let x=Int(c.x+CGFloat(cos(ang))*r),y=Int(c.y+CGFloat(sin(ang))*r)
            guard x>=0,x<W,y>=0,y<H else{continue}
            let i=y*bpr+x*4
            let rr=Int(obuf[i]),gg=Int(obuf[i+1]),bb=Int(obuf[i+2])
            let lum=Double(rr)*0.3+Double(gg)*0.59+Double(bb)*0.11
            if lum>=35 && lum<=205 { samples.append((rr,gg,bb)) }
        }
        r += R*0.22
    }
    if samples.isEmpty { return [0.34,0.40,0.34] }
    func med(_ sel:((Int,Int,Int))->Int)->Double{
        let vals = samples.map(sel).sorted(); return Double(vals[vals.count/2])/255.0
    }
    return [med{$0.0},med{$0.1},med{$0.2}]
}
let irisL = ring2(CGPoint(x:lBox.midX,y:lBox.midY), lBox.height)
let irisR = ring2(CGPoint(x:rBox.midX,y:rBox.midY), rBox.height)
let iris = [ (irisL[0]+irisR[0])/2, (irisL[1]+irisR[1])/2, (irisL[2]+irisR[2])/2 ]

// Skin tone from the upper cheek just below each eye (reliable skin, no beard
// at this height), for painting over the real eye when the synthetic eye is
// closed (asleep/blink).
func skinSample(_ c:CGPoint,_ eyeH:CGFloat)->[Double]{
    var rs=[Int](),gs=[Int](),bs=[Int]()
    let cy=c.y+eyeH*1.7
    for dy in -3...3 { for dx in -8...8 {
        let x=Int(c.x)+dx*2, y=Int(cy)+dy*2
        guard x>=0,x<W,y>=0,y<H else{continue}
        let i=y*bpr+x*4; rs.append(Int(obuf[i]));gs.append(Int(obuf[i+1]));bs.append(Int(obuf[i+2]))
    }}
    func med(_ a:[Int])->Double{a.isEmpty ?0.6:Double(a.sorted()[a.count/2])/255.0}
    return [med(rs),med(gs),med(bs)]
}
let skinL=skinSample(CGPoint(x:lBox.midX,y:lBox.midY),lBox.height)
let skinR=skinSample(CGPoint(x:rBox.midX,y:rBox.midY),rBox.height)
let skin=[(skinL[0]+skinR[0])/2,(skinL[1]+skinR[1])/2,(skinL[2]+skinR[2])/2]

// --- write package ---
let fm = FileManager.default
try? fm.createDirectory(atPath: "\(outDir)/frames", withIntermediateDirectories: true)
let rep = NSBitmapImageRep(cgImage: outCG)
try rep.representation(using:.png,properties:[:])!.write(to: URL(fileURLWithPath:"\(outDir)/frames/neutral.png"))

func f(_ v: Double) -> String { String(format:"%.4f", v) }
let manifest = """
{
  "format": 3,
  "name": "\(name)",
  "canvas": 252,
  "safeArea": 240,
  "frames": { "neutral": "frames/neutral.png" },
  "eyes": {
    "left":  { "x": \(f(lx)), "y": \(f(ly)), "w": \(f(ew)), "h": \(f(eh)) },
    "right": { "x": \(f(rx)), "y": \(f(ry)), "w": \(f(ew)), "h": \(f(eh)) },
    "irisColor": [\(f(iris[0])), \(f(iris[1])), \(f(iris[2]))],
    "skinColor": [\(f(skin[0])), \(f(skin[1])), \(f(skin[2]))]
  },
  "mouth": { "x": \(f(mx)), "y": \(f(my)), "w": \(f(mw)), "h": \(f(mh)) }
}
"""
try manifest.write(toFile:"\(outDir)/manifest.json", atomically:true, encoding:.utf8)
print("neutral.png written; eyes L=(\(f(lx)),\(f(ly))) R=(\(f(rx)),\(f(ry))) w=\(f(ew)) h=\(f(eh)) iris=\(iris.map{f($0)})")
