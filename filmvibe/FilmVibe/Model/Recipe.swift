import Foundation

// MARK: - Fujifilm-style settings

enum FilmSimulation: String, Codable, CaseIterable, Identifiable, Hashable {
    case provia, velvia, astia, classicChrome, realaAce, proNegHi, proNegStd, classicNeg, nostalgicNeg, eterna, eternaBleach
    case acros, acrosYe, acrosR, acrosG
    case monochrome, monochromeYe, monochromeR, monochromeG
    case sepia

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
        case .acrosYe: return "Acros + Ye"
        case .acrosR: return "Acros + R"
        case .acrosG: return "Acros + G"
        case .monochrome: return "Monochrome"
        case .monochromeYe: return "Monochrome + Ye"
        case .monochromeR: return "Monochrome + R"
        case .monochromeG: return "Monochrome + G"
        case .sepia: return "Sepia"
        }
    }

    /// Short label in the style of the camera's on-screen icons.
    var badge: String {
        switch self {
        case .provia: return "STD"
        case .velvia: return "V"
        case .astia: return "S"
        case .classicChrome: return "CC"
        case .realaAce: return "RA"
        case .proNegHi: return "NH"
        case .proNegStd: return "NS"
        case .classicNeg: return "NC"
        case .nostalgicNeg: return "NN"
        case .eterna: return "E"
        case .eternaBleach: return "EB"
        case .acros: return "A"
        case .acrosYe: return "A+Ye"
        case .acrosR: return "A+R"
        case .acrosG: return "A+G"
        case .monochrome: return "B"
        case .monochromeYe: return "B+Ye"
        case .monochromeR: return "B+R"
        case .monochromeG: return "B+G"
        case .sepia: return "SEPIA"
        }
    }

    var isMonochrome: Bool {
        switch self {
        case .acros, .acrosYe, .acrosR, .acrosG, .monochrome, .monochromeYe, .monochromeR, .monochromeG, .sepia: return true
        default: return false
        }
    }

    /// The tunable base profile behind this simulation (filters share their base profile).
    var profileKey: SimProfileKey {
        switch self {
        case .provia: return .provia
        case .velvia: return .velvia
        case .astia: return .astia
        case .classicChrome: return .classicChrome
        case .realaAce: return .realaAce
        case .proNegHi: return .proNegHi
        case .proNegStd: return .proNegStd
        case .classicNeg: return .classicNeg
        case .nostalgicNeg: return .nostalgicNeg
        case .eterna: return .eterna
        case .eternaBleach: return .eternaBleach
        case .acros, .acrosYe, .acrosR, .acrosG: return .acros
        case .monochrome, .monochromeYe, .monochromeR, .monochromeG: return .monochrome
        case .sepia: return .sepia
        }
    }

    var monoFilter: MonoFilter {
        switch self {
        case .acrosYe, .monochromeYe: return .yellow
        case .acrosR, .monochromeR: return .red
        case .acrosG, .monochromeG: return .green
        default: return .none
        }
    }
}

enum MonoFilter: String, Codable, CaseIterable { case none, yellow, red, green }

enum EffectLevel: String, Codable, CaseIterable, Identifiable, Hashable {
    case off, weak, strong
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum GrainSize: String, Codable, CaseIterable, Identifiable, Hashable {
    case small, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum WBMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case auto, autoWhite, autoAmbience, daylight, shade, fluorescent1, fluorescent2, fluorescent3, incandescent, kelvin
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .autoWhite: return "Auto White Priority"
        case .autoAmbience: return "Auto Ambience Priority"
        case .daylight: return "Daylight"
        case .shade: return "Shade"
        case .fluorescent1: return "Fluorescent 1"
        case .fluorescent2: return "Fluorescent 2"
        case .fluorescent3: return "Fluorescent 3"
        case .incandescent: return "Incandescent"
        case .kelvin: return "Kelvin"
        }
    }
    var shortLabel: String {
        switch self {
        case .auto: return "AWB"
        case .autoWhite: return "AWB-W"
        case .autoAmbience: return "AWB-A"
        case .daylight: return "Daylight"
        case .shade: return "Shade"
        case .fluorescent1: return "Fluor 1"
        case .fluorescent2: return "Fluor 2"
        case .fluorescent3: return "Fluor 3"
        case .incandescent: return "Incand."
        case .kelvin: return "K"
        }
    }
    var isAuto: Bool { self == .auto || self == .autoWhite || self == .autoAmbience }
}

