import Foundation

/// Base film-simulation profiles. Filter variants (+Ye/+R/+G) share their base profile.
enum SimProfileKey: String, Codable, CaseIterable, Identifiable {
    case provia, velvia, astia, classicChrome, realaAce, proNegHi, proNegStd, classicNeg, nostalgicNeg, eterna, eternaBleach
    case acros, monochrome, sepia
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .provia: return "Provia / Standard"
        case .velvia: return "Velvia / Vivid"
        case .astia: return "Astia / Soft"
        case .classicChrome: return "Classic Chrome"
        case .realaAce: return "Reala Ace"
        case .proNegHi: return "Pro Neg. Hi"
        case .proNegStd: return "Pro Neg. Std"
        case .classicNeg: return "Classic Neg."
        case .nostalgicNeg: return "Nostalgic Neg."
        case .eterna: return "Eterna / Cinema"
        case .eternaBleach: return "Eterna Bleach Bypass"
        case .acros: return "Acros"
        case .monochrome: return "Monochrome"
        case .sepia: return "Sepia"
        }
    }

    var isMonochrome: Bool { self == .acros || self == .monochrome || self == .sepia }
}

/// Hue anchors used by the per-hue tables (OkLCh hue angles, degrees).
enum HueAnchor: Int, CaseIterable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    var id: Int { rawValue }
    var name: String { ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"][rawValue] }
    /// Must match the anchor table in FilmKernels.metal
    static let degrees: [Double] = [25, 60, 100, 140, 190, 245, 290, 330]
}

/// The "character" of one film simulation. Everything here is tunable in-app.
struct SimProfile: Codable, Equatable {
    // Tone
    /// Mid-tone contrast: change in display value per stop of scene exposure around middle grey.
    var contrast: Double
    /// Brightness offset of middle grey (display value).
    var midShift: Double
    /// Extra stops of highlight headroom for this simulation (positive = softer highlight roll-off).
    var highlightRange: Double
    /// Stops from middle grey down to black (smaller = deeper / harder shadows).
    var shadowRange: Double
    /// Built-in Highlight tone, in camera steps (added to the recipe's Highlight).
    var highlightTone: Double
    /// Built-in Shadow tone, in camera steps (added to the recipe's Shadow).
    var shadowTone: Double
    /// Raises the black point (display value), for faded / cine looks.
    var blackLift: Double
    /// Lowers the white point (display value 0...1).
    var whiteCap: Double

    // Color
    var saturation: Double
    var shadowSaturation: Double
    var highlightSaturation: Double
    /// Per-hue tables (8 anchors: red, orange, yellow, green, aqua, blue, purple, magenta)
    var hueShift: [Double]      // degrees
    var hueSat: [Double]        // multiplier
    var hueLum: [Double]        // fraction of lightness (+/-)
    /// OkLab (a, b) offsets
    var shadowTint: [Double]
    var midTint: [Double]
    var highlightTint: [Double]
    /// Monochrome toning applied on top of the WC/MG setting (used by Sepia), OkLab (a, b)
    var monoTone: [Double]

    static func make(contrast: Double, shadowRange: Double = 6.5, highlightRange: Double = 0, highlightTone: Double = 0,
                     shadowTone: Double = 0, blackLift: Double = 0, whiteCap: Double = 1, midShift: Double = 0,
                     saturation: Double = 1, shadowSaturation: Double = 1, highlightSaturation: Double = 1,
                     hueShift: [Double] = Array(repeating: 0, count: 8), hueSat: [Double] = Array(repeating: 1, count: 8),
                     hueLum: [Double] = Array(repeating: 0, count: 8), shadowTint: [Double] = [0, 0],
                     midTint: [Double] = [0, 0], highlightTint: [Double] = [0, 0], monoTone: [Double] = [0, 0]) -> SimProfile {
        SimProfile(contrast: contrast, midShift: midShift, highlightRange: highlightRange, shadowRange: shadowRange,
                   highlightTone: highlightTone, shadowTone: shadowTone, blackLift: blackLift, whiteCap: whiteCap,
                   saturation: saturation, shadowSaturation: shadowSaturation, highlightSaturation: highlightSaturation,
                   hueShift: hueShift, hueSat: hueSat, hueLum: hueLum, shadowTint: shadowTint, midTint: midTint,
                   highlightTint: highlightTint, monoTone: monoTone)
    }
}

