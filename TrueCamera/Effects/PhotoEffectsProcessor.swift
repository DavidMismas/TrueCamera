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

nonisolated private struct SendableFloatPointer: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Float>
}

final class PhotoEffectsProcessor {
    private let previewContext: CIContext
    private let exportContext: CIContext
    private let exportColorSpace: CGColorSpace
    private let previewCubeDimension = 14
    private let exportCubeDimension = 80
    private let cubeCacheLock = NSLock()
    nonisolated(unsafe) private var colorCubeCache: [ColorCubeKey: Data] = [:]

    nonisolated init(
        previewContext: CIContext = CIContext(options: [.cacheIntermediates: false]),
        exportContext: CIContext = PhotoEffectsProcessor.makeHighPrecisionExportContext()
    ) {
        self.previewContext = previewContext
        self.exportContext = exportContext
        self.exportColorSpace = PhotoEffectsProcessor.makeExportColorSpace()
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

        guard let cgImage = previewContext.createCGImage(outputImage, from: outputImage.extent.integral) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    nonisolated func renderProcessedImageData(
        rawData: Data?,
        processedData: Data?,
        settings: PhotoEffectSettings,
        preferredHEIFBitDepth: StyledHEIFBitDepth = .tenBit,
        preferredProcessingSource: StyledProcessingSource = .proRAW
    ) -> (data: Data, uniformTypeIdentifier: String)? {
        if shouldBypassNeutralProcessing(settings),
           let processedData,
           let passthroughUTI = detectedPassthroughUTI(for: processedData) {
            return (data: processedData, uniformTypeIdentifier: passthroughUTI)
        }

        guard let input = makeExportInputImage(
            rawData: rawData,
            processedData: processedData,
            preferredProcessingSource: preferredProcessingSource
        ) else { return nil }
        // Grain intentionally excluded from final styled export.
        let graded = apply(
            to: input,
            settings: settings,
            includeGrain: false,
            cubeDimension: exportCubeDimension
        )
        let options: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 1.0,
            kCGImageDestinationEmbedThumbnail as CIImageRepresentationOption: true,
        ]
        if preferredHEIFBitDepth == .tenBit,
           #available(iOS 15.0, *),
           let heif10 = try? exportContext.heif10Representation(of: graded, colorSpace: exportColorSpace, options: options) {
            return (data: heif10, uniformTypeIdentifier: "public.heic")
        }
        if let heif = exportContext.heifRepresentation(of: graded, format: .RGBA8, colorSpace: exportColorSpace, options: options) {
            return (data: heif, uniformTypeIdentifier: "public.heic")
        }
        guard let jpeg = exportContext.jpegRepresentation(of: graded, colorSpace: exportColorSpace, options: options) else {
            return nil
        }
        return (data: jpeg, uniformTypeIdentifier: "public.jpeg")
    }

    nonisolated private func detectedPassthroughUTI(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { return nil }
        if type == "public.heic" || type.contains("heic") {
            return "public.heic"
        }
        if type == "public.jpeg" || type.contains("jpeg") {
            return "public.jpeg"
        }
        return nil
    }

    nonisolated private func shouldBypassNeutralProcessing(_ settings: PhotoEffectSettings) -> Bool {
        abs(settings.baseExposure) < 0.0001 &&
            abs(settings.highlights) < 0.0001 &&
            abs(settings.shadows) < 0.0001 &&
            abs(settings.contrast) < 0.0001 &&
            abs(settings.saturation) < 0.0001 &&
            abs(settings.vibrance) < 0.0001 &&
            abs(settings.warmth) < 0.5 &&
            abs(settings.tint) < 0.5 &&
            abs(settings.clarity) < 0.0001 &&
            abs(settings.sharpness) < 0.0001 &&
            settings.bloomIntensity < 0.0001 &&
            settings.vignetteIntensity < 0.0001 &&
            settings.grainAmount < 0.0001 &&
            settings.hsl == .neutral &&
            settings.colorGrading == .neutral
    }

