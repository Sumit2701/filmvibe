import CoreImage
import simd

/// Where the pixels come from. RAW and processed images have different headroom.
enum SourceKind: String, Codable {
    case raw, processed, live
}

/// Per-render context that isn't part of the recipe.
struct RenderContext {
    var source: SourceKind
    /// Long edge, in pixels, of the image being processed (after any downscale).
    var processedLongEdge: CGFloat
    /// Stops of underexposure that were applied at capture time for DR200 / DR400.
    var captureDRStops: Double = 0
    /// Additional exposure applied while editing (EV).
    var postExposure: Double = 0
    /// Extra channel gains (e.g. live auto-WB priority correction).
    var extraGains: SIMD3<Float> = SIMD3(1, 1, 1)
    /// Long edge of the final full-resolution output. Grain, sharpening and clarity are
    /// specified in pixels at this size (4032 = full iPhone frame).
    var referenceLongEdge: CGFloat = 4032
}

/// Everything the kernels need, resolved from a Recipe + EngineTuning + RenderContext.
struct FilmParams {
    var gain = SIMD3<Float>(1, 1, 1)
    var mono = false
    var monoWeights = SIMD3<Float>(0.2126, 0.7152, 0.0722)
    var vmid: Float = 0.46
    var Th: Float = 3
    var kh: Float = 0
    var Tb: Float = 6.5
    var ks: Float = 2
    var blackLift: Float = 0
    var whiteCap: Float = 1
    var hiKnee: Float = 0.82
    var hlBump: Float = 0
    var shBump: Float = 0
    var chroma: Float = 1
    var cce: Float = 0
    var fxBlue: Float = 0
    var shadowSat: Float = 1
    var highlightSat: Float = 1
    var hueShift = [Float](repeating: 0, count: 8)
    var hueSat = [Float](repeating: 1, count: 8)
    var hueLum = [Float](repeating: 0, count: 8)
    var shadowTint = SIMD2<Float>(0, 0)
    var highlightTint = SIMD2<Float>(0, 0)
    var midTint = SIMD2<Float>(0, 0)
    var monoTone = SIMD2<Float>(0, 0)

    // Detail (in pixels of the processed image)
    var clarity: Float = 0
    var clarityRadius: Float = 10
    var sharp: Float = 0
    var sharpRadius: Float = 1

    // Grain
    var grainAmp: Float = 0
    var grainSize: Float = 1
    var grainShape: Float = 0.6

    // RAW decoding
    var nrScale: Float = 1
    var nrAdd: Float = 0
    var nrColorFloor: Float = 0.12
    /// nil = keep the file's as-shot white balance
    var wbTemperature: Float?
    var wbTint: Float?
    var autoWBAdjust: Float = 0
}

enum ParamResolver {

