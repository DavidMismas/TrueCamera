import SwiftUI
import Photos

extension ContentView {
    var selectedUserPreset: PhotoEffectPreset? {
        visibleEffectPresets.first(where: { $0.id == cameraService.selectedEffectPresetID })
    }

    var selectedPresetHasUnsavedChanges: Bool {
        guard let selectedUserPreset else { return false }
        return selectedUserPreset.settings.clamped() != cameraService.effectSettings.clamped()
    }

    var effectsSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                referencePreview
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                Form {
                    Section("Presets") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Preset")
                                .font(.subheadline)
                                .foregroundStyle(themeTextSecondary)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    Button {
                                        cameraService.resetEffectsToNeutral()
                                        scheduleReferenceRender()
                                    } label: {
                                        Text("Original")
                                            .font(.subheadline)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(
                                                Capsule()
                                                    .fill(cameraService.selectedEffectPresetID == PhotoEffectLibrary.customPresetID ? themeTeal : Color.gray.opacity(0.2))
                                            )
                                            .foregroundStyle(cameraService.selectedEffectPresetID == PhotoEffectLibrary.customPresetID ? .white : themeTextPrimary)
                                    }
                                    .buttonStyle(.plain)

                                    ForEach(visibleEffectPresets, id: \.id) { preset in
                                        Button {
                                            cameraService.applyEffectPreset(preset)
                                            scheduleReferenceRender()
                                        } label: {
                                            Text(preset.name)
                                                .font(.subheadline)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 8)
                                                .background(
                                                    Capsule()
                                                        .fill(cameraService.selectedEffectPresetID == preset.id ? themeTeal : Color.gray.opacity(0.2))
                                                )
                                                .foregroundStyle(cameraService.selectedEffectPresetID == preset.id ? .white : themeTextPrimary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)

                        if selectedUserPreset != nil {
                            ColorPicker("Preset Color", selection: selectedPresetDisplayColorBinding, supportsOpacity: false)
                        }

                        HStack(spacing: 10) {
                            TextField("Preset name", text: $presetNameDraft)
                                .textInputAutocapitalization(.words)
                                .disableAutocorrection(true)

                            if hasReachedFreePresetLimit {
                                Button("Unlock Pro") {
                                    premiumManager.presentPaywall(for: .unlimitedPresets)
                                }
                            } else {
                                Button("Save New") {
                                    saveNewPreset()
                                }
                                .disabled(presetNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }

                            if selectedUserPreset != nil {
                                Button("Update") {
                                    cameraService.updateSelectedPresetFromCurrentSettings()
                                }
                                .disabled(!selectedPresetHasUnsavedChanges)
                            }
                        }

                        if hasReachedFreePresetLimit {
                            Text("Free mode includes 1 saved preset. Upgrade to Grejn Pro for unlimited presets.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(visibleEffectPresets) { preset in
                            HStack {
                                Circle()
                                    .fill(presetDisplayColor(for: preset))
                                    .frame(width: 10, height: 10)
                                Text(preset.name)
                                    .foregroundStyle(presetDisplayColor(for: preset))
                                    .lineLimit(1)
                                Spacer()
                                if cameraService.selectedEffectPresetID == preset.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(themeTeal)
                                }
                                Button(role: .destructive) {
                                    cameraService.deleteEffectPreset(preset)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }

                    collapsibleEffectsSection(.base) {
                        effectSlider(
                            title: "Base Exposure",
                            value: effectBinding(\.baseExposure),
                            range: PhotoEffectSettings.baseExposureRange
                        )
                        effectSlider(
                            title: "Contrast",
                            value: effectBinding(\.contrast),
                            range: PhotoEffectSettings.contrastRange
                        )
                        effectSlider(
                            title: "Highlights",
                            value: effectBinding(\.highlights),
                            range: PhotoEffectSettings.highlightsRange
                        )
                        effectSlider(
                            title: "Shadows",
                            value: effectBinding(\.shadows),
                            range: PhotoEffectSettings.shadowsRange
                        )
                        effectSlider(
                            title: "Whites",
                            value: effectBinding(\.whites),
                            range: PhotoEffectSettings.whitesRange
                        )
                        effectSlider(
                            title: "Blacks",
                            value: effectBinding(\.blacks),
                            range: PhotoEffectSettings.blacksRange
                        )
                        effectSlider(
                            title: "White Fade",
                            value: effectBinding(\.whiteFade),
                            range: PhotoEffectSettings.whiteFadeRange
                        )
                        effectSlider(
                            title: "Black Fade",
                            value: effectBinding(\.blackFade),
                            range: PhotoEffectSettings.blackFadeRange
                        )
                        effectSlider(
                            title: "Clarity",
                            value: effectBinding(\.clarity),
                            range: PhotoEffectSettings.clarityRange
                        )
                        effectSlider(
                            title: "Sharpness",
                            value: effectBinding(\.sharpness),
                            range: PhotoEffectSettings.sharpnessRange
                        )
                    }

                    collapsibleEffectsSection(.color) {
                        effectSlider(
                            title: "Saturation",
                            value: effectBinding(\.saturation),
                            range: PhotoEffectSettings.saturationRange
                        )
                        effectSlider(
                            title: "Vibrance",
                            value: effectBinding(\.vibrance),
                            range: PhotoEffectSettings.vibranceRange
                        )
                        effectSlider(
                            title: "Warmth",
                            value: effectBinding(\.warmth),
                            range: PhotoEffectSettings.warmthRange,
                            decimals: 0,
                            tint: warmthTintColor(value: cameraService.effectSettings.warmth)
                        )
                        effectSlider(
                            title: "Tint",
                            value: effectBinding(\.tint),
                            range: PhotoEffectSettings.tintRange,
                            decimals: 0,
                            tint: tintAdjustmentColor(value: cameraService.effectSettings.tint)
                        )
                    }

                    collapsibleEffectsSection(.colorGrading) {
                        effectSlider(
                            title: "Global Hue",
                            value: colorGradeBinding(\.global, \.hue),
                            range: PhotoEffectSettings.colorGradeHueRange,
                            tint: gradeTintColor(hue: cameraService.effectSettings.colorGrading.global.hue)
                        )
                        effectSlider(
                            title: "Global Amount",
                            value: colorGradeBinding(\.global, \.amount),
                            range: PhotoEffectSettings.colorGradeAmountRange,
                            tint: gradeTintColor(hue: cameraService.effectSettings.colorGrading.global.hue)
                        )
                        effectSlider(
                            title: "Shadows Hue",
                            value: colorGradeBinding(\.shadows, \.hue),
                            range: PhotoEffectSettings.colorGradeHueRange,
                            tint: gradeTintColor(hue: cameraService.effectSettings.colorGrading.shadows.hue)
                        )
                        effectSlider(
                            title: "Shadows Amount",
                            value: colorGradeBinding(\.shadows, \.amount),
                            range: PhotoEffectSettings.colorGradeAmountRange,
                            tint: gradeTintColor(hue: cameraService.effectSettings.colorGrading.shadows.hue)
                        )
                        effectSlider(
                            title: "Midtones Hue",
                            value: colorGradeBinding(\.midtones, \.hue),
                            range: PhotoEffectSettings.colorGradeHueRange,
                            tint: gradeTintColor(hue: cameraService.effectSettings.colorGrading.midtones.hue)
                        )
                        effectSlider(
                            title: "Midtones Amount",
                            value: colorGradeBinding(\.midtones, \.amount),
                            range: PhotoEffectSettings.colorGradeAmountRange,
                            tint: gradeTintColor(hue: cameraService.effectSettings.colorGrading.midtones.hue)
                        )
                        effectSlider(
                            title: "Highlights Hue",
                            value: colorGradeBinding(\.highlights, \.hue),
                            range: PhotoEffectSettings.colorGradeHueRange,
                            tint: gradeTintColor(hue: cameraService.effectSettings.colorGrading.highlights.hue)
                        )
                        effectSlider(
                            title: "Highlights Amount",
                            value: colorGradeBinding(\.highlights, \.amount),
                            range: PhotoEffectSettings.colorGradeAmountRange,
                            tint: gradeTintColor(hue: cameraService.effectSettings.colorGrading.highlights.hue)
                        )
                    }

                    collapsibleEffectsSection(.hslMix) {
                        ForEach(HSLColorBand.allCases) { band in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(band.title)
                                    .font(.subheadline.weight(.semibold))
                                effectSlider(
                                    title: "Hue",
                                    value: hslBinding(for: band, \.hueShift),
                                    range: PhotoEffectSettings.hslHueRange,
                                    tint: hslHueTintColor(for: band, shift: cameraService.effectSettings.hsl[band].hueShift)
                                )
                                effectSlider(
                                    title: "Saturation",
                                    value: hslBinding(for: band, \.saturationDelta),
                                    range: PhotoEffectSettings.hslSaturationRange,
                                    tint: hslSaturationTintColor(for: band, delta: cameraService.effectSettings.hsl[band].saturationDelta)
                                )
                                effectSlider(
                                    title: "Luminance",
                                    value: hslBinding(for: band, \.lightnessDelta),
                                    range: PhotoEffectSettings.hslLightnessRange,
                                    tint: hslLuminanceTintColor(for: band, delta: cameraService.effectSettings.hsl[band].lightnessDelta)
                                )
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    collapsibleEffectsSection(.stylization) {
                        effectSlider(
                            title: "Bloom Intensity",
                            value: effectBinding(\.bloomIntensity),
                            range: PhotoEffectSettings.bloomIntensityRange
                        )
                        effectSlider(
                            title: "Bloom Radius",
                            value: effectBinding(\.bloomRadius),
                            range: PhotoEffectSettings.bloomRadiusRange,
                            decimals: 1
                        )
                        effectSlider(
                            title: "Vignette",
                            value: effectBinding(\.vignetteIntensity),
                            range: PhotoEffectSettings.vignetteIntensityRange
                        )
                        effectSlider(
                            title: "Vignette Radius",
                            value: effectBinding(\.vignetteRadius),
                            range: PhotoEffectSettings.vignetteRadiusRange,
                            decimals: 2
                        )
                        effectSlider(
                            title: "Grain",
                            value: effectBinding(\.grainAmount),
                            range: PhotoEffectSettings.grainAmountRange
                        )
                        effectSlider(
                            title: "Grain Size",
                            value: effectBinding(\.grainSize),
                            range: PhotoEffectSettings.grainSizeRange
                        )
                    }
                }
            }
            .tint(themeTeal)
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [themeBackgroundTop, themeBackgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle("Effects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        cameraService.resetCurrentEffectAdjustments()
                        scheduleReferenceRender()
                    }
                    .foregroundStyle(themePink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showEffectsSheet = false }
                        .foregroundStyle(themePink)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $premiumManager.isPaywallPresented) {
            PremiumPaywallView()
                .environmentObject(premiumManager)
        }
    }

    var referencePreview: some View {
        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(themeBackgroundBottom.opacity(0.55))

            if let referenceImage = renderedReferenceImage ?? Self.editorReferenceImage {
                Image(uiImage: referenceImage)
                    .resizable()
                    .scaledToFit()
                    .padding(10)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.title3.weight(.semibold))
                    Text("Missing reference image")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(themeTextSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(themePink.opacity(0.32), lineWidth: 1)
        )
    }

    func scheduleReferenceRender() {
        guard showEffectsSheet, let sourceImage = Self.editorReferenceImage else { return }
        let settings = cameraService.effectSettings
        referenceRenderGeneration &+= 1
        let generation = referenceRenderGeneration

        referenceRenderTask?.cancel()
        referenceRenderTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: Self.referenceRenderDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            let shouldRender = await MainActor.run { generation == referenceRenderGeneration && showEffectsSheet }
            guard shouldRender else { return }

            let rendered = Self.referencePreviewProcessor.renderReferencePreview(
                from: sourceImage,
                settings: settings,
                maxDimension: Self.referencePreviewRenderDimension,
                includeGrain: false
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard generation == referenceRenderGeneration, showEffectsSheet else { return }
                renderedReferenceImage = rendered
            }
        }
    }

    func effectBinding(_ keyPath: WritableKeyPath<PhotoEffectSettings, Double>) -> Binding<Double> {
        Binding(
            get: { cameraService.effectSettings[keyPath: keyPath] },
            set: { nextValue in
                cameraService.updateEffectSetting { settings in
                    settings[keyPath: keyPath] = nextValue
                }
                scheduleReferenceRender()
            }
        )
    }

    func hslBinding(
        for band: HSLColorBand,
        _ keyPath: WritableKeyPath<HSLBandAdjustment, Double>
    ) -> Binding<Double> {
        Binding(
            get: { cameraService.effectSettings.hsl[band][keyPath: keyPath] },
            set: { nextValue in
                cameraService.updateEffectSetting { settings in
                    var adjustment = settings.hsl[band]
                    adjustment[keyPath: keyPath] = nextValue
                    settings.hsl[band] = adjustment
                }
                scheduleReferenceRender()
            }
        )
    }

    func colorGradeBinding(
        _ toneKeyPath: WritableKeyPath<ColorGradingSettings, ColorGradeTone>,
        _ valueKeyPath: WritableKeyPath<ColorGradeTone, Double>
    ) -> Binding<Double> {
        Binding(
            get: { cameraService.effectSettings.colorGrading[keyPath: toneKeyPath][keyPath: valueKeyPath] },
            set: { nextValue in
                cameraService.updateEffectSetting { settings in
                    var tone = settings.colorGrading[keyPath: toneKeyPath]
                    tone[keyPath: valueKeyPath] = nextValue
                    settings.colorGrading[keyPath: toneKeyPath] = tone
                }
                scheduleReferenceRender()
            }
        )
    }

    var heifCompressionPercentBinding: Binding<Double> {
        Binding(
            get: { cameraService.styledHEIFCompressionQuality * 100 },
            set: { nextValue in
                cameraService.styledHEIFCompressionQuality = nextValue.rounded() / 100
            }
        )
    }

    @ViewBuilder
    func collapsibleEffectsSection<Content: View>(
        _ group: EffectEditorGroup,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    toggleEffectsGroup(group)
                }
            } label: {
                HStack(spacing: 10) {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(themePink.opacity(0.96))
                    Spacer()
                    Image(systemName: expandedEffectGroups.contains(group) ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(themeTeal)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedEffectGroups.contains(group) {
                content()
            }
        }
    }

    func toggleEffectsGroup(_ group: EffectEditorGroup) {
        if expandedEffectGroups.contains(group) {
            expandedEffectGroups.remove(group)
        } else {
            expandedEffectGroups = [group]
        }
    }

    func effectSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        decimals: Int = 2,
        tint: Color? = nil
    ) -> some View {
        let sliderTint = tint ?? themeTeal
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(themePink.opacity(0.92))
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(decimals)))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(themeTextSecondary)
            }
            ThemedSlider(
                value: value,
                range: range,
                minimumTrackColor: sliderTint,
                maximumTrackColor: themePink.opacity(0.22),
                thumbColor: themePink
            )
                .frame(height: 28)
                .contentShape(Rectangle())
                .padding(.vertical, 2)
        }
        .padding(.vertical, 2)
    }

    func presetScrollTargetID(for presetID: String) -> String {
        "main-preset-\(presetID)"
    }

    func saveNewPreset() {
        guard !hasReachedFreePresetLimit else {
            premiumManager.presentPaywall(for: .unlimitedPresets)
            return
        }

        cameraService.saveCurrentEffectsAsPreset(named: presetNameDraft)
        presetNameDraft = ""
    }

    func applyPremiumAccessState() {
        cameraService.applyPremiumAccess(premiumManager.hasPremiumAccess)

        guard !premiumManager.hasPremiumAccess else { return }
        guard cameraService.selectedEffectPresetID != PhotoEffectLibrary.customPresetID else { return }

        let visiblePresetIDs = Set(visibleEffectPresets.map(\.id))
        guard !visiblePresetIDs.contains(cameraService.selectedEffectPresetID) else { return }

        if let firstVisiblePreset = visibleEffectPresets.first {
            cameraService.applyEffectPreset(firstVisiblePreset)
        } else {
            cameraService.resetEffectsToNeutral()
        }
    }

    func scrollPresetStrip(to proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo(presetScrollTargetID(for: cameraService.selectedEffectPresetID), anchor: .center)
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.22)) {
                action()
            }
        } else {
            action()
        }
    }

    func gradeTintColor(hue: Double) -> Color {
        let normalized = normalizedHueUnit(hue)
        return Color(hue: normalized, saturation: 0.9, brightness: 0.95)
    }

    func presetDisplayColor(for preset: PhotoEffectPreset) -> Color {
        guard let displayColor = preset.displayColor?.clamped() else { return themeTeal }
        return Color(red: displayColor.red, green: displayColor.green, blue: displayColor.blue)
    }

    func presetDisplayColorModel(from color: Color) -> PresetDisplayColor {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return PresetDisplayColor(red: 0.07, green: 0.74, blue: 0.70)
        }

        return PresetDisplayColor(
            red: Double(red),
            green: Double(green),
            blue: Double(blue)
        )
    }

    func warmthTintColor(value: Double) -> Color {
        let neutral = UIColor(themeTextSecondary.opacity(0.9))
        let cool = UIColor(red: 0.35, green: 0.72, blue: 0.98, alpha: 1)
        let warm = UIColor(red: 1.0, green: 0.63, blue: 0.24, alpha: 1)
        let progress = normalizedUnit(value, in: PhotoEffectSettings.warmthRange)

        if progress < 0.5 {
            return interpolateColor(from: cool, to: neutral, progress: progress / 0.5)
        }

        return interpolateColor(from: neutral, to: warm, progress: (progress - 0.5) / 0.5)
    }

    func tintAdjustmentColor(value: Double) -> Color {
        let neutral = UIColor(themeTextSecondary.opacity(0.9))
        let green = UIColor(red: 0.34, green: 0.86, blue: 0.58, alpha: 1)
        let magenta = UIColor(red: 0.96, green: 0.47, blue: 0.82, alpha: 1)
        let progress = normalizedUnit(value, in: PhotoEffectSettings.tintRange)

        if progress < 0.5 {
            return interpolateColor(from: green, to: neutral, progress: progress / 0.5)
        }

        return interpolateColor(from: neutral, to: magenta, progress: (progress - 0.5) / 0.5)
    }

    func hslHueTintColor(for band: HSLColorBand, shift: Double) -> Color {
        hslBandColor(for: band, hueShift: shift, saturation: 0.92, brightness: 0.96)
    }

    func hslSaturationTintColor(for band: HSLColorBand, delta: Double) -> Color {
        let progress = normalizedUnit(delta, in: PhotoEffectSettings.hslSaturationRange)
        let saturation = 0.18 + (progress * 0.78)
        let brightness = 0.76 + (progress * 0.2)
        return hslBandColor(for: band, saturation: saturation, brightness: brightness)
    }

    func hslLuminanceTintColor(for band: HSLColorBand, delta: Double) -> Color {
        let progress = normalizedUnit(delta, in: PhotoEffectSettings.hslLightnessRange)
        let saturation = 0.92 - (progress * 0.28)
        let brightness = 0.42 + (progress * 0.54)
        return hslBandColor(for: band, saturation: saturation, brightness: brightness)
    }

    func hslBandColor(
        for band: HSLColorBand,
        hueShift: Double = 0,
        saturation: Double = 0.9,
        brightness: Double = 0.95
    ) -> Color {
        let normalized = normalizedHueUnit(hslBandBaseHueDegrees(for: band) + hueShift)
        return Color(hue: normalized, saturation: saturation, brightness: brightness)
    }

    func hslBandBaseHueDegrees(for band: HSLColorBand) -> Double {
        switch band {
        case .red: return 0
        case .orange: return 28
        case .yellow: return 56
        case .green: return 122
        case .aqua: return 182
        case .blue: return 220
        case .purple: return 276
        case .magenta: return 320
        }
    }

    func normalizedHueUnit(_ hue: Double) -> Double {
        let degrees = hue.truncatingRemainder(dividingBy: 360)
        return (degrees < 0 ? degrees + 360 : degrees) / 360
    }

    func normalizedUnit(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return (clamped - range.lowerBound) / span
    }

    func interpolateColor(from start: UIColor, to end: UIColor, progress: Double) -> Color {
        let clamped = min(max(progress, 0), 1)

        var startRed: CGFloat = 0
        var startGreen: CGFloat = 0
        var startBlue: CGFloat = 0
        var startAlpha: CGFloat = 0
        var endRed: CGFloat = 0
        var endGreen: CGFloat = 0
        var endBlue: CGFloat = 0
        var endAlpha: CGFloat = 0

        guard start.getRed(&startRed, green: &startGreen, blue: &startBlue, alpha: &startAlpha),
              end.getRed(&endRed, green: &endGreen, blue: &endBlue, alpha: &endAlpha) else {
            return Color(uiColor: end)
        }

        let inverse = 1 - clamped
        return Color(
            red: Double((startRed * inverse) + (endRed * clamped)),
            green: Double((startGreen * inverse) + (endGreen * clamped)),
            blue: Double((startBlue * inverse) + (endBlue * clamped)),
            opacity: Double((startAlpha * inverse) + (endAlpha * clamped))
        )
    }

    func shortPresetTitle(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Preset" }
        if trimmed.count <= 8 { return trimmed }
        return String(trimmed.prefix(8))
    }
}