/// Global engine calibration: how strong one "step" of each camera setting is.
/// Every recipe setting is multiplied through these, so tweaking a value here changes
/// what e.g. "Shadow +1" means everywhere.
struct EngineTuning: Codable, Equatable {
    var version: Int = 1

    // MARK: Tone / Dynamic range
    /// Display value (sRGB encoded) that 18% grey maps to.
    var midGrey: Double = 0.46
    /// Linear value treated as "white" for RAW files at DR100 (sensor clip headroom above mid grey).
    var rawWhite: Double = 1.6
    /// Same for live preview / processed (JPEG/HEIC) sources.
    var processedWhite: Double = 1.0
    /// Extra exposure applied when developing RAW files, EV.
    var rawExposure: Double = 0.3
    /// Multiplier on DR200 / DR400 stops (1 = one stop per DR step like the camera).
    var drStrength: Double = 1.0
    /// What DR-Auto resolves to, in stops (0 = DR100, 1 = DR200, 2 = DR400).
    var drAutoStops: Double = 1.0
    /// Highlight: curve bump per step (positive steps brighten & harden highlights).
    var highlightStep: Double = 0.10
    /// Highlight: stops of extra headroom per negative step (softer roll-off).
    var highlightRangeStep: Double = 0.12
    /// Shadow: curve bump per step (positive steps deepen shadows).
    var shadowStep: Double = 0.12
    /// Where highlight desaturation ("path to white") starts, display-linear.
    var highlightKnee: Double = 0.82

    // MARK: Color
    /// Chroma multiplier per Color step (+4 = 1 + 4 * step).
    var colorStep: Double = 0.075
    /// WB shift strength: stops of channel gain per Red/Blue step.
    var wbShiftStep: Double = 0.05
    var cceWeak: Double = 0.035
    var cceStrong: Double = 0.07
    var fxBlueWeak: Double = 0.06
    var fxBlueStrong: Double = 0.12
    /// Mono WC / MG toning per step (OkLab units).
    var monoToneStep: Double = 0.0035
    /// WB presets (Kelvin)
    var daylightK: Double = 5500
    var shadeK: Double = 7500
    var incandescentK: Double = 3000
    var fluorescent1K: Double = 6500
    var fluorescent2K: Double = 3000
    var fluorescent3K: Double = 4100
    var fluorescentTint: Double = 10
    /// How much Auto White Priority cools / Ambience Priority keeps warm light (fraction of distance to 5500K).
    var autoWhiteStrength: Double = 0.15
    var autoAmbienceStrength: Double = 0.25

    // MARK: Detail
    /// Sharpening amount at Sharpness 0 (RAW has no in-camera sharpening).
    var sharpBase: Double = 0.45
    var sharpStep: Double = 0.18
    /// Unsharp radius in px at 4032 px wide.
    var sharpRadius: Double = 1.0
    /// Clarity local-contrast amount per step.
    var clarityStep: Double = 0.09
    /// Clarity radius in px at 4032 px wide.
    var clarityRadius: Double = 28
    /// High ISO NR: each step scales Apple's default noise reduction by 2^(step * nrStep).
    var nrStep: Double = 0.35
    /// High ISO NR: fixed amount added per step (0...1 scale of Apple's NR).
    var nrAddStep: Double = 0.04
    /// Minimum chroma NR so colour noise never explodes.
    var nrColorFloor: Double = 0.3

    // MARK: Grain
    var grainWeak: Double = 0.011
    var grainStrong: Double = 0.02
    /// Grain size in px at 4032 px wide.
    var grainSmall: Double = 1.0
    var grainLarge: Double = 1.7
    /// Midtone concentration of grain (higher = less grain in deep shadows / highlights).
    var grainShape: Double = 0.6