    static func resolve(_ r: Recipe, tuning t: EngineTuning, context ctx: RenderContext) -> FilmParams {
        var p = FilmParams()
        let prof = t.profile(r.filmSimulation.profileKey)

        // ---- Dynamic range & Highlight / Shadow ----
        var drStops: Double
        var hl = r.highlight
        var sh = r.shadow
        switch r.dRangePriority {
        case .off:
            switch r.dynamicRange {
            case .dr100: drStops = 0
            case .dr200: drStops = 1
            case .dr400: drStops = 2
            case .auto: drStops = t.drAutoStops
            }
        case .weak, .auto:
            drStops = 1; hl = -1; sh = -1
        case .strong:
            drStops = 2; hl = -2; sh = -2
        }
        drStops *= t.drStrength
        hl += prof.highlightTone
        sh += prof.shadowTone

        let baseWhite: Double
        switch ctx.source {
        case .raw: baseWhite = t.rawWhite
        case .processed, .live: baseWhite = t.processedWhite
        }
        let rawEV = ctx.source == .raw ? t.rawExposure : 0
        let totalEV = ctx.captureDRStops + ctx.postExposure + rawEV
        let exposureGain = Float(pow(2.0, totalEV))

        // White point: what the DR mode wants, limited by the data actually available.
        let wantWhite = baseWhite * pow(2.0, drStops)
        let dataWhite = baseWhite * pow(2.0, ctx.captureDRStops + ctx.postExposure)
        let white = min(wantWhite, max(dataWhite, baseWhite))

        var Th = log2(white / 0.18) + prof.highlightRange
        if hl < 0 { Th += -hl * t.highlightRangeStep }
        Th = max(Th, 0.8)
        let Tb = max(prof.shadowRange, 2.0)
        var contrast = prof.contrast
        if ctx.source == .live { contrast *= t.previewContrast }
        let vmid = min(max(t.midGrey + prof.midShift, 0.2), 0.8)

        p.vmid = Float(vmid)
        p.Th = Float(Th)
        p.Tb = Float(Tb)
        p.kh = Float(solveShoulder(contrast * Th / (1 - vmid)))
        p.ks = Float(solveShoulder(contrast * Tb / vmid))
        p.hlBump = Float(min(max(hl * t.highlightStep, -2.5), 0.9))
        p.shBump = Float(min(max(sh * t.shadowStep, -2.5), 0.9))
        p.blackLift = Float(prof.blackLift)
        p.whiteCap = Float(prof.whiteCap)
        p.hiKnee = Float(min(max(t.highlightKnee, 0.3), 0.98))

        // ---- White balance shift (R / B steps) ----
        let rg = pow(2.0, Double(r.whiteBalance.red) * t.wbShiftStep)
        let bg = pow(2.0, Double(r.whiteBalance.blue) * t.wbShiftStep)
        var wb = SIMD3<Double>(rg, 1, bg)
        let lum = 0.2126 * wb.x + 0.7152 * wb.y + 0.0722 * wb.z
        wb /= lum
        p.gain = SIMD3<Float>(Float(wb.x), Float(wb.y), Float(wb.z)) * exposureGain * ctx.extraGains

        // ---- Color ----
        p.mono = r.filmSimulation.isMonochrome
        if p.mono {
            var trans = SIMD3<Double>(1, 1, 1)
            switch r.filmSimulation.monoFilter {
            case .none: break
            case .yellow: trans = vec3(t.filterYellow)
            case .red: trans = vec3(t.filterRed)
            case .green: trans = vec3(t.filterGreen)
            }
            var w = SIMD3<Double>(0.2126, 0.7152, 0.0722) * trans
            w /= (w.x + w.y + w.z)
            p.monoWeights = SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z))
            let a = Double(r.monoMG) * t.monoToneStep + prof.monoTone[safe: 0]
            let b = Double(r.monoWC) * t.monoToneStep + prof.monoTone[safe: 1]
            p.monoTone = SIMD2<Float>(Float(a), Float(b))
        } else {
            p.chroma = Float(max(0, prof.saturation * (1 + Double(r.color) * t.colorStep)))
            p.hueShift = prof.hueShift.map { Float($0 * .pi / 180) }.padded(to: 8, with: 0)
            p.hueSat = prof.hueSat.map { Float($0) }.padded(to: 8, with: 1)
            p.hueLum = prof.hueLum.map { Float($0) }.padded(to: 8, with: 0)
            p.shadowTint = SIMD2<Float>(Float(prof.shadowTint[safe: 0]), Float(prof.shadowTint[safe: 1]))
            p.midTint = SIMD2<Float>(Float(prof.midTint[safe: 0]), Float(prof.midTint[safe: 1]))
            p.highlightTint = SIMD2<Float>(Float(prof.highlightTint[safe: 0]), Float(prof.highlightTint[safe: 1]))
            p.shadowSat = Float(prof.shadowSaturation)
            p.highlightSat = Float(prof.highlightSaturation)
        }
        p.cce = Float(level(r.colorChrome, weak: t.cceWeak, strong: t.cceStrong))
        p.fxBlue = Float(level(r.colorChromeBlue, weak: t.fxBlueWeak, strong: t.fxBlueStrong))

        // ---- Detail ----
        let k = Double(ctx.processedLongEdge) / Double(max(ctx.referenceLongEdge, 1))
        p.clarity = Float(Double(r.clarity) * t.clarityStep)
        p.clarityRadius = Float(max(t.clarityRadius * k, 2))
        var sharp = t.sharpBase + Double(r.sharpness) * t.sharpStep
        var sharpRadius = t.sharpRadius * k
        if sharpRadius < 0.6 {
            // Sub-pixel radius at preview sizes: shrink the effect instead.
            sharp *= sharpRadius / 0.6
            sharpRadius = 0.6
        }
        p.sharp = Float(min(max(sharp, -0.9), 3))
        p.sharpRadius = Float(sharpRadius)

        // ---- Grain ----
        var amp = level(r.grainEffect, weak: t.grainWeak, strong: t.grainStrong)
        var size = (r.grainSize == .large ? t.grainLarge : t.grainSmall) * k
        if size < 1 {
            amp *= max(size, 0.25)
            size = 1
        }
        if ctx.source == .live { amp *= t.previewGrain }
        p.grainAmp = Float(amp)
        p.grainSize = Float(size)
        p.grainShape = Float(t.grainShape)

        // ---- RAW decode settings ----
        p.nrScale = Float(pow(2.0, Double(r.highISONR) * t.nrStep))
        p.nrAdd = Float(Double(r.highISONR) * t.nrAddStep)
        p.nrColorFloor = Float(t.nrColorFloor)
        switch r.whiteBalance.mode {
        case .auto: break
        case .autoWhite: p.autoWBAdjust = Float(-t.autoWhiteStrength)
        case .autoAmbience: p.autoWBAdjust = Float(t.autoAmbienceStrength)
        case .daylight: p.wbTemperature = Float(t.daylightK); p.wbTint = 0
        case .shade: p.wbTemperature = Float(t.shadeK); p.wbTint = 0
        case .incandescent: p.wbTemperature = Float(t.incandescentK); p.wbTint = 0
        case .fluorescent1: p.wbTemperature = Float(t.fluorescent1K); p.wbTint = Float(t.fluorescentTint)
        case .fluorescent2: p.wbTemperature = Float(t.fluorescent2K); p.wbTint = Float(t.fluorescentTint)
        case .fluorescent3: p.wbTemperature = Float(t.fluorescent3K); p.wbTint = Float(t.fluorescentTint)
        case .kelvin: p.wbTemperature = Float(r.whiteBalance.kelvin); p.wbTint = 0
        }
        return p
    }

    /// Stops of capture underexposure a recipe asks for (DR200 = 1, DR400 = 2).
    static func captureDRStops(for r: Recipe, tuning t: EngineTuning) -> Double {
        switch r.dRangePriority {
        case .off:
            switch r.dynamicRange {
            case .dr100: return 0
            case .dr200: return 1
            case .dr400: return 2
            case .auto: return t.drAutoStops
            }
        case .weak, .auto: return 1
        case .strong: return 2
        }
    }

    /// Fixed white balance (temperature, tint) for the camera, or nil for auto modes.
    static func fixedWhiteBalance(for r: Recipe, tuning t: EngineTuning) -> (Float, Float)? {
        let p = resolve(r, tuning: t, context: RenderContext(source: .live, processedLongEdge: 1000))
        guard let temp = p.wbTemperature else { return nil }
        return (temp, p.wbTint ?? 0)
    }

    /// Solves k / (1 - e^-k) = s0 for k. k > 0 gives a shoulder, k < 0 a hard (convex) approach.
    static func solveShoulder(_ s0: Double) -> Double {
        if s0 <= 0.02 { return -40 }
        if abs(s0 - 1) < 1e-4 { return 0 }
        func f(_ k: Double) -> Double {
            if abs(k) < 1e-6 { return 1 }
            return k / (1 - exp(-k))
        }
        var lo = -40.0, hi = 60.0
        for _ in 0..<80 {
            let mid = (lo + hi) / 2
            if f(mid) < s0 { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    private static func level(_ l: EffectLevel, weak: Double, strong: Double) -> Double {
        switch l {
        case .off: return 0
        case .weak: return weak
        case .strong: return strong
        }
    }

    private static func vec3(_ a: [Double]) -> SIMD3<Double> {
        SIMD3(a[safe: 0, default: 1], a[safe: 1, default: 1], a[safe: 2, default: 1])
    }
}

extension Array where Element == Double {
    subscript(safe i: Int) -> Double { indices.contains(i) ? self[i] : 0 }
    subscript(safe i: Int, default d: Double) -> Double { indices.contains(i) ? self[i] : d }
}

extension Array {
    func padded(to n: Int, with v: Element) -> [Element] {
        if count >= n { return Array(prefix(n)) }
        return self + Array(repeating: v, count: n - count)
    }
}
