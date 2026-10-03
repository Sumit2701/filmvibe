import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Metal
#if canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers

/// Applies film looks with Core Image. Thread-safe: CIContext and kernels can be used from any queue.
final class FilmEngine {
    static let shared = FilmEngine()
    /// Override for tools / tests that don't run from the app bundle.
    static var metallibURL: URL?

    let device: MTLDevice
    let context: CIContext
    let outputColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    private let colorKernel: CIColorKernel
    private let detailKernel: CIColorKernel
    private let grainKernel: CIColorKernel

    private let grainLock = NSLock()
    private var grainStats: [Int: (norm: Float, mean: Float)] = [:]

    private init() {
        device = MTLCreateSystemDefaultDevice()!
        context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
            .name: "FilmVibe",
        ])
        let url = FilmEngine.metallibURL ?? Bundle.main.url(forResource: "default", withExtension: "metallib")!
        let data = try! Data(contentsOf: url)
        colorKernel = try! CIColorKernel(functionName: "fvFilmColor", fromMetalLibraryData: data)
        detailKernel = try! CIColorKernel(functionName: "fvDetail", fromMetalLibraryData: data)
        grainKernel = try! CIColorKernel(functionName: "fvGrain", fromMetalLibraryData: data)
    }

    // MARK: - Film pipeline

    /// Applies the full film look to a linear image.
    /// - Parameter grainSeed: offset into the grain field (vary per frame for animated live grain).
    func apply(_ input: CIImage, _ p: FilmParams, grainSeed: CGPoint = .zero) -> CIImage {
        let extent = input.extent
        guard !extent.isEmpty, !extent.isInfinite else { return input }

        func v4(_ x: Float, _ y: Float, _ z: Float, _ w: Float) -> CIVector {
            CIVector(x: CGFloat(x), y: CGFloat(y), z: CGFloat(z), w: CGFloat(w))
        }
        let args: [Any] = [
            input,
            v4(p.gain.x, p.gain.y, p.gain.z, p.mono ? 1 : 0),
            v4(p.monoWeights.x, p.monoWeights.y, p.monoWeights.z, 0),
            v4(p.vmid, p.Th, p.kh, p.Tb),
            v4(p.ks, p.blackLift, p.hiKnee, p.whiteCap),
            v4(p.hlBump, p.shBump, 0, 0),
            v4(p.chroma, p.cce, p.fxBlue, 0),
            v4(p.shadowSat, p.highlightSat, 0, 0),
            v4(p.hueShift[0], p.hueShift[1], p.hueShift[2], p.hueShift[3]),
            v4(p.hueShift[4], p.hueShift[5], p.hueShift[6], p.hueShift[7]),
            v4(p.hueSat[0], p.hueSat[1], p.hueSat[2], p.hueSat[3]),
            v4(p.hueSat[4], p.hueSat[5], p.hueSat[6], p.hueSat[7]),
            v4(p.hueLum[0], p.hueLum[1], p.hueLum[2], p.hueLum[3]),
            v4(p.hueLum[4], p.hueLum[5], p.hueLum[6], p.hueLum[7]),
            v4(p.shadowTint.x, p.shadowTint.y, p.highlightTint.x, p.highlightTint.y),
            v4(p.midTint.x, p.midTint.y, p.monoTone.x, p.monoTone.y),
        ]
        guard var img = colorKernel.apply(extent: extent, arguments: args) else { return input }

        if abs(p.clarity) > 0.001 || abs(p.sharp) > 0.001 {
            let clamped = img.clampedToExtent()
            let blurL = abs(p.clarity) > 0.001
                ? clamped.applyingGaussianBlur(sigma: Double(p.clarityRadius)).cropped(to: extent)
                : img
            let blurS = abs(p.sharp) > 0.001
                ? clamped.applyingGaussianBlur(sigma: Double(p.sharpRadius)).cropped(to: extent)
                : img
            if let out = detailKernel.apply(extent: extent, arguments: [img, blurL, blurS, v4(p.clarity, p.sharp, 0, 0)]) {
                img = out
            }
        }

        if p.grainAmp > 0.0001 {
            let (noise, stats) = grain(size: p.grainSize, seed: grainSeed)
            let n = noise.cropped(to: extent)
            if let out = grainKernel.apply(extent: extent, arguments: [img, n, v4(p.grainAmp, p.grainShape, stats.norm, stats.mean)]) {
                img = out
            }
        }
        return img
    }

    // MARK: - Grain

    private func rawNoise(size: Float, seed: CGPoint) -> CIImage {
        var n = CIFilter.randomGenerator().outputImage!
            .transformed(by: CGAffineTransform(translationX: seed.x.rounded(), y: seed.y.rounded()))
        if size > 1.05 {
            n = n.samplingNearest()
                .transformed(by: CGAffineTransform(scaleX: CGFloat(size), y: CGFloat(size)))
                .applyingGaussianBlur(sigma: Double(size) * 0.45)
        }
        return n
    }

    /// Returns a noise field and its normalisation so the kernel gets unit-variance grain.
    private func grain(size: Float, seed: CGPoint) -> (CIImage, (norm: Float, mean: Float)) {
        let key = Int((size * 20).rounded())
        grainLock.lock()
        let cached = grainStats[key]
        grainLock.unlock()
        if let cached { return (rawNoise(size: size, seed: seed), cached) }

        // Measure the noise statistics once per size.
        let side = 160
        let patch = rawNoise(size: size, seed: .zero).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        var buf = [Float](repeating: 0, count: side * side * 4)
        context.render(patch, toBitmap: &buf, rowBytes: side * 16,
                       bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBAf, colorSpace: nil)
        var sum = 0.0, sum2 = 0.0
        let count = side * side
        for i in 0..<count {
            let v = Double(buf[i * 4] + buf[i * 4 + 1] + buf[i * 4 + 2])
            sum += v; sum2 += v * v
        }
        let mean = sum / Double(count)
        let std = sqrt(max(sum2 / Double(count) - mean * mean, 1e-8))
        let stats = (norm: Float(1 / std), mean: Float(mean))
        grainLock.lock()
        grainStats[key] = stats
        grainLock.unlock()
        return (rawNoise(size: size, seed: seed), stats)
    }

    // MARK: - RAW development

    /// Configures a RAW filter for "as raw as possible" output: linear, no Apple tone curve,
    /// no local tone mapping, no sharpening; noise reduction and WB from the recipe.
    func configure(_ raw: CIRAWFilter, params p: FilmParams, longEdge: CGFloat?) {
        let native = raw.nativeSize
        let nativeLong = max(native.width, native.height)
        if let longEdge, nativeLong > 0 {
            raw.scaleFactor = Float(min(1, longEdge / nativeLong))
        } else {
            raw.scaleFactor = 1
        }
        raw.boostAmount = 0
        raw.boostShadowAmount = 0
        raw.extendedDynamicRangeAmount = 0
        // Pull exposure down so highlight data above white survives; restored via FilmParams gain.
        raw.exposure = Float(-FilmEngine.rawHeadroomPull)
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
        if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
        if raw.isContrastSupported { raw.contrastAmount = 0 }
        if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = true }
        if #available(iOS 26.0, macOS 26.0, *), raw.isHighlightRecoverySupported { raw.isHighlightRecoveryEnabled = true }
    }

    /// Auto White Priority (adjust < 0) over-corrects warm light so whites stay white;
    /// Ambience Priority (adjust > 0) moves toward 5500K so the light's mood is kept.
    static func adjustedAutoTemperature(_ t: Float, adjust a: Float) -> Float {
        if a > 0 { return t + (5500 - t) * a }
        if a < 0 && t < 5500 { return t + (5500 - t) * a }
        return t
    }

    /// Stops the RAW decode is pulled down to keep highlights unclipped.
    static let rawHeadroomPull: Double = 2

    /// Creates a developed CIImage from RAW data, cropped to `framing`.
    func developRAW(_ raw: CIRAWFilter, recipe: Recipe, tuning: EngineTuning, captureDRStops: Double,
                    postExposure: Double, longEdge: CGFloat?, defaults: RAWDefaults, framing: Framing = .full) -> CIImage? {
        var ctx = RenderContext(source: .raw, processedLongEdge: 1000)
        ctx.captureDRStops = captureDRStops
        ctx.postExposure = postExposure
        // Resolve once to get decode settings
        var p = ParamResolver.resolve(recipe, tuning: tuning, context: ctx)
        // Decode enough pixels that the cropped frame still reaches `longEdge`.
        configure(raw, params: p, longEdge: longEdge.map { $0 * CGFloat(framing.crop) })

        // White balance
        if let temp = p.wbTemperature {
            raw.neutralTemperature = temp
            raw.neutralTint = p.wbTint ?? 0
        } else {
            raw.neutralTemperature = FilmEngine.adjustedAutoTemperature(defaults.temperature, adjust: p.autoWBAdjust)
            raw.neutralTint = defaults.tint
        }

        // Apple's defaults are ISO-aware (often 0 luminance NR at low ISO), so each step both scales
        // the default and adds/removes a fixed amount.
        if raw.isLuminanceNoiseReductionSupported {
            let v = defaults.luminanceNR * p.nrScale + p.nrAdd
            raw.luminanceNoiseReductionAmount = min(1, max(0, v))
        }
        // Chroma NR follows the setting only gently: like the camera, NR -4 still keeps colour noise in check.
        if raw.isColorNoiseReductionSupported {
            let v = defaults.colorNR * pow(p.nrScale, 0.4) + p.nrAdd * 0.5
            raw.colorNoiseReductionAmount = min(1, max(p.nrColorFloor, v))
        }

        guard let decoded = raw.outputImage else { return nil }
        let nativeLong = max(raw.nativeSize.width, raw.nativeSize.height)
        let framed = frame(decoded, framing, fullResolution: longEdge == nil)
        ctx.processedLongEdge = max(framed.extent.width, framed.extent.height)
        ctx.referenceLongEdge = framing.referenceLongEdge(native: nativeLong)
        p = ParamResolver.resolve(recipe, tuning: tuning, context: ctx)
        p.gain *= Float(pow(2.0, FilmEngine.rawHeadroomPull))
        return apply(framed, p)
    }

    /// Apple's default RAW rendering, for before/after comparison.
    func standardRAW(_ data: Data, longEdge: CGFloat?, framing: Framing = .full) -> CIImage? {
        guard let raw = CIRAWFilter(imageData: data, identifierHint: nil) else { return nil }
        let native = raw.nativeSize
        let nativeLong = max(native.width, native.height)
        if let longEdge, nativeLong > 0 { raw.scaleFactor = Float(min(1, longEdge * CGFloat(framing.crop) / nativeLong)) }
        guard let img = raw.outputImage else { return nil }
        return frame(img, framing, fullResolution: longEdge == nil)
    }

    /// Centre-crops to the chosen focal length; at full resolution optionally upscales back to the
    /// sensor size like Fujifilm's Digital Teleconverter.
    func frame(_ image: CIImage, _ framing: Framing, fullResolution: Bool) -> CIImage {
        var img = image.translatedToOrigin()
        guard framing.crop > 1.001 else { return img }
        let full = img.extent.size
        img = img.centerCropped(by: framing.crop).translatedToOrigin()
        if fullResolution && framing.upscale {
            // Scale so the long edge lands exactly on the sensor's, then trim rounding slop.
            let scale = max(full.width, full.height) / max(img.extent.width, img.extent.height)
            let f = CIFilter(name: "CILanczosScaleTransform",
                             parameters: [kCIInputImageKey: img, kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            img = (f?.outputImage ?? img).translatedToOrigin()
            img = img.cropped(to: CGRect(origin: .zero, size: CGSize(width: min(img.extent.width, full.width).rounded(.down),
                                                                      height: min(img.extent.height, full.height).rounded(.down))))
        }
        return img
    }

    // MARK: - Output

    func cgImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: outputColorSpace)
    }

    func jpegData(_ image: CIImage, metadata: [String: Any]?, quality: CGFloat = 0.92) -> Data? {
        var img = image
        if var md = metadata {
            md[kCGImagePropertyOrientation as String] = 1
            md.removeValue(forKey: kCGImagePropertyPixelWidth as String)
            md.removeValue(forKey: kCGImagePropertyPixelHeight as String)
            md.removeValue(forKey: kCGImagePropertyDNGDictionary as String)
            md.removeValue(forKey: kCGImagePropertyRawDictionary as String)
            md.removeValue(forKey: kCGImagePropertyExifAuxDictionary as String)
            var tiff = md[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            tiff[kCGImagePropertyTIFFSoftware as String] = "FilmVibe"
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            md[kCGImagePropertyTIFFDictionary as String] = tiff
            img = img.settingProperties(md)
        } else {
            img = img.settingProperties([kCGImagePropertyOrientation as String: 1])
        }
        let opts: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
        ]
        return context.jpegRepresentation(of: img, colorSpace: outputColorSpace, options: opts)
    }

    /// Reads file metadata (EXIF / GPS / TIFF) to carry over into the rendered JPEG.
    static func metadata(of data: Data) -> [String: Any]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
    }
}

/// Focal-length crop applied at development time (non-destructive; the RAW keeps the full frame).
struct Framing: Equatable {
    var crop: Double = 1
    /// Upscale crops back to full sensor resolution (like Fuji's Digital Teleconverter).
    var upscale: Bool = true
    static let full = Framing()

    /// Long edge of the final full-resolution output for a sensor with `native` long edge.
    func referenceLongEdge(native: CGFloat) -> CGFloat {
        upscale || crop <= 1.001 ? native : native / CGFloat(crop)
    }
}

/// As-shot values from a RAW file, read once with a fresh filter.
struct RAWDefaults {
    var temperature: Float
    var tint: Float
    var luminanceNR: Float
    var colorNR: Float
    var baselineExposure: Float

    init(_ raw: CIRAWFilter) {
        temperature = raw.neutralTemperature
        tint = raw.neutralTint
        luminanceNR = raw.luminanceNoiseReductionAmount
        colorNR = raw.colorNoiseReductionAmount
        baselineExposure = raw.baselineExposure
    }
}
