import Foundation

nonisolated enum HSLColorBand: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case red
    case orange
    case yellow
    case green
    case aqua
    case blue
    case purple
    case magenta

    var id: String { rawValue }

    var title: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .aqua: return "Aqua"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .magenta: return "Magenta"
        }
    }
}

nonisolated struct HSLBandAdjustment: Equatable, Hashable, Codable, Sendable {
    var hueShift: Double = 0
    var saturationDelta: Double = 0
    var lightnessDelta: Double = 0
}

nonisolated struct HSLAdjustments: Equatable, Hashable, Codable, Sendable {
    var red = HSLBandAdjustment()
    var orange = HSLBandAdjustment()
    var yellow = HSLBandAdjustment()
    var green = HSLBandAdjustment()
    var aqua = HSLBandAdjustment()
    var blue = HSLBandAdjustment()
    var purple = HSLBandAdjustment()
    var magenta = HSLBandAdjustment()

    static let neutral = HSLAdjustments()

    subscript(_ band: HSLColorBand) -> HSLBandAdjustment {
        get {
            switch band {
            case .red: return red
            case .orange: return orange
            case .yellow: return yellow
            case .green: return green
            case .aqua: return aqua
            case .blue: return blue
            case .purple: return purple
            case .magenta: return magenta
            }
        }
        set {
            switch band {
            case .red: red = newValue
            case .orange: orange = newValue
            case .yellow: yellow = newValue
            case .green: green = newValue
            case .aqua: aqua = newValue
            case .blue: blue = newValue
            case .purple: purple = newValue
            case .magenta: magenta = newValue
            }
        }
    }
}

nonisolated struct ColorGradeTone: Equatable, Hashable, Codable, Sendable {
    var hue: Double = 0
    var amount: Double = 0
}

nonisolated struct ColorGradingSettings: Equatable, Hashable, Codable, Sendable {
    var global = ColorGradeTone()
    var shadows = ColorGradeTone()
    var highlights = ColorGradeTone()

    static let neutral = ColorGradingSettings()
}

nonisolated struct PhotoEffectSettings: Equatable, Hashable, Codable, Sendable {
    var baseExposure: Double
    var highlights: Double
    var shadows: Double
    /// Contrast percentage offset where 0 = neutral (actual contrast = 1 + contrast / 100).
    var contrast: Double
    /// Saturation offset where 0 = neutral (actual saturation = 1 + saturation).
    var saturation: Double
    var vibrance: Double
    var warmth: Double
    var tint: Double
    var clarity: Double
    var sharpness: Double
    var bloomIntensity: Double
    var bloomRadius: Double
    var vignetteIntensity: Double
    var vignetteRadius: Double
    var grainAmount: Double
    var grainSize: Double
    var hsl: HSLAdjustments
    var colorGrading: ColorGradingSettings

    static let neutral = PhotoEffectSettings(
        baseExposure: 0,
        highlights: 0,
        shadows: 0,
        contrast: 0,
        saturation: 0,
        vibrance: 0,
        warmth: 0,
        tint: 0,
        clarity: 0,
        sharpness: 0,
        bloomIntensity: 0,
        bloomRadius: 0,
        vignetteIntensity: 0,
        vignetteRadius: 0,
        grainAmount: 0,
        grainSize: 1.0,
        hsl: .neutral,
        colorGrading: .neutral
    )

    static let baseExposureRange: ClosedRange<Double> = -2.0...2.0
    static let highlightsRange: ClosedRange<Double> = -1.0...1.0
    static let shadowsRange: ClosedRange<Double> = -1.0...1.0
    static let contrastRange: ClosedRange<Double> = -20...20
    static let saturationRange: ClosedRange<Double> = -0.7...0.7
    static let vibranceRange: ClosedRange<Double> = -0.5...0.5
    static let warmthRange: ClosedRange<Double> = -900...900
    static let tintRange: ClosedRange<Double> = -120...120
    static let clarityRange: ClosedRange<Double> = -1.0...1.0
    static let sharpnessRange: ClosedRange<Double> = -1.0...1.0
    static let bloomIntensityRange: ClosedRange<Double> = 0...0.85
    static let bloomRadiusRange: ClosedRange<Double> = 0...32
    static let vignetteIntensityRange: ClosedRange<Double> = 0...2.0
    static let vignetteRadiusRange: ClosedRange<Double> = 0...2.0
    static let grainAmountRange: ClosedRange<Double> = 0...0.22
    static let grainSizeRange: ClosedRange<Double> = 0.6...2.2

    static let hslHueRange: ClosedRange<Double> = -35...35
    static let hslSaturationRange: ClosedRange<Double> = -1.0...1.0
    static let hslLightnessRange: ClosedRange<Double> = -0.35...0.35
    static let colorGradeHueRange: ClosedRange<Double> = -180...180
    static let colorGradeAmountRange: ClosedRange<Double> = 0...1

    func clamped() -> PhotoEffectSettings {
        func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
            min(max(value, range.lowerBound), range.upperBound)
        }

        func clampedHSL(_ value: HSLBandAdjustment) -> HSLBandAdjustment {
            HSLBandAdjustment(
                hueShift: clamp(value.hueShift, to: Self.hslHueRange),
                saturationDelta: clamp(value.saturationDelta, to: Self.hslSaturationRange),
                lightnessDelta: clamp(value.lightnessDelta, to: Self.hslLightnessRange)
            )
        }

        func clampedTone(_ tone: ColorGradeTone) -> ColorGradeTone {
            ColorGradeTone(
                hue: clamp(tone.hue, to: Self.colorGradeHueRange),
                amount: clamp(tone.amount, to: Self.colorGradeAmountRange)
            )
        }

        var result = self
        result.baseExposure = clamp(result.baseExposure, to: Self.baseExposureRange)
        result.highlights = clamp(result.highlights, to: Self.highlightsRange)
        result.shadows = clamp(result.shadows, to: Self.shadowsRange)
        result.contrast = clamp(result.contrast, to: Self.contrastRange)
        result.saturation = clamp(result.saturation, to: Self.saturationRange)
        result.vibrance = clamp(result.vibrance, to: Self.vibranceRange)
        result.warmth = clamp(result.warmth, to: Self.warmthRange)
        result.tint = clamp(result.tint, to: Self.tintRange)
        result.clarity = clamp(result.clarity, to: Self.clarityRange)
        result.sharpness = clamp(result.sharpness, to: Self.sharpnessRange)
        result.bloomIntensity = clamp(result.bloomIntensity, to: Self.bloomIntensityRange)
        result.bloomRadius = clamp(result.bloomRadius, to: Self.bloomRadiusRange)
        result.vignetteIntensity = clamp(result.vignetteIntensity, to: Self.vignetteIntensityRange)
        result.vignetteRadius = clamp(result.vignetteRadius, to: Self.vignetteRadiusRange)
        result.grainAmount = clamp(result.grainAmount, to: Self.grainAmountRange)
        result.grainSize = clamp(result.grainSize, to: Self.grainSizeRange)

        result.hsl.red = clampedHSL(result.hsl.red)
        result.hsl.orange = clampedHSL(result.hsl.orange)
        result.hsl.yellow = clampedHSL(result.hsl.yellow)
        result.hsl.green = clampedHSL(result.hsl.green)
        result.hsl.aqua = clampedHSL(result.hsl.aqua)
        result.hsl.blue = clampedHSL(result.hsl.blue)
        result.hsl.purple = clampedHSL(result.hsl.purple)
        result.hsl.magenta = clampedHSL(result.hsl.magenta)

        result.colorGrading.global = clampedTone(result.colorGrading.global)
        result.colorGrading.shadows = clampedTone(result.colorGrading.shadows)
        result.colorGrading.highlights = clampedTone(result.colorGrading.highlights)
        return result
    }
}