struct WhiteBalance: Codable, Equatable, Hashable {
    var mode: WBMode
    var kelvin: Int
    var red: Int
    var blue: Int

    var summary: String {
        let head = mode == .kelvin ? "\(kelvin)K" : mode.shortLabel
        return "\(head) \(red.signedString)R \(blue.signedString)B"
    }
}

enum DynamicRange: String, Codable, CaseIterable, Identifiable, Hashable {
    case dr100, dr200, dr400, auto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dr100: return "DR100"
        case .dr200: return "DR200"
        case .dr400: return "DR400"
        case .auto: return "DR-Auto"
        }
    }
}

enum DRangePriority: String, Codable, CaseIterable, Identifiable, Hashable {
    case off, auto, weak, strong
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .auto: return "Auto"
        case .weak: return "Weak"
        case .strong: return "Strong"
        }
    }
}

// MARK: - Recipe

struct Recipe: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var category: String
    var source: String?

    var filmSimulation: FilmSimulation
    var grainEffect: EffectLevel
    var grainSize: GrainSize
    var colorChrome: EffectLevel
    var colorChromeBlue: EffectLevel
    var whiteBalance: WhiteBalance
    var dynamicRange: DynamicRange
    var dRangePriority: DRangePriority
    /// -2 ... +4 in 0.5 steps
    var highlight: Double
    /// -2 ... +4 in 0.5 steps
    var shadow: Double
    /// -4 ... +4
    var color: Int
    /// -4 ... +4
    var sharpness: Int
    /// -4 ... +4
    var highISONR: Int
    /// -5 ... +5
    var clarity: Int
    var isoMax: Int
    /// Suggested exposure compensation used by the camera, in EV.
    var exposureComp: Double
    var exposureNote: String?
    /// Monochromatic Color, -18 ... +18
    var monoWC: Int
    var monoMG: Int

    static let neutral = Recipe(
        id: "custom-neutral", name: "Provia Standard", category: "Custom", source: nil,
        filmSimulation: .provia, grainEffect: .off, grainSize: .small, colorChrome: .off, colorChromeBlue: .off,
        whiteBalance: WhiteBalance(mode: .auto, kelvin: 5500, red: 0, blue: 0),
        dynamicRange: .dr100, dRangePriority: .off, highlight: 0, shadow: 0, color: 0, sharpness: 0,
        highISONR: 0, clarity: 0, isoMax: 6400, exposureComp: 0, exposureNote: nil, monoWC: 0, monoMG: 0)

    enum CodingKeys: String, CodingKey {
        case id, name, category, source, filmSimulation, grainEffect, grainSize, colorChrome, colorChromeBlue,
             whiteBalance, dynamicRange, dRangePriority, highlight, shadow, color, sharpness, highISONR, clarity,
             isoMax, exposureComp, exposureNote, monoWC, monoMG
    }

    init(id: String, name: String, category: String, source: String?, filmSimulation: FilmSimulation,
         grainEffect: EffectLevel, grainSize: GrainSize, colorChrome: EffectLevel, colorChromeBlue: EffectLevel,
         whiteBalance: WhiteBalance, dynamicRange: DynamicRange, dRangePriority: DRangePriority, highlight: Double,
         shadow: Double, color: Int, sharpness: Int, highISONR: Int, clarity: Int, isoMax: Int, exposureComp: Double,
         exposureNote: String?, monoWC: Int, monoMG: Int) {
        self.id = id; self.name = name; self.category = category; self.source = source
        self.filmSimulation = filmSimulation; self.grainEffect = grainEffect; self.grainSize = grainSize
        self.colorChrome = colorChrome; self.colorChromeBlue = colorChromeBlue; self.whiteBalance = whiteBalance
        self.dynamicRange = dynamicRange; self.dRangePriority = dRangePriority; self.highlight = highlight
        self.shadow = shadow; self.color = color; self.sharpness = sharpness; self.highISONR = highISONR
        self.clarity = clarity; self.isoMax = isoMax; self.exposureComp = exposureComp
        self.exposureNote = exposureNote; self.monoWC = monoWC; self.monoMG = monoMG
    }

    // Tolerant decoding so older saved recipes keep working when fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Recipe.neutral
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "Custom"
        source = try c.decodeIfPresent(String.self, forKey: .source)
        filmSimulation = try c.decodeIfPresent(FilmSimulation.self, forKey: .filmSimulation) ?? d.filmSimulation
        grainEffect = try c.decodeIfPresent(EffectLevel.self, forKey: .grainEffect) ?? d.grainEffect
        grainSize = try c.decodeIfPresent(GrainSize.self, forKey: .grainSize) ?? d.grainSize
        colorChrome = try c.decodeIfPresent(EffectLevel.self, forKey: .colorChrome) ?? d.colorChrome
        colorChromeBlue = try c.decodeIfPresent(EffectLevel.self, forKey: .colorChromeBlue) ?? d.colorChromeBlue
        whiteBalance = try c.decodeIfPresent(WhiteBalance.self, forKey: .whiteBalance) ?? d.whiteBalance
        dynamicRange = try c.decodeIfPresent(DynamicRange.self, forKey: .dynamicRange) ?? d.dynamicRange
        dRangePriority = try c.decodeIfPresent(DRangePriority.self, forKey: .dRangePriority) ?? d.dRangePriority
        highlight = try c.decodeIfPresent(Double.self, forKey: .highlight) ?? 0
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? 0
        color = try c.decodeIfPresent(Int.self, forKey: .color) ?? 0
        sharpness = try c.decodeIfPresent(Int.self, forKey: .sharpness) ?? 0
        highISONR = try c.decodeIfPresent(Int.self, forKey: .highISONR) ?? 0
        clarity = try c.decodeIfPresent(Int.self, forKey: .clarity) ?? 0
        isoMax = try c.decodeIfPresent(Int.self, forKey: .isoMax) ?? 6400
        exposureComp = try c.decodeIfPresent(Double.self, forKey: .exposureComp) ?? 0
        exposureNote = try c.decodeIfPresent(String.self, forKey: .exposureNote)
        monoWC = try c.decodeIfPresent(Int.self, forKey: .monoWC) ?? 0
        monoMG = try c.decodeIfPresent(Int.self, forKey: .monoMG) ?? 0
    }

    /// True when D-Range Priority is active, which takes over Highlight / Shadow like on the camera.
    var usesDRangePriority: Bool { dRangePriority != .off }

    /// One-line summary for lists.
    var summary: String {
        var parts: [String] = [filmSimulation.displayName]
        if usesDRangePriority {
            parts.append("DR-P \(dRangePriority.label)")
        } else {
            parts.append(dynamicRange.label)
            parts.append("H\(highlight.toneString) S\(shadow.toneString)")
        }
        if !filmSimulation.isMonochrome { parts.append("Color \(color.signedString)") }
        parts.append(whiteBalance.summary)
        return parts.joined(separator: " · ")
    }

    func duplicated(named newName: String) -> Recipe {
        var r = self
        r.id = "custom-" + UUID().uuidString.lowercased()
        r.name = newName
        r.category = "My Recipes"
        return r
    }
}

// MARK: - Formatting helpers

extension Int {
    var signedString: String { self > 0 ? "+\(self)" : "\(self)" }
}

extension Double {
    /// Highlight / Shadow style: "+1.5", "0", "-2"
    var toneString: String {
        let isWhole = self.rounded() == self
        let body = isWhole ? String(Int(self)) : String(format: "%.1f", self)
        return self > 0 ? "+" + body : body
    }

    /// Exposure value as camera-style thirds: "+2/3", "-1 1/3", "0"
    var evString: String {
        let thirds = Int((self * 3).rounded())
        if thirds == 0 { return "±0" }
        let sign = thirds > 0 ? "+" : "−"
        let a = abs(thirds)
        let whole = a / 3, rem = a % 3
        if rem == 0 { return "\(sign)\(whole)" }
        if whole == 0 { return "\(sign)\(rem)/3" }
        return "\(sign)\(whole) \(rem)/3"
    }
}
