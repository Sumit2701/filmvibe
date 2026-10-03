import CoreImage

/// Holds one source photo (RAW or processed) and renders it with any recipe.
/// Not thread-safe: use from a single serial queue.
final class DevelopSession {
    let data: Data
    let isRAW: Bool
    let captureDRStops: Double

    private var raw: CIRAWFilter?
    private var rawDefaults: RAWDefaults?
    private var processed: CIImage?

    init?(data: Data, captureDRStops: Double) {
        self.data = data
        self.captureDRStops = captureDRStops
        if let r = CIRAWFilter(imageData: data, identifierHint: nil), r.outputImage != nil {
            raw = r
            rawDefaults = RAWDefaults(r)
            isRAW = true
        } else if let img = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            processed = img.translatedToOrigin()
            isRAW = false
        } else {
            return nil
        }
    }

    convenience init?(url: URL, captureDRStops: Double) {
        guard let d = try? Data(contentsOf: url) else { return nil }
        self.init(data: d, captureDRStops: captureDRStops)
    }

    var nativeSize: CGSize {
        if let raw { return raw.nativeSize }
        return processed?.extent.size ?? .zero
    }

    /// Renders with a recipe. `longEdge` nil = full resolution.
    func render(recipe: Recipe, tuning: EngineTuning, postExposure: Double, longEdge: CGFloat?,
                framing: Framing = .full) -> CIImage? {
        if let raw, let rawDefaults {
            return FilmEngine.shared.developRAW(raw, recipe: recipe, tuning: tuning, captureDRStops: captureDRStops,
                                                postExposure: postExposure, longEdge: longEdge, defaults: rawDefaults,
                                                framing: framing)
        }
        guard let processed else { return nil }
        let nativeLong = max(processed.extent.width, processed.extent.height)
        var src = FilmEngine.shared.frame(processed, framing, fullResolution: longEdge == nil)
        if let longEdge { src = scaled(src, to: longEdge) }
        var ctx = RenderContext(source: .processed, processedLongEdge: max(src.extent.width, src.extent.height))
        ctx.postExposure = postExposure
        ctx.referenceLongEdge = framing.referenceLongEdge(native: nativeLong)
        let p = ParamResolver.resolve(recipe, tuning: tuning, context: ctx)
        return FilmEngine.shared.apply(src, p)
    }

    /// Apple's standard rendering of the same file (the "before").
    func renderStandard(longEdge: CGFloat?, framing: Framing = .full) -> CIImage? {
        if isRAW { return FilmEngine.shared.standardRAW(data, longEdge: longEdge, framing: framing) }
        guard let processed else { return nil }
        let src = FilmEngine.shared.frame(processed, framing, fullResolution: longEdge == nil)
        return longEdge.map { scaled(src, to: $0) } ?? src
    }

    /// Diagnostic: the brightest linear value in the decoded RAW (helps calibrate rawWhite).
    func measuredRAWMax() -> Float? {
        guard let raw else { return nil }
        let saved = raw.scaleFactor
        raw.scaleFactor = 0.1
        raw.boostAmount = 0
        raw.exposure = Float(-FilmEngine.rawHeadroomPull)
        defer { raw.scaleFactor = saved }
        guard let img = raw.outputImage else { return nil }
        let f = CIFilter(name: "CIAreaMaximum", parameters: [kCIInputImageKey: img, kCIInputExtentKey: CIVector(cgRect: img.extent)])
        guard let out = f?.outputImage else { return nil }
        var px = [Float](repeating: 0, count: 4)
        FilmEngine.shared.context.render(out, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return max(px[0], px[1], px[2]) * Float(pow(2.0, FilmEngine.rawHeadroomPull))
    }

    private func scaled(_ img: CIImage, to longEdge: CGFloat) -> CIImage {
        let current = max(img.extent.width, img.extent.height)
        guard longEdge < current else { return img }
        let f = CIFilter(name: "CILanczosScaleTransform",
                         parameters: [kCIInputImageKey: img, kCIInputScaleKey: longEdge / current, kCIInputAspectRatioKey: 1])
        return (f?.outputImage ?? img).translatedToOrigin()
    }
}

extension CIImage {
    /// The centre 1/crop of the frame (crop >= 1).
    func centerCropped(by crop: Double) -> CIImage {
        guard crop > 1.001 else { return self }
        let e = extent
        let w = e.width / CGFloat(crop), h = e.height / CGFloat(crop)
        return cropped(to: CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h).integral)
    }

    func translatedToOrigin() -> CIImage {
        let e = extent
        if e.origin == .zero { return self }
        return transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
    }
}