extension PhotoEffectSettings {
    private enum CodingKeys: String, CodingKey {
        case baseExposure
        case highlights
        case shadows
        case contrast
        case saturation
        case vibrance
        case warmth
        case tint
        case clarity
        case sharpness
        case bloomIntensity
        case bloomRadius
        case vignetteIntensity
        case vignetteRadius
        case grainAmount
        case grainSize
        case hsl
        case colorGrading
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.neutral

        baseExposure = try container.decodeIfPresent(Double.self, forKey: .baseExposure) ?? defaults.baseExposure
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? defaults.highlights
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? defaults.shadows
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? defaults.contrast
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? defaults.saturation
        vibrance = try container.decodeIfPresent(Double.self, forKey: .vibrance) ?? defaults.vibrance
        warmth = try container.decodeIfPresent(Double.self, forKey: .warmth) ?? defaults.warmth
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? defaults.tint
        clarity = try container.decodeIfPresent(Double.self, forKey: .clarity) ?? defaults.clarity
        sharpness = try container.decodeIfPresent(Double.self, forKey: .sharpness) ?? defaults.sharpness
        bloomIntensity = try container.decodeIfPresent(Double.self, forKey: .bloomIntensity) ?? defaults.bloomIntensity
        bloomRadius = try container.decodeIfPresent(Double.self, forKey: .bloomRadius) ?? defaults.bloomRadius
        vignetteIntensity = try container.decodeIfPresent(Double.self, forKey: .vignetteIntensity) ?? defaults.vignetteIntensity
        vignetteRadius = try container.decodeIfPresent(Double.self, forKey: .vignetteRadius) ?? defaults.vignetteRadius
        grainAmount = try container.decodeIfPresent(Double.self, forKey: .grainAmount) ?? defaults.grainAmount
        grainSize = try container.decodeIfPresent(Double.self, forKey: .grainSize) ?? defaults.grainSize
        hsl = try container.decodeIfPresent(HSLAdjustments.self, forKey: .hsl) ?? defaults.hsl
        colorGrading = try container.decodeIfPresent(ColorGradingSettings.self, forKey: .colorGrading) ?? defaults.colorGrading
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseExposure, forKey: .baseExposure)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(shadows, forKey: .shadows)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(vibrance, forKey: .vibrance)
        try container.encode(warmth, forKey: .warmth)
        try container.encode(tint, forKey: .tint)
        try container.encode(clarity, forKey: .clarity)
        try container.encode(sharpness, forKey: .sharpness)
        try container.encode(bloomIntensity, forKey: .bloomIntensity)
        try container.encode(bloomRadius, forKey: .bloomRadius)
        try container.encode(vignetteIntensity, forKey: .vignetteIntensity)
        try container.encode(vignetteRadius, forKey: .vignetteRadius)
        try container.encode(grainAmount, forKey: .grainAmount)
        try container.encode(grainSize, forKey: .grainSize)
        try container.encode(hsl, forKey: .hsl)
        try container.encode(colorGrading, forKey: .colorGrading)
    }
}

nonisolated struct PhotoEffectPreset: Identifiable, Equatable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var settings: PhotoEffectSettings
}

nonisolated enum PhotoEffectLibrary {
    static let customPresetID = "custom"
}
