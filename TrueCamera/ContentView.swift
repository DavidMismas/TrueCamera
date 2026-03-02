import Photos
import SwiftUI
import UIKit

struct ContentView: View {
    private static let editorReferenceImage: UIImage? = {
        for name in ["Image", "image", "bird"] {
            if let image = UIImage(named: name) {
                return image
            }
        }

        for (name, ext) in [("image", "jpg"), ("Image", "jpg"), ("bird", "jpg")] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext),
               let image = UIImage(contentsOfFile: url.path) {
                return image
            }
        }

        return nil
    }()
    nonisolated(unsafe) private static let referencePreviewProcessor = PhotoEffectsProcessor()

    @StateObject private var cameraService = CameraService()
    @Environment(\.scenePhase) private var scenePhase

    @State private var isSaving = false
    @State private var statusMessage: String?
    @State private var lastCaptureSucceeded = false
    @State private var controlRotationAngle: Angle = .zero
    @State private var showSettingsSheet = false
    @State private var showEffectsSheet = false
    @State private var showLensPickerDialog = false
    @State private var renderedReferenceImage: UIImage?
    @State private var referenceRenderTask: Task<Void, Never>?
    @State private var referenceRenderInFlight = false
    @State private var pendingReferenceSettings: PhotoEffectSettings?
    @State private var referenceRenderGeneration: UInt64 = 0
    @State private var presetNameDraft = ""

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.06).ignoresSafeArea()

            switch cameraService.authorizationStatus {
            case .authorized:
                VStack(spacing: 0) {
                    HStack {
                        settingsButton
                        Spacer()
                        effectsButton
                            .padding(.trailing, 12)
                        cameraSwitchButton
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 10)

                    ZStack {
                        CameraPreviewView(
                            session: cameraService.session,
                            activeDevice: cameraService.activeVideoDevice,
                            onTapToFocus: { _, devicePoint in
                                cameraService.focus(at: devicePoint, lockFocus: false)
                            },
                            onLongPressToFocusLock: { _, devicePoint in
                                cameraService.focus(at: devicePoint, lockFocus: true)
                            }
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                    exposureSlider
                        .padding(.top, 14)

                    presetStrip
                        .padding(.top, 12)

                    controls
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                }

            case .denied, .restricted:
                deniedView

            case .notDetermined:
                ProgressView("Waiting for camera permission...")
                    .tint(.white)
                    .foregroundStyle(.white.opacity(0.9))

            @unknown default:
                Text("Unknown camera permission state.")
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .overlay(alignment: .top) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.top, 16)
            }
        }
        .onAppear {
            cameraService.onPhotoCapture = handleCaptureResult
            cameraService.setLivePreviewEnabled(false)
            requestPhotosPermissionIfNeeded()
            cameraService.requestPermissionIfNeeded()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            setInitialControlRotation()
            normalizeCaptureFormatSelection()
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                requestPhotosPermissionIfNeeded()
                cameraService.requestPermissionIfNeeded()
                cameraService.startSession()
                normalizeCaptureFormatSelection()
            case .inactive, .background:
                cameraService.stopSession()
            @unknown default:
                break
            }
        }
        .onChange(of: cameraService.appleProRAWSupported) { _, _ in
            normalizeCaptureFormatSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateControlRotation(for: UIDevice.current.orientation)
        }
        .sheet(isPresented: $showSettingsSheet) {
            settingsSheet
        }
        .sheet(isPresented: $showEffectsSheet) {
            effectsSheet
        }
        .onChange(of: showEffectsSheet) { _, isPresented in
            if isPresented {
                referenceRenderGeneration &+= 1
                scheduleReferenceRender()
            } else {
                referenceRenderGeneration &+= 1
                referenceRenderTask?.cancel()
                referenceRenderTask = nil
                referenceRenderInFlight = false
                pendingReferenceSettings = nil
                renderedReferenceImage = nil
            }
        }
    }

    // MARK: - Exposure Slider

    private var exposureSlider: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.min.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 22)

            Slider(value: $cameraService.exposureBias, in: cameraService.exposureBiasRange)
                .tint(.orange)

            Image(systemName: "sun.max.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 22)

            Text(cameraService.exposureBias >= 0
                 ? "+\(String(format: "%.1f", cameraService.exposureBias))"
                 : String(format: "%.1f", cameraService.exposureBias))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 34, alignment: .trailing)

            Button {
                cameraService.exposureBias = 0
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .opacity(abs(cameraService.exposureBias) > 0.05 ? 1 : 0.3)
        }
        .padding(.horizontal, 20)
    }

    private var presetStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                presetIcon(title: "Orig", symbol: "camera", isSelected: cameraService.selectedEffectPresetID == PhotoEffectLibrary.customPresetID) {
                    cameraService.resetEffectsToNeutral()
                }
                ForEach(cameraService.effectPresets) { preset in
                    presetIcon(
                        title: shortPresetTitle(preset.name),
                        symbol: "camera.filters",
                        isSelected: cameraService.selectedEffectPresetID == preset.id
                    ) {
                        cameraService.applyEffectPreset(preset)
                    }
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private func presetIcon(title: String, symbol: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? .orange.opacity(0.26) : .white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? .orange.opacity(0.8) : .white.opacity(0.16), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        controlButtons
            .overlay(alignment: .top) {
                if isSaving {
                    ProgressView()
                        .tint(.white)
                        .padding(.top, -18)
                }
            }
    }

    private var controlButtons: some View {
        HStack(spacing: 12) {
            HStack {
                lensSelector
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            shutterButton

            HStack {
                Spacer(minLength: 0)
                galleryButton
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white.opacity(0.08), in: Capsule())
        .overlay(
            Capsule()
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
    }

    // MARK: - Buttons

    private var settingsButton: some View {
        Button {
            showSettingsSheet = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(.black.opacity(0.45), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
        }
        .rotationEffect(controlRotationAngle)
        .animation(.easeInOut(duration: 0.2), value: controlRotationAngle)
    }

    private var effectsButton: some View {
        Button {
            showEffectsSheet = true
        } label: {
            Image(systemName: "camera.filters")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(.black.opacity(0.45), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
        }
        .rotationEffect(controlRotationAngle)
        .animation(.easeInOut(duration: 0.2), value: controlRotationAngle)
    }

    private var cameraSwitchButton: some View {
        Button {
            cameraService.togglePosition()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(.black.opacity(0.45), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
        }
        .rotationEffect(controlRotationAngle)
        .animation(.easeInOut(duration: 0.2), value: controlRotationAngle)
    }

    private var shutterButton: some View {
        Button {
            guard !isSaving else { return }
            lastCaptureSucceeded = false
            cameraService.capturePhoto()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 82, height: 82)
                Circle()
                    .fill(lastCaptureSucceeded ? .green : .white)
                    .frame(width: 66, height: 66)
                    .animation(.easeInOut(duration: 0.2), value: lastCaptureSucceeded)
            }
        }
        .disabled(isSaving)
        .opacity(isSaving ? 0.72 : 1)
        .rotationEffect(controlRotationAngle)
        .animation(.easeInOut(duration: 0.2), value: controlRotationAngle)
        .buttonStyle(.plain)
    }

    private var galleryButton: some View {
        Button {
            openSystemPhotosApp()
        } label: {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(.black.opacity(0.45), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
        }
        .rotationEffect(controlRotationAngle)
        .animation(.easeInOut(duration: 0.2), value: controlRotationAngle)
    }

    private var lensSelector: some View {
        Button {
            showLensPickerDialog = true
        } label: {
            HStack(spacing: 6) {
                Text(currentLensName)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(.white.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
        }
        .frame(width: 106, alignment: .leading)
        .disabled(cameraService.availableLenses.isEmpty)
        .confirmationDialog("Select Lens", isPresented: $showLensPickerDialog, titleVisibility: .visible) {
            if cameraService.availableLenses.isEmpty {
                Button("No lenses available") {}
                    .disabled(true)
            } else {
                ForEach(cameraService.availableLenses.reversed()) { lens in
                    let label = cameraService.selectedLens?.id == lens.id ? "\(lens.name) ✓" : lens.name
                    Button(label) {
                        cameraService.selectLens(lens)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .rotationEffect(controlRotationAngle)
        .animation(.easeInOut(duration: 0.2), value: controlRotationAngle)
    }

    private var currentLensName: String {
        cameraService.selectedLens?.name ?? cameraService.availableLenses.first?.name ?? "Lens"
    }

    // MARK: - Permission denied view

    private var deniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text("Camera access is disabled.")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Enable camera in iOS Settings for TrueCamera.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(20)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(20)
    }

    // MARK: - Settings sheet

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Sound & Haptics") {
                    Toggle("Haptic Feedback", isOn: $cameraService.hapticsEnabled)
                    if cameraService.isShutterSoundToggleAvailable {
                        Toggle("Shutter Sound", isOn: $cameraService.shutterSoundEnabled)
                    }
                }

                Section("Capture Format") {
                    Toggle("Save RAW (.dng) to Photos", isOn: $cameraService.saveRAWToLibrary)
                    Text("Zajem je vedno Apple ProRAW. Efekti se aplicirajo naknadno na ProRAW in izvozi se JPEG (95%). RAW .dng se shrani samo, če je ta opcija vklopljena.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !cameraService.appleProRAWSupported {
                        Text("ProRAW ni podprt na trenutni napravi/leči.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showSettingsSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var effectsSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                referencePreview
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                Form {
                    Section("Presets") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                presetIcon(
                                    title: "Orig",
                                    symbol: "camera",
                                    isSelected: cameraService.selectedEffectPresetID == PhotoEffectLibrary.customPresetID
                                ) {
                                    cameraService.resetEffectsToNeutral()
                                    scheduleReferenceRender()
                                }
                                ForEach(cameraService.effectPresets) { preset in
                                    presetIcon(
                                        title: shortPresetTitle(preset.name),
                                        symbol: "camera.filters",
                                        isSelected: cameraService.selectedEffectPresetID == preset.id
                                    ) {
                                        cameraService.applyEffectPreset(preset)
                                        scheduleReferenceRender()
                                    }
                                }
                            }
                        }

                        HStack(spacing: 10) {
                            TextField("Preset name", text: $presetNameDraft)
                                .textInputAutocapitalization(.words)
                                .disableAutocorrection(true)
                            Button("Save") {
                                cameraService.saveCurrentEffectsAsPreset(named: presetNameDraft)
                                presetNameDraft = ""
                            }
                            .disabled(presetNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        ForEach(cameraService.effectPresets) { preset in
                            HStack {
                                Text(preset.name)
                                    .lineLimit(1)
                                Spacer()
                                if cameraService.selectedEffectPresetID == preset.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                                Button(role: .destructive) {
                                    cameraService.deleteEffectPreset(preset)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                    }

                    Section("Base") {
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

                    Section("Color") {
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
                    }

                    Section("White Balance") {
                        effectSlider(
                            title: "Warmth",
                            value: effectBinding(\.warmth),
                            range: PhotoEffectSettings.warmthRange,
                            decimals: 0
                        )
                        effectSlider(
                            title: "Tint",
                            value: effectBinding(\.tint),
                            range: PhotoEffectSettings.tintRange,
                            decimals: 0
                        )
                    }

                    Section("Color Grading") {
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

                    Section("HSL Mix") {
                        ForEach(HSLColorBand.allCases) { band in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(band.title)
                                    .font(.subheadline.weight(.semibold))
                                effectSlider(
                                    title: "Hue",
                                    value: hslBinding(for: band, \.hueShift),
                                    range: PhotoEffectSettings.hslHueRange
                                )
                                effectSlider(
                                    title: "Saturation",
                                    value: hslBinding(for: band, \.saturationDelta),
                                    range: PhotoEffectSettings.hslSaturationRange
                                )
                                effectSlider(
                                    title: "Luminance",
                                    value: hslBinding(for: band, \.lightnessDelta),
                                    range: PhotoEffectSettings.hslLightnessRange
                                )
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Section("Stylization") {
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
                    }
                }
            }
            .navigationTitle("Effects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        cameraService.resetEffectsToNeutral()
                        scheduleReferenceRender()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showEffectsSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var referencePreview: some View {
        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.28))

            if let referenceImage = renderedReferenceImage ?? Self.editorReferenceImage {
                Image(uiImage: referenceImage)
                    .resizable()
                    .scaledToFit()
                    .padding(10)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.title3.weight(.semibold))
                    Text("Missing image.jpg reference image")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
    }

    private func scheduleReferenceRender() {
        guard showEffectsSheet, let sourceImage = Self.editorReferenceImage else { return }
        pendingReferenceSettings = cameraService.effectSettings
        if referenceRenderInFlight { return }
        referenceRenderInFlight = true
        runReferenceRenderLoop(sourceImage: sourceImage)
    }

    @MainActor
    private func runReferenceRenderLoop(sourceImage: UIImage) {
        guard showEffectsSheet else {
            referenceRenderInFlight = false
            pendingReferenceSettings = nil
            return
        }
        guard let settings = pendingReferenceSettings else {
            referenceRenderInFlight = false
            return
        }
        pendingReferenceSettings = nil
        let generation = referenceRenderGeneration

        referenceRenderTask = Task.detached(priority: .userInitiated) {
            let rendered = Self.referencePreviewProcessor.renderReferencePreview(
                from: sourceImage,
                settings: settings,
                maxDimension: 320,
                includeGrain: true
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard generation == referenceRenderGeneration, showEffectsSheet else {
                    referenceRenderInFlight = false
                    return
                }
                renderedReferenceImage = rendered
                if pendingReferenceSettings != nil {
                    runReferenceRenderLoop(sourceImage: sourceImage)
                } else {
                    referenceRenderInFlight = false
                }
            }
        }
    }

    private func effectBinding(_ keyPath: WritableKeyPath<PhotoEffectSettings, Double>) -> Binding<Double> {
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

    private func hslBinding(
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

    private func colorGradeBinding(
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

    private func effectSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        decimals: Int = 2,
        tint: Color = .orange
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(decimals)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .tint(tint)
                .contentShape(Rectangle())
                .padding(.vertical, 2)
        }
        .padding(.vertical, 2)
    }

    private func gradeTintColor(hue: Double) -> Color {
        let degrees = hue.truncatingRemainder(dividingBy: 360)
        let normalized = (degrees < 0 ? degrees + 360 : degrees) / 360
        return Color(hue: normalized, saturation: 0.9, brightness: 0.95)
    }

    private func shortPresetTitle(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Preset" }
        if trimmed.count <= 8 { return trimmed }
        return String(trimmed.prefix(8))
    }

    // MARK: - Capture format helpers

    private func normalizeCaptureFormatSelection() {
        if cameraService.captureFormat != .appleProRAW {
            cameraService.captureFormat = .appleProRAW
        }
    }

    // MARK: - Capture result handling

    private func handleCaptureResult(_ result: CameraCaptureResult) {
        guard let rawData = result.rawData else {
            if let unavailableMessage = unavailableCaptureFormatMessage {
                statusMessage = unavailableMessage
            } else {
                statusMessage = "Capture failed (missing ProRAW data)."
            }
            lastCaptureSucceeded = false
            return
        }
        Task { @MainActor in
            isSaving = true
            defer { isSaving = false }
            let styledData = await cameraService.buildStyledPhotoData(from: rawData)
            let rawDataToSave = cameraService.saveRAWToLibrary ? rawData : nil
            let (saveOk, saveErrorMessage) = await saveToPhotoLibrary(rawData: rawDataToSave, styledData: styledData)
            lastCaptureSucceeded = saveOk
            if saveOk {
                statusMessage = nil
            } else {
                statusMessage = photoPermissionDenied
                    ? "Photos permission denied. Enable it in Settings."
                    : "Save failed: \(saveErrorMessage ?? "Unknown Photos error")"
            }
        }
    }

    private var unavailableCaptureFormatMessage: String? {
        switch cameraService.captureFormat {
        case .appleProRAW:
            return cameraService.appleProRAWActive ? nil : "ProRAW ni na voljo za izbrano kamero/lečo."
        }
    }

    // MARK: - Photos library

    private func saveToPhotoLibrary(rawData: Data?, styledData: Data?) async -> (Bool, String?) {
        let authStatus = await ensurePhotoWriteAuthorization()
        guard authStatus == .authorized || authStatus == .limited else {
            return (false, "No Photos write permission")
        }
        guard rawData != nil || styledData != nil else { return (false, "No photo data to save") }

        var tempPhotoFileURL: URL?
        if let rawData {
            guard let tempURL = await writeRawTempFile(rawData) else {
                return (false, "Couldn't prepare temporary DNG file")
            }
            tempPhotoFileURL = tempURL
        }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                if let styledData {
                    request.addResource(with: .photo, data: styledData, options: nil)
                }
                if let tempPhotoFileURL {
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = true
                    let rawResourceType: PHAssetResourceType = styledData == nil ? .photo : .alternatePhoto
                    request.addResource(with: rawResourceType, fileURL: tempPhotoFileURL, options: options)
                }
            }, completionHandler: { success, error in
                if let error { print("Photos save error: \(error)") }
                if !success, let tempPhotoFileURL {
                    try? FileManager.default.removeItem(at: tempPhotoFileURL)
                }
                continuation.resume(returning: (success, error?.localizedDescription))
            })
        }
    }

    private func writeRawTempFile(_ data: Data) async -> URL? {
        await Task.detached(priority: .utility) { () -> URL? in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("dng")
            do {
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                print("Raw temp file write error: \(error)")
                return nil
            }
        }.value
    }

    private func openSystemPhotosApp() {
        guard let photosURL = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(photosURL)
    }

    private var photoPermissionDenied: Bool {
        let addOnly = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let readWrite = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return addOnly == .denied || addOnly == .restricted || readWrite == .denied || readWrite == .restricted
    }

    private func ensurePhotoWriteAuthorization() async -> PHAuthorizationStatus {
        let addOnlyCurrent = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch addOnlyCurrent {
        case .authorized: return .authorized
        case .notDetermined:
            let requested = await requestPhotoAuthorization(for: .addOnly)
            if requested == .authorized { return requested }
        default: break
        }
        let readWriteCurrent = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch readWriteCurrent {
        case .authorized, .limited: return readWriteCurrent
        case .notDetermined: return await requestPhotoAuthorization(for: .readWrite)
        default: return readWriteCurrent
        }
    }

    private func requestPhotoAuthorization(for accessLevel: PHAccessLevel) async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: accessLevel) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestPhotosPermissionIfNeeded() {
        let addOnly = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let readWrite = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard addOnly == .notDetermined || readWrite == .notDetermined else { return }
        Task { _ = await ensurePhotoWriteAuthorization() }
    }

    // MARK: - Orientation

    private func setInitialControlRotation() {
        let deviceOrientation = UIDevice.current.orientation
        switch deviceOrientation {
        case .landscapeLeft: controlRotationAngle = .degrees(90)
        case .landscapeRight: controlRotationAngle = .degrees(-90)
        case .portrait: controlRotationAngle = .degrees(0)
        default:
            guard let interfaceOrientation = currentInterfaceOrientation() else { return }
            switch interfaceOrientation {
            case .landscapeLeft: controlRotationAngle = .degrees(90)
            case .landscapeRight: controlRotationAngle = .degrees(-90)
            default: controlRotationAngle = .degrees(0)
            }
        }
    }

    private func updateControlRotation(for orientation: UIDeviceOrientation) {
        withAnimation(.easeInOut(duration: 0.22)) {
            switch orientation {
            case .landscapeLeft: controlRotationAngle = .degrees(90)
            case .landscapeRight: controlRotationAngle = .degrees(-90)
            case .portrait: controlRotationAngle = .degrees(0)
            default: break
            }
        }
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return nil
        }
        return scene.effectiveGeometry.interfaceOrientation
    }
}

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
