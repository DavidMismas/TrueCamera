import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit
import simd

nonisolated private struct ColorCubeKey: Hashable {
    let hsl: HSLAdjustments
    let grading: ColorGradingSettings
    let cubeDimension: Int
}

final class PhotoEffectsProcessor {
    private let context: CIContext
    private let previewCubeDimension = 12
    private let exportCubeDimension = 32
    private let cubeCacheLock = NSLock()
    nonisolated(unsafe) private var colorCubeCache: [ColorCubeKey: Data] = [:]

    nonisolated init(context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.context = context
    }

    nonisolated func renderPreviewImage(
        from pixelBuffer: CVPixelBuffer,
        settings: PhotoEffectSettings,
        isFrontCamera: Bool,
        maxDimension: CGFloat = 960
    ) -> UIImage? {
        let orientation: CGImagePropertyOrientation = isFrontCamera ? .rightMirrored : .right
        let input = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let graded = apply(
            to: input,
            settings: settings,
            includeGrain: true,
            cubeDimension: previewCubeDimension
        )

        let extent = graded.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }

        let scale = min(1, maxDimension / max(extent.width, extent.height))
        let outputImage: CIImage
        if scale < 1 {
            outputImage = graded.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            outputImage = graded
        }

        guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent.integral) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    nonisolated func renderProcessedJPEG(from imageData: Data, settings: PhotoEffectSettings) -> Data? {
        guard let input = CIImage(data: imageData, options: [.applyOrientationProperty: true]) else { return nil }
        // Grain intentionally excluded from final JPEG export.
        let graded = apply(
            to: input,
            settings: settings,
            includeGrain: false,
            cubeDimension: exportCubeDimension
        )
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return context.jpegRepresentation(
            of: graded,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95]
        )
    }

    nonisolated func renderReferencePreview(
        from image: UIImage,
        settings: PhotoEffectSettings,
        maxDimension: CGFloat = 1100,
        includeGrain: Bool = true
    ) -> UIImage? {
        let input: CIImage?
        if let cgImage = image.cgImage {
            input = CIImage(cgImage: cgImage)
        } else {
            input = CIImage(image: image)
        }
        guard let input else { return nil }

        let graded = apply(
            to: input,
            settings: settings,
            includeGrain: includeGrain,
            cubeDimension: previewCubeDimension
        )
        let extent = graded.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }

        let scale = min(1, maxDimension / max(extent.width, extent.height))
        let output = scale < 1
            ? graded.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : graded

        guard let cgImage = context.createCGImage(output, from: output.extent.integral) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    nonisolated private func apply(
        to image: CIImage,
        settings: PhotoEffectSettings,
        includeGrain: Bool,
        cubeDimension: Int
    ) -> CIImage {
        var output = image

        if abs(settings.baseExposure) > 0.0001 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = output
            exposure.ev = Float(settings.baseExposure)
            if let processed = exposure.outputImage {
                output = processed
            }
        }

        if abs(settings.contrast) > 0.0001 || abs(settings.saturation) > 0.0001 {
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.contrast = Float(max(0.01, 1.0 + (settings.contrast / 100.0)))
            controls.saturation = Float(max(0, 1.0 + settings.saturation))
            if let processed = controls.outputImage {
                output = processed
            }
        }

        if abs(settings.vibrance) > 0.0001 {
            let vibrance = CIFilter.vibrance()
            vibrance.inputImage = output
            vibrance.amount = Float(settings.vibrance)
            if let processed = vibrance.outputImage {
                output = processed
            }
        }

        if abs(settings.warmth) > 0.5 || abs(settings.tint) > 0.5 {
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = output
            temp.neutral = CIVector(x: 6500, y: 0)
            // UX mapping: positive warmth = warmer, positive tint = magenta.
            temp.targetNeutral = CIVector(x: 6500 - settings.warmth, y: -settings.tint)
            if let processed = temp.outputImage {
                output = processed
            }
        }

        if shouldApplyColorCube(for: settings) {
            output = applyHSLAndColorGrading(settings, to: output, cubeDimension: cubeDimension)
        }

        if abs(settings.clarity) > 0.0001 {
            output = applyClarity(settings.clarity, to: output)
        }

        if abs(settings.sharpness) > 0.0001 {
            output = applySharpness(settings.sharpness, to: output)
        }

        if settings.bloomIntensity > 0.0001 {
            let bloom = CIFilter.bloom()
            bloom.inputImage = output
            bloom.intensity = Float(settings.bloomIntensity)
            bloom.radius = Float(max(1.5, settings.bloomRadius))
            if let processed = bloom.outputImage {
                output = processed
            }
        }

        if settings.vignetteIntensity > 0.0001 {
            let vignette = CIFilter.vignette()
            vignette.inputImage = output
            vignette.intensity = Float(settings.vignetteIntensity * 1.8)
            vignette.radius = Float(max(0.01, settings.vignetteRadius))
            if let processed = vignette.outputImage {
                output = processed
            }
        }

        if includeGrain, settings.grainAmount > 0.0001 {
            output = addGrain(to: output, amount: settings.grainAmount)
        }

        return output.cropped(to: image.extent)
    }

    nonisolated private func shouldApplyColorCube(for settings: PhotoEffectSettings) -> Bool {
        if settings.colorGrading.global.amount > 0.0001 ||
            settings.colorGrading.shadows.amount > 0.0001 ||
            settings.colorGrading.highlights.amount > 0.0001 {
            return true
        }

        for band in HSLColorBand.allCases {
            let value = settings.hsl[band]
            if abs(value.hueShift) > 0.0001 ||
                abs(value.saturationDelta) > 0.0001 ||
                abs(value.lightnessDelta) > 0.0001 {
                return true
            }
        }
        return false
    }

    nonisolated private func applyHSLAndColorGrading(
        _ settings: PhotoEffectSettings,
        to image: CIImage,
        cubeDimension: Int
    ) -> CIImage {
        guard let cubeData = colorCubeData(for: settings, cubeDimension: cubeDimension) else { return image }
        guard let colorCube = CIFilter(name: "CIColorCubeWithColorSpace") else { return image }

        colorCube.setValue(image, forKey: kCIInputImageKey)
        colorCube.setValue(cubeDimension, forKey: "inputCubeDimension")
        colorCube.setValue(cubeData, forKey: "inputCubeData")
        if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) {
            colorCube.setValue(colorSpace, forKey: "inputColorSpace")
        }

        return colorCube.outputImage?.cropped(to: image.extent) ?? image
    }

    nonisolated private func colorCubeData(for settings: PhotoEffectSettings, cubeDimension: Int) -> Data? {
        if Task.isCancelled { return nil }
        let key = ColorCubeKey(hsl: settings.hsl, grading: settings.colorGrading, cubeDimension: cubeDimension)

        cubeCacheLock.lock()
        if let cached = colorCubeCache[key] {
            cubeCacheLock.unlock()
            return cached
        }
        cubeCacheLock.unlock()

        var cube = [Float](repeating: 0, count: cubeDimension * cubeDimension * cubeDimension * 4)
        var offset = 0

        for blue in 0 ..< cubeDimension {
            if Task.isCancelled { return nil }
            let b = Double(blue) / Double(cubeDimension - 1)
            for green in 0 ..< cubeDimension {
                let g = Double(green) / Double(cubeDimension - 1)
                for red in 0 ..< cubeDimension {
                    let r = Double(red) / Double(cubeDimension - 1)
                    var color = SIMD3<Double>(r, g, b)

                    color = applyHSLMix(to: color, hsl: settings.hsl)
                    color = applyColorGrading(to: color, grading: settings.colorGrading)

                    cube[offset] = Float(clamp(color.x, 0, 1))
                    cube[offset + 1] = Float(clamp(color.y, 0, 1))
                    cube[offset + 2] = Float(clamp(color.z, 0, 1))
                    cube[offset + 3] = 1
                    offset += 4
                }
            }
        }

        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        cubeCacheLock.lock()
        colorCubeCache[key] = data
        cubeCacheLock.unlock()
        return data
    }

    nonisolated private func applyHSLMix(to rgb: SIMD3<Double>, hsl: HSLAdjustments) -> SIMD3<Double> {
        var (hue, saturation, lightness) = rgbToHsl(rgb)

        var hueShiftSum = 0.0
        var satDeltaSum = 0.0
        var lightDeltaSum = 0.0
        var weightSum = 0.0

        for band in HSLColorBand.allCases {
            let adjustment = hsl[band]
            let weight = hueBandWeight(hue: hue, center: hueCenter(for: band), width: hueWidth(for: band))
            if weight <= 0.0001 { continue }
            hueShiftSum += adjustment.hueShift * weight
            satDeltaSum += adjustment.saturationDelta * weight
            lightDeltaSum += adjustment.lightnessDelta * weight
            weightSum += weight
        }

        if weightSum > 0 {
            hue += hueShiftSum / weightSum
            saturation *= (1 + (satDeltaSum / weightSum))
            lightness += (lightDeltaSum / weightSum)
        }

        hue = wrapHue(hue)
        saturation = clamp(saturation, 0, 1)
        lightness = clamp(lightness, 0, 1)
        return hslToRgb(h: hue, s: saturation, l: lightness)
    }

    nonisolated private func applyColorGrading(to rgb: SIMD3<Double>, grading: ColorGradingSettings) -> SIMD3<Double> {
        var output = rgb

        if grading.global.amount > 0.0001 {
            output = toneBand(output, toward: hueToneColor(grading.global.hue), t: grading.global.amount * 0.35)
        }

        let luminance = dot(output, SIMD3<Double>(0.2126, 0.7152, 0.0722))
        let shadowWeight = 1 - smoothstep(0.12, 0.55, luminance)
        let highlightWeight = smoothstep(0.45, 0.88, luminance)

        if grading.shadows.amount > 0.0001 {
            output = toneBand(
                output,
                toward: hueToneColor(grading.shadows.hue),
                t: grading.shadows.amount * shadowWeight * 0.7
            )
        }
        if grading.highlights.amount > 0.0001 {
            output = toneBand(
                output,
                toward: hueToneColor(grading.highlights.hue),
                t: grading.highlights.amount * highlightWeight * 0.7
            )
        }

        return SIMD3<Double>(
            clamp(output.x, 0, 1),
            clamp(output.y, 0, 1),
            clamp(output.z, 0, 1)
        )
    }

    nonisolated private func applyClarity(_ value: Double, to image: CIImage) -> CIImage {
        if value > 0 {
            let unsharp = CIFilter.unsharpMask()
            unsharp.inputImage = image
            unsharp.radius = 2.0
            unsharp.intensity = Float(value * 1.6)
            return unsharp.outputImage?.cropped(to: image.extent) ?? image
        }

        // Negative clarity: soft local-contrast reduction.
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image
        blur.radius = Float(abs(value) * 2.2)
        guard let blurred = blur.outputImage?.cropped(to: image.extent) else { return image }
        return blend(blurred, over: image, amount: abs(value) * 0.35)
    }

    nonisolated private func applySharpness(_ value: Double, to image: CIImage) -> CIImage {
        if value > 0 {
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = image
            sharpen.sharpness = Float(value * 1.7)
            return sharpen.outputImage?.cropped(to: image.extent) ?? image
        }

        // Negative sharpness: additional softening.
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image
        blur.radius = Float(abs(value) * 1.4)
        guard let blurred = blur.outputImage?.cropped(to: image.extent) else { return image }
        return blend(blurred, over: image, amount: abs(value) * 0.5)
    }

    nonisolated private func blend(_ foreground: CIImage, over background: CIImage, amount: Double) -> CIImage {
        let alpha = clamp(amount, 0, 1)
        let alphaMatrix = CIFilter.colorMatrix()
        alphaMatrix.inputImage = foreground
        alphaMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: alpha)
        alphaMatrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        guard let alphaForeground = alphaMatrix.outputImage else { return background }

        let composite = CIFilter.sourceOverCompositing()
        composite.inputImage = alphaForeground
        composite.backgroundImage = background
        return composite.outputImage?.cropped(to: background.extent) ?? background
    }

    /// Mix toward a tint color then rescale to the original luminance.
    /// This shifts chrominance while preserving perceived brightness.
    nonisolated private func toneBand(_ rgb: SIMD3<Double>, toward toneColor: SIMD3<Double>, t: Double) -> SIMD3<Double> {
        guard t > 0.0001 else { return rgb }
        let inLum = dot(rgb, SIMD3<Double>(0.2126, 0.7152, 0.0722))
        let blended = rgb * (1 - t) + toneColor * t
        let outLum = dot(blended, SIMD3<Double>(0.2126, 0.7152, 0.0722))
        guard outLum > 0.0001 else { return rgb }
        return blended * (inLum / outLum)
    }

    nonisolated private func hueToneColor(_ hue: Double) -> SIMD3<Double> {
        let wrapped = wrapHue(hue)
        return hslToRgb(h: wrapped, s: 1, l: 0.5)
    }

    nonisolated private func hueCenter(for band: HSLColorBand) -> Double {
        switch band {
        case .red: return 0
        case .orange: return 32
        case .yellow: return 62
        case .green: return 122
        case .aqua: return 178
        case .blue: return 225
        case .purple: return 275
        case .magenta: return 318
        }
    }

    nonisolated private func hueWidth(for band: HSLColorBand) -> Double {
        switch band {
        case .red, .orange: return 40
        default: return 44
        }
    }

    nonisolated private func hueBandWeight(hue: Double, center: Double, width: Double) -> Double {
        let d = angularDistance(a: hue, b: center)
        if d >= width { return 0 }
        let normalized = 1 - (d / width)
        return normalized * normalized
    }

    nonisolated private func angularDistance(a: Double, b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(diff, 360 - diff)
    }

    nonisolated private func wrapHue(_ value: Double) -> Double {
        var h = value.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return h
    }

    nonisolated private func rgbToHsl(_ rgb: SIMD3<Double>) -> (Double, Double, Double) {
        let r = rgb.x
        let g = rgb.y
        let b = rgb.z

        let maxValue = max(r, max(g, b))
        let minValue = min(r, min(g, b))
        let delta = maxValue - minValue
        let lightness = (maxValue + minValue) / 2

        if delta == 0 {
            return (0, 0, lightness)
        }

        let saturation = delta / (1 - abs((2 * lightness) - 1))
        var hue: Double

        if maxValue == r {
            hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
        } else if maxValue == g {
            hue = 60 * (((b - r) / delta) + 2)
        } else {
            hue = 60 * (((r - g) / delta) + 4)
        }

        if hue < 0 { hue += 360 }
        return (hue, saturation, lightness)
    }

    nonisolated private func hslToRgb(h: Double, s: Double, l: Double) -> SIMD3<Double> {
        if s == 0 {
            return SIMD3<Double>(l, l, l)
        }

        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs(((h / 60).truncatingRemainder(dividingBy: 2)) - 1))
        let m = l - (c / 2)

        let rgbPrime: SIMD3<Double>
        switch h {
        case 0 ..< 60: rgbPrime = SIMD3<Double>(c, x, 0)
        case 60 ..< 120: rgbPrime = SIMD3<Double>(x, c, 0)
        case 120 ..< 180: rgbPrime = SIMD3<Double>(0, c, x)
        case 180 ..< 240: rgbPrime = SIMD3<Double>(0, x, c)
        case 240 ..< 300: rgbPrime = SIMD3<Double>(x, 0, c)
        default: rgbPrime = SIMD3<Double>(c, 0, x)
        }

        return SIMD3<Double>(rgbPrime.x + m, rgbPrime.y + m, rgbPrime.z + m)
    }

    nonisolated private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = clamp((x - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    nonisolated private func clamp(_ value: Double, _ minValue: Double, _ maxValue: Double) -> Double {
        min(max(value, minValue), maxValue)
    }

    nonisolated private func addGrain(to image: CIImage, amount: Double) -> CIImage {
        let extent = image.extent

        let random = CIFilter.randomGenerator()
        guard var noise = random.outputImage?.cropped(to: extent) else { return image }

        let monochrome = CIFilter.colorMonochrome()
        monochrome.inputImage = noise
        monochrome.intensity = 1
        monochrome.color = CIColor(red: 0.5, green: 0.5, blue: 0.5)
        if let monoNoise = monochrome.outputImage {
            noise = monoNoise
        }

        let noisyContrast = CIFilter.colorControls()
        noisyContrast.inputImage = noise
        noisyContrast.contrast = 1.8
        noisyContrast.brightness = -0.05
        if let shapedNoise = noisyContrast.outputImage {
            noise = shapedNoise
        }

        let alphaMatrix = CIFilter.colorMatrix()
        alphaMatrix.inputImage = noise
        alphaMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: amount)
        alphaMatrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        if let alphaNoise = alphaMatrix.outputImage {
            noise = alphaNoise
        }

        let blend = CIFilter.overlayBlendMode()
        blend.inputImage = noise
        blend.backgroundImage = image
        return blend.outputImage?.cropped(to: extent) ?? image
    }
}
