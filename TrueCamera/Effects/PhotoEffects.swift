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
    var hsl: HSLAdjustments
    var colorGrading: ColorGradingSettings

    static let neutral = PhotoEffectSettings(
        baseExposure: 0,
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
        hsl: .neutral,
        colorGrading: .neutral
    )

    static let baseExposureRange: ClosedRange<Double> = -2.0...2.0
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

    static let hslHueRange: ClosedRange<Double> = -35...35
    static let hslSaturationRange: ClosedRange<Double> = -0.5...0.5
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

nonisolated struct PhotoEffectPreset: Identifiable, Equatable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var settings: PhotoEffectSettings
}

nonisolated enum PhotoEffectLibrary {
    static let customPresetID = "custom"
}