    // MARK: Mono filters (channel transmission R, G, B)
    var filterYellow: [Double] = [1.0, 0.92, 0.35]
    var filterRed: [Double] = [1.0, 0.25, 0.08]
    var filterGreen: [Double] = [0.55, 1.0, 0.45]

    // MARK: Live preview
    /// The live feed is already tone-mapped by iOS; scale curve contrast so preview matches RAW output.
    var previewContrast: Double = 0.9
    var previewGrain: Double = 1.5

    // MARK: Film simulations
    var sims: [String: SimProfile] = EngineTuning.defaultSims

    func profile(_ key: SimProfileKey) -> SimProfile {
        sims[key.rawValue] ?? EngineTuning.defaultSims[key.rawValue]!
    }

    static let defaults = EngineTuning()

    // MARK: Default film simulation characters
    // Hue tables: [red, orange, yellow, green, aqua, blue, purple, magenta]
    static let defaultSims: [String: SimProfile] = [
        SimProfileKey.provia.rawValue: .make(
            contrast: 0.17, shadowRange: 6.5, saturation: 1.05, highlightSaturation: 0.95,
            hueSat: [1, 1, 1, 1, 1, 1.03, 1, 1],
            hueLum: [0, 0, 0, 0, 0, -0.02, 0, 0]),

        SimProfileKey.velvia.rawValue: .make(
            contrast: 0.195, shadowRange: 5.8, highlightTone: 0.5, shadowTone: 0.5,
            saturation: 1.32, shadowSaturation: 1.05, highlightSaturation: 0.95,
            hueShift: [-3, 0, -2, 2, 0, 3, 0, 0],
            hueSat: [1.1, 1.0, 1.05, 1.12, 1.05, 1.1, 1.1, 1.1],
            hueLum: [-0.03, 0, -0.01, -0.04, -0.02, -0.06, -0.03, -0.02]),

        SimProfileKey.astia.rawValue: .make(
            contrast: 0.16, shadowRange: 6.6, highlightTone: -0.5,
            saturation: 1.08, highlightSaturation: 0.92,
            hueShift: [2, 1, 0, 0, 0, 0, 0, 0],
            hueSat: [1.0, 0.94, 1.04, 1.08, 1.08, 1.12, 1.0, 0.98],
            hueLum: [0.01, 0.015, 0, 0, 0, -0.02, 0, 0],
            midTint: [0, 0.002]),

        SimProfileKey.classicChrome.rawValue: .make(
            contrast: 0.17, shadowRange: 5.9, highlightTone: -0.5, shadowTone: 1.0,
            saturation: 0.80, shadowSaturation: 0.9, highlightSaturation: 0.85,
            hueShift: [3, -2, -4, -8, -6, -10, -6, -4],
            hueSat: [0.95, 0.88, 0.78, 0.75, 0.85, 0.9, 0.75, 0.8],
            hueLum: [-0.04, 0, -0.02, -0.03, -0.03, -0.06, -0.02, -0.02],
            shadowTint: [-0.004, -0.002], highlightTint: [0.001, 0.005]),

        SimProfileKey.realaAce.rawValue: .make(
            contrast: 0.185, shadowRange: 6.0, highlightTone: 0.5, shadowTone: 0.5,
            saturation: 1.06, highlightSaturation: 0.95,
            hueShift: [-1, 0, -2, 2, 0, -2, 0, 0],
            hueSat: [1.04, 0.98, 1.0, 1.0, 1.02, 1.05, 1.0, 1.0],
            hueLum: [0, 0, 0, -0.01, 0, -0.02, 0, 0]),

        SimProfileKey.proNegHi.rawValue: .make(
            contrast: 0.175, shadowRange: 6.2, shadowTone: 0.5,
            saturation: 0.92,
            hueShift: [0, 0, 0, -3, 0, -4, 0, 0],
            hueSat: [1, 0.95, 1, 0.9, 1, 0.92, 1, 1],
            hueLum: [0, 0.01, 0, 0, 0, 0, 0, 0]),

        SimProfileKey.proNegStd.rawValue: .make(
            contrast: 0.145, shadowRange: 7.0, highlightTone: -1, shadowTone: -1,
            saturation: 0.82, highlightSaturation: 0.9,
            hueShift: [0, 0, -2, -4, 0, -5, 0, 0],
            hueSat: [1, 1, 0.9, 0.85, 1, 0.9, 1, 1],
            hueLum: [0, 0.01, 0, 0, 0, 0, 0, 0],
            shadowTint: [-0.002, -0.002]),

        SimProfileKey.classicNeg.rawValue: .make(
            contrast: 0.19, shadowRange: 5.7, highlightTone: 0.5, shadowTone: 1.0,
            saturation: 0.9, shadowSaturation: 0.95, highlightSaturation: 0.85,
            hueShift: [-5, -3, 6, 10, -4, -10, -4, 0],
            hueSat: [1.05, 0.9, 0.85, 0.88, 0.95, 0.92, 0.8, 0.9],
            hueLum: [-0.04, 0, 0, -0.04, -0.02, -0.04, -0.02, -0.02],
            shadowTint: [-0.010, -0.006], highlightTint: [0.003, 0.010]),

        SimProfileKey.nostalgicNeg.rawValue: .make(
            contrast: 0.17, shadowRange: 5.8, highlightTone: -1.0, shadowTone: 0.5,
            saturation: 1.0, shadowSaturation: 1.12, highlightSaturation: 0.95,
            hueShift: [3, 0, -5, -6, -2, -6, 0, 0],
            hueSat: [1.08, 1.04, 1.04, 0.9, 0.85, 0.88, 0.9, 0.95],
            hueLum: [-0.02, 0, -0.01, -0.02, 0, -0.02, 0, 0],
            shadowTint: [0.002, 0.002], midTint: [0.002, 0.006], highlightTint: [0.004, 0.016]),

        SimProfileKey.eterna.rawValue: .make(
            contrast: 0.125, shadowRange: 7.4, highlightTone: -1.0, shadowTone: -1.0, blackLift: 0.012,
            saturation: 0.68, highlightSaturation: 0.9,
            hueShift: [0, 0, -3, 6, 0, -6, 0, 0],
            hueSat: [0.9, 1.0, 0.85, 0.8, 0.9, 0.9, 0.85, 0.85],
            shadowTint: [-0.007, -0.005], highlightTint: [0.002, 0.005]),

        SimProfileKey.eternaBleach.rawValue: .make(
            contrast: 0.215, shadowRange: 5.2, highlightTone: 0.5, shadowTone: 1.0,
            saturation: 0.42, shadowSaturation: 0.85, highlightSaturation: 0.8,
            shadowTint: [-0.003, -0.004], highlightTint: [0, 0.002]),

        SimProfileKey.acros.rawValue: .make(
            contrast: 0.19, shadowRange: 5.8, highlightTone: 0.5, shadowTone: 1.0),

        SimProfileKey.monochrome.rawValue: .make(
            contrast: 0.165, shadowRange: 6.5),

        SimProfileKey.sepia.rawValue: .make(
            contrast: 0.16, shadowRange: 6.5, monoTone: [0.012, 0.035]),
    ]

    // MARK: Persistence helpers

    /// Decodes saved tuning on top of the current defaults so new parameters get sensible values.
    static func decodeMerged(from data: Data) -> EngineTuning? {
        guard let defaultsData = try? JSONEncoder().encode(EngineTuning.defaults),
              let base = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any],
              let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let merged = deepMerge(base, user)
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(EngineTuning.self, from: mergedData)
    }

    private static func deepMerge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let b = base[k] as? [String: Any], let o = v as? [String: Any] {
                out[k] = deepMerge(b, o)
            } else {
                out[k] = v
            }
        }
        return out
    }
}
