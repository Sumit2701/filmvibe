import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// usage: fvtest <image> <out.jpg> <longEdge> <cols> <spec>...
// spec: "std" (Apple standard), recipe id, or "id|key=value,key=value" for overrides
let args = CommandLine.arguments
FilmEngine.metallibURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FV_METALLIB"] ?? "k.metallib")
let recipes = try! JSONDecoder().decode([Recipe].self, from: Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["FV_RECIPES"] ?? "../../FilmVibe/Resources/Recipes.json")))
var tuning = EngineTuning.defaults
if let tpath = ProcessInfo.processInfo.environment["TUNING"], let d = try? Data(contentsOf: URL(fileURLWithPath: tpath)), let t = EngineTuning.decodeMerged(from: d) { tuning = t }
let data = try! Data(contentsOf: URL(fileURLWithPath: args[1]))
let dr = Double(ProcessInfo.processInfo.environment["CAPDR"] ?? "0") ?? 0
let session = DevelopSession(data: data, captureDRStops: dr)!
let longEdgeV = Double(args[3])!; let longEdge: CGFloat? = longEdgeV > 0 ? CGFloat(longEdgeV) : nil
let cols = Int(args[4])!
print("RAW:", session.isRAW, "native:", session.nativeSize, "max linear:", session.measuredRAWMax() ?? -1)
if let r = CIRAWFilter(imageData: data, identifierHint: nil) {
    print(String(format: "as-shot %.0fK tint %.1f baseline %.2f lumNR %.2f colNR %.2f", r.neutralTemperature, r.neutralTint, r.baselineExposure, r.luminanceNoiseReductionAmount, r.colorNoiseReductionAmount))
}

func applyOverrides(_ r: inout Recipe, _ s: String) {
    for kv in s.split(separator: ",") {
        let p = kv.split(separator: "="); guard p.count == 2 else { continue }
        let k = String(p[0]), v = String(p[1])
        switch k {
        case "sim": r.filmSimulation = FilmSimulation(rawValue: v)!
        case "h": r.highlight = Double(v)!
        case "s": r.shadow = Double(v)!
        case "c": r.color = Int(v)!
        case "cl": r.clarity = Int(v)!
        case "sh": r.sharpness = Int(v)!
        case "dr": r.dynamicRange = DynamicRange(rawValue: v)!
        case "g": r.grainEffect = EffectLevel(rawValue: v)!
        case "cc": r.colorChrome = EffectLevel(rawValue: v)!
        case "fx": r.colorChromeBlue = EffectLevel(rawValue: v)!
        case "wb": r.whiteBalance.mode = WBMode(rawValue: v)!
        case "k": r.whiteBalance.mode = .kelvin; r.whiteBalance.kelvin = Int(v)!
        case "wr": r.whiteBalance.red = Int(v)!
        case "wbb": r.whiteBalance.blue = Int(v)!
        case "name": r.name = v
        default: print("unknown key", k)
        }
    }
}

var tiles: [(CGImage, String)] = []
for spec in args[5...] {
    let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
    let id = parts[0]
    var label = id
    let img: CIImage?
    if id == "std" {
        img = session.renderStandard(longEdge: longEdge); label = "Apple standard"
    } else {
        var r = id == "neutral" ? Recipe.neutral : recipes.first { $0.id == id }!
        if parts.count > 1 { applyOverrides(&r, parts[1]) }
        label = r.name + (parts.count > 1 ? " [\(parts[1])]" : "")
        let fr = Framing(crop: Double(ProcessInfo.processInfo.environment["FOCALCROP"] ?? "1") ?? 1, upscale: ProcessInfo.processInfo.environment["NATIVECROP"] == nil)
        img = session.render(recipe: r, tuning: tuning, postExposure: ProcessInfo.processInfo.environment["NOEV"] != nil ? 0 : r.exposureComp, longEdge: longEdge, framing: fr)
    }
    var final = img
    if let c = ProcessInfo.processInfo.environment["CROP"], let im = img {
        let v = c.split(separator: ",").map { Double($0)! }
        let e = im.extent, w = CGFloat(v[2])
        let cx = e.minX + CGFloat(v[0]) * e.width, cy = e.maxY - CGFloat(v[1]) * e.height
        final = im.cropped(to: CGRect(x: cx - w/2, y: cy - w/2, width: w, height: w)).translatedToOrigin()
    }
    if let f = final { print(spec, "→", Int(f.extent.width), "x", Int(f.extent.height)) }
    guard let i = final, let cg = FilmEngine.shared.cgImage(i) else { print("fail", spec); continue }
    tiles.append((cg, label))
}

let tw = tiles[0].0.width, th = tiles[0].0.height
let rows = (tiles.count + cols - 1) / cols
let labelH = 26
let W = cols * tw, H = rows * (th + labelH)
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
for (i, t) in tiles.enumerated() {
    let cx = (i % cols) * tw, ry = i / cols
    let y = H - (ry + 1) * (th + labelH)
    ctx.draw(t.0, in: CGRect(x: cx, y: y, width: t.0.width, height: t.0.height))
    let attr = [kCTFontAttributeName: CTFontCreateWithName("Menlo-Bold" as CFString, 15, nil), kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, t.1 as CFString, attr))
    ctx.textPosition = CGPoint(x: cx + 6, y: y + th + 7)
    CTLineDraw(line, ctx)
}
let out = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
CGImageDestinationFinalize(dest)
print("wrote", args[2], W, H)