    /// Precomputes expensive LUT resources for the current export settings.
    /// Keeps final quality identical while reducing shutter-to-save latency.
    nonisolated func prewarmExportPipeline(for settings: PhotoEffectSettings) {
        guard shouldApplyColorCube(for: settings) else { return }
        _ = colorCubeData(for: settings, cubeDimension: exportCubeDimension)
    }

    nonisolated private func makeExportInputImage(
        rawData: Data?,
        processedData: Data?,
        preferredProcessingSource: StyledProcessingSource
    ) -> CIImage? {
        switch preferredProcessingSource {
        case .proRAW:
            if let rawData, let rawImage = decodeRawImage(from: rawData) {
                return rawImage
            }
            if let processedData, let processedImage = CIImage(data: processedData, options: [.applyOrientationProperty: true]) {
                return processedImage
            }
            return nil
        case .processed:
            if let processedData, let processedImage = CIImage(data: processedData, options: [.applyOrientationProperty: true]) {
                return processedImage
            }
            if let rawData, let rawImage = decodeRawImage(from: rawData) {
                return rawImage
            }
            return nil
        }
    }

    nonisolated private func decodeRawImage(from rawData: Data) -> CIImage? {
        if let rawFilter = CIFilter(
            imageData: rawData,
            options: [CIRAWFilterOption.allowDraftMode: false]
        ) as? CIRAWFilter,
           let output = configureRAWDevelopmentAndRender(rawFilter: rawFilter) {
            return output
        }
        return CIImage(data: rawData, options: [.applyOrientationProperty: true])
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

        guard let cgImage = previewContext.createCGImage(output, from: output.extent.integral) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    nonisolated private static func makeExportColorSpace() -> CGColorSpace {
        CGColorSpace(name: CGColorSpace.displayP3) ??
            CGColorSpace(name: CGColorSpace.sRGB) ??
            CGColorSpaceCreateDeviceRGB()
    }

    nonisolated private static func makeHighPrecisionExportContext() -> CIContext {
        var options: [CIContextOption: Any] = [
            .cacheIntermediates: true,
            .workingFormat: CIFormat.RGBAh.rawValue,
        ]
        if let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
            options[.workingColorSpace] = linearP3
        } else if let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) {
            options[.workingColorSpace] = linearSRGB
        }
        return CIContext(options: options)
    }

    nonisolated private func configureRAWDevelopmentAndRender(rawFilter: CIRAWFilter) -> CIImage? {
        // Keep RAW development predictable: no draft decode and no aggressive local tone mapping.
        rawFilter.isDraftModeEnabled = false
        rawFilter.scaleFactor = 1
        rawFilter.exposure = 0
        // Lower global RAW tone-curve to preserve headroom in bright/dark extremes.
        rawFilter.boostAmount = min(rawFilter.boostAmount, 0.35)
        rawFilter.boostShadowAmount = min(rawFilter.boostShadowAmount, 0.95)
        rawFilter.isGamutMappingEnabled = true
        rawFilter.extendedDynamicRangeAmount = 0

        if #available(iOS 16.0, *), rawFilter.isHighlightRecoverySupported {
            rawFilter.isHighlightRecoveryEnabled = true
        }
        if rawFilter.isLocalToneMapSupported {
            rawFilter.localToneMapAmount = 0
        }

        return rawFilter.outputImage
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

        if abs(settings.highlights) > 0.0001 || abs(settings.shadows) > 0.0001 {
            let tonal = CIFilter.highlightShadowAdjust()
            tonal.inputImage = output
            // Neutral is highlightAmount = 1 and shadowAmount = 0.
            tonal.highlightAmount = Float(max(0.25, min(1.75, 1 + (settings.highlights * 0.72))))
            tonal.shadowAmount = Float(max(-0.85, min(0.85, settings.shadows * 0.82)))
            if let processed = tonal.outputImage {
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
            let sourceTone = output
            output = applyHSLAndColorGrading(settings, to: output, cubeDimension: cubeDimension)
            if shouldPreserveSourceLuminanceAfterGrading(settings) {
                output = preserveSourceLuminance(from: sourceTone, to: output)
            }
        }

        if abs(settings.clarity) > 0.0001 {
            output = applyClarity(settings.clarity, to: output)
        }

        if abs(settings.sharpness) > 0.0001 {
            output = applySharpness(settings.sharpness, to: output)
        }

        if shouldApplyExtremeToneProtection(for: settings) {
            output = applyExtremeToneProtection(to: output)
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

    nonisolated private func shouldApplyExtremeToneProtection(for settings: PhotoEffectSettings) -> Bool {
        abs(settings.baseExposure) > 0.0001 ||
            abs(settings.highlights) > 0.0001 ||
            abs(settings.shadows) > 0.0001 ||
            abs(settings.contrast) > 0.0001 ||
            abs(settings.saturation) > 0.0001 ||
            abs(settings.vibrance) > 0.0001 ||
            abs(settings.warmth) > 0.5 ||
            abs(settings.tint) > 0.5 ||
            abs(settings.clarity) > 0.0001 ||
            abs(settings.sharpness) > 0.0001 ||
            settings.bloomIntensity > 0.0001 ||
            settings.vignetteIntensity > 0.0001 ||
            settings.hsl != .neutral ||
            settings.colorGrading != .neutral
    }

    nonisolated private func applyExtremeToneProtection(to image: CIImage) -> CIImage {
        var output = image

        if let toneCurve = CIFilter(name: "CIToneCurve") {
            toneCurve.setValue(output, forKey: kCIInputImageKey)
            // Soft toe + shoulder to avoid hard black/white clipping after grading.
            toneCurve.setValue(CIVector(x: 0.00, y: 0.014), forKey: "inputPoint0")
            toneCurve.setValue(CIVector(x: 0.12, y: 0.124), forKey: "inputPoint1")
            toneCurve.setValue(CIVector(x: 0.50, y: 0.50), forKey: "inputPoint2")
            toneCurve.setValue(CIVector(x: 0.88, y: 0.872), forKey: "inputPoint3")
            toneCurve.setValue(CIVector(x: 1.00, y: 0.988), forKey: "inputPoint4")
            if let curved = toneCurve.outputImage {
                output = curved
            }
        }

        let highlightShadow = CIFilter.highlightShadowAdjust()
        highlightShadow.inputImage = output
        highlightShadow.shadowAmount = 0.03
        highlightShadow.highlightAmount = 0.985
        return highlightShadow.outputImage?.cropped(to: image.extent) ?? output
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

        let totalEntries = cubeDimension * cubeDimension * cubeDimension
        var cube = [Float](repeating: 0, count: totalEntries * 4)
        cube.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let sendableBase = SendableFloatPointer(pointer: baseAddress)

            DispatchQueue.concurrentPerform(iterations: totalEntries) { index in
                let red = index % cubeDimension
                let green = (index / cubeDimension) % cubeDimension
                let blue = index / (cubeDimension * cubeDimension)

                let r = Double(red) / Double(cubeDimension - 1)
                let g = Double(green) / Double(cubeDimension - 1)
                let b = Double(blue) / Double(cubeDimension - 1)
                var color = SIMD3<Double>(r, g, b)

                color = applyHSLMix(to: color, hsl: settings.hsl)
                color = applyColorGrading(to: color, grading: settings.colorGrading)

                let offset = index * 4
                sendableBase.pointer[offset] = Float(clamp(color.x, 0, 1))
                sendableBase.pointer[offset + 1] = Float(clamp(color.y, 0, 1))
                sendableBase.pointer[offset + 2] = Float(clamp(color.z, 0, 1))
                sendableBase.pointer[offset + 3] = 1
            }
        }

        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        cubeCacheLock.lock()
        if colorCubeCache.count >= 6 {
            colorCubeCache.removeAll(keepingCapacity: true)
        }
        colorCubeCache[key] = data
        cubeCacheLock.unlock()
        return data
    }

    nonisolated private func applyHSLMix(to rgb: SIMD3<Double>, hsl: HSLAdjustments) -> SIMD3<Double> {
        let original = rgb
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
        let adjusted = hslToRgb(h: hue, s: saturation, l: lightness)

        // Hue in near-neutral pixels is unstable and creates blotchy walls/highlights.
        let chromaWeight = smoothstep(0.10, 0.34, rgbSaturation(original))
        let shadowGuard = smoothstep(0.04, 0.14, lightness)
        let highlightGuard = 1 - smoothstep(0.90, 0.98, lightness)
        let protection = chromaWeight * shadowGuard * highlightGuard
        return mix(original, adjusted, t: protection)
    }

    nonisolated private func applyColorGrading(to rgb: SIMD3<Double>, grading: ColorGradingSettings) -> SIMD3<Double> {
        var output = rgb
        let saturation = rgbSaturation(output)
        // Avoid tint speckling and blotchy artifacts in near-neutral fog/sky regions.
        let chromaWeight = smoothstep(0.06, 0.24, saturation)
        guard chromaWeight > 0.0001 else { return output }

        let luminance = dot(output, SIMD3<Double>(0.2126, 0.7152, 0.0722))
        let shadowGuard = smoothstep(0.04, 0.16, luminance)
        let highlightGuard = 1 - smoothstep(0.90, 0.99, luminance)
        let protectedWeight = chromaWeight * shadowGuard * highlightGuard

        if grading.global.amount > 0.0001 {
            output = toneBand(
                output,
                toward: hueToneColor(grading.global.hue),
                t: grading.global.amount * 0.32 * protectedWeight
            )
        }

        let shadowWeight = 1 - smoothstep(0.12, 0.55, luminance)
        let highlightWeight = smoothstep(0.45, 0.88, luminance)

        if grading.shadows.amount > 0.0001 {
            output = toneBand(
                output,
                toward: hueToneColor(grading.shadows.hue),
                t: grading.shadows.amount * shadowWeight * 0.62 * protectedWeight
            )
        }
        if grading.highlights.amount > 0.0001 {
            output = toneBand(
                output,
                toward: hueToneColor(grading.highlights.hue),
                t: grading.highlights.amount * highlightWeight * 0.62 * protectedWeight
            )
        }

        return SIMD3<Double>(
            clamp(output.x, 0, 1),
            clamp(output.y, 0, 1),
            clamp(output.z, 0, 1)
        )
    }

    nonisolated private func shouldPreserveSourceLuminanceAfterGrading(_ settings: PhotoEffectSettings) -> Bool {
        guard settings.hsl == .neutral else { return false }
        return settings.colorGrading.global.amount > 0.0001 ||
            settings.colorGrading.shadows.amount > 0.0001 ||
            settings.colorGrading.highlights.amount > 0.0001
    }

    nonisolated private func preserveSourceLuminance(from source: CIImage, to graded: CIImage) -> CIImage {
        guard let colorBlend = CIFilter(name: "CIColorBlendMode") else { return graded }
        colorBlend.setValue(graded, forKey: kCIInputImageKey)
        colorBlend.setValue(source, forKey: kCIInputBackgroundImageKey)
        return colorBlend.outputImage?.cropped(to: source.extent) ?? graded
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

    nonisolated private func rgbSaturation(_ rgb: SIMD3<Double>) -> Double {
        let maxV = max(rgb.x, max(rgb.y, rgb.z))
        let minV = min(rgb.x, min(rgb.y, rgb.z))
        guard maxV > 0 else { return 0 }
        return (maxV - minV) / maxV
    }

    nonisolated private func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, t: Double) -> SIMD3<Double> {
        let clampedT = clamp(t, 0, 1)
        return (a * (1 - clampedT)) + (b * clampedT)
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
