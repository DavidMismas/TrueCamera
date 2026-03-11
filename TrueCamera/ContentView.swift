import CoreImage
import Photos
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    private enum CaptureProcessingStage: Int {
        case capturing
        case processing
        case saving
        case done
        case failed

        var title: String {
            switch self {
            case .capturing: return "Capturing ProRAW"
            case .processing: return "Developing"
            case .saving: return "Saving"
            case .done: return "Done"
            case .failed: return "Failed"
            }
        }

        var subtitle: String {
            switch self {
            case .capturing: return "Capturing full-resolution RAW photo"
            case .processing: return "Applying style and tone mapping"
            case .saving: return "Saving to Photos library"
            case .done: return "Photo saved"
            case .failed: return "An error occurred during processing"
            }
        }

        var symbol: String {
            switch self {
            case .capturing: return "camera.aperture"
            case .processing: return "wand.and.stars"
            case .saving: return "tray.and.arrow.down.fill"
            case .done: return "checkmark.circle.fill"
            case .failed: return "xmark.octagon.fill"
            }
        }

        var accentColor: Color {
            switch self {
            case .capturing: return Color(red: 0.07, green: 0.74, blue: 0.70)
            case .processing: return Color(red: 0.95, green: 0.54, blue: 0.75)
            case .saving: return Color(red: 0.07, green: 0.74, blue: 0.70)
            case .done: return Color(red: 0.07, green: 0.74, blue: 0.70)
            case .failed: return Color(red: 0.95, green: 0.54, blue: 0.75)
            }
        }

        var progressStep: Int {
            switch self {
            case .capturing: return 1
            case .processing: return 2
            case .saving: return 3
            case .done: return 3
            case .failed: return 1
            }
        }
    }

    private struct CaptureRequestContext {
        let effectSettings: PhotoEffectSettings
        let heifBitDepth: StyledHEIFBitDepth
        let heifCompressionQuality: Double
        let processingSource: StyledProcessingSource
        let saveRAWToLibrary: Bool
    }

    private struct PendingCaptureJob: Identifiable {
        let id = UUID()
        let rawData: Data?
        let processedData: Data?
        let requestContext: CaptureRequestContext
    }

    private static let editorReferenceImage: UIImage? = loadEditorReferenceImage()
    nonisolated private static let referencePreviewProcessor = PhotoEffectsProcessor()
    nonisolated private static let referenceRenderDebounceNanoseconds: UInt64 = 16_000_000
    private static let queueFullStatusMessage = "Processing queue is full. Please wait a moment."
    private static let editorReferenceMaxDimension: CGFloat = 2200
    nonisolated private static let referencePreviewRenderDimension: CGFloat = 960

    @StateObject private var cameraService = CameraService()
    @Environment(\.scenePhase) private var scenePhase

    @State private var statusMessage: String?
    @State private var lastCaptureSucceeded = false
    @State private var controlRotationAngle: Angle = .zero
    @State private var showSettingsSheet = false
    @State private var showEffectsSheet = false
    @State private var renderedReferenceImage: UIImage?
    @State private var referenceRenderTask: Task<Void, Never>?
    @State private var referenceRenderGeneration: UInt64 = 0
    @State private var presetNameDraft = ""
    @State private var captureProcessingStage: CaptureProcessingStage?
    @State private var captureStageDismissTask: Task<Void, Never>?
    @State private var processingSpinnerRotation: Double = 0
    @State private var processingPulse = false
    @State private var pendingCaptureRequestContext: CaptureRequestContext?
    @State private var pendingCaptureJobs: [PendingCaptureJob] = []
    @State private var backgroundProcessorTask: Task<Void, Never>?
    @State private var backgroundProcessingInFlight = false
    private let maxPendingBackgroundCaptures = 3
    private let themeTeal = Color(red: 0.07, green: 0.74, blue: 0.70)
    private let themePink = Color(red: 0.95, green: 0.54, blue: 0.75)
    private let themeTextPrimary = Color.white.opacity(0.94)
    private let themeTextSecondary = Color(red: 0.82, green: 0.83, blue: 0.9)
    private let themeBackgroundTop = Color(red: 0.06, green: 0.09, blue: 0.13)
    private let themeBackgroundBottom = Color(red: 0.03, green: 0.05, blue: 0.08)
    private let topControlsHorizontalPadding: CGFloat = 24
    private let exposureHorizontalPadding: CGFloat = 20

    private var backgroundQueueIsFull: Bool {
        let totalPending = pendingCaptureJobs.count + (backgroundProcessingInFlight ? 1 : 0)
        return totalPending >= maxPendingBackgroundCaptures
    }

    private var backgroundQueueCount: Int {
        pendingCaptureJobs.count + (backgroundProcessingInFlight ? 1 : 0)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [themeBackgroundTop, themeBackgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

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
                    .padding(.horizontal, topControlsHorizontalPadding)
                    .padding(.top, 16)
                    .padding(.bottom, 6)

                    GeometryReader { proxy in
                        let targetWidth = max(0, proxy.size.width - (exposureHorizontalPadding * 2))
                        let maxWidthFromHeight = max(0, proxy.size.height * (3.0 / 4.0))
                        let previewWidth = min(targetWidth, maxWidthFromHeight)
                        let previewHeight = previewWidth * (4.0 / 3.0)

                        ZStack {
                            CameraPreviewView(
                                session: cameraService.session,
                                activeDevice: cameraService.activeVideoDevice,
                                focusLocked: cameraService.focusLocked,
                                onTapToFocus: { _, devicePoint in
                                    cameraService.focus(at: devicePoint, lockFocus: false)
                                },
                                onLongPressToFocusLock: { _, devicePoint in
                                    cameraService.focus(at: devicePoint, lockFocus: true)
                                }
                            )
                            .frame(width: previewWidth, height: previewHeight)
                            .overlay(alignment: .top) {
                                if backgroundQueueCount > 0 {
                                    backgroundQueueIndicator
                                        .padding(.top, 10)
                                }
                            }
                            .overlay(
                                Rectangle()
                                    .stroke(themeTeal, lineWidth: 1)
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        exposureSlider
                            .padding(.top, 8)

                        presetStrip
                            .padding(.top, 8)

                        controls
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                    }
                    .padding(.bottom, 0)
                }

            case .denied, .restricted:
                deniedView

            case .notDetermined:
                ProgressView("Waiting for camera permission...")
                    .tint(themeTeal)
                    .foregroundStyle(themeTextPrimary)

            @unknown default:
                Text("Unknown camera permission state.")
                    .foregroundStyle(themeTextPrimary)
            }
        }
        .tint(themeTeal)
        .overlay(alignment: .top) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(themeTextPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        LinearGradient(
                            colors: [themeBackgroundTop.opacity(0.92), themeBackgroundBottom.opacity(0.92)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .stroke(themeTeal.opacity(0.35), lineWidth: 1)
                    )
                    .padding(.top, 16)
            }
        }
        .overlay {
            if let stage = captureProcessingStage {
                captureProcessingOverlay(stage: stage)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
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
            captureStageDismissTask?.cancel()
            backgroundProcessorTask?.cancel()
            backgroundProcessorTask = nil
            backgroundProcessingInFlight = false
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
                scheduleReferenceRender()
            } else {
                referenceRenderGeneration &+= 1
                referenceRenderTask?.cancel()
                referenceRenderTask = nil
                renderedReferenceImage = nil
            }
        }
    }

    // MARK: - Exposure Slider

    private var exposureSlider: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.min.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(themePink.opacity(0.85))
                .frame(width: 22)

            Slider(value: $cameraService.exposureBias, in: cameraService.exposureBiasRange)
                .tint(themeTeal)

            Image(systemName: "sun.max.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(themePink.opacity(0.85))
                .frame(width: 22)

            Text(cameraService.exposureBias >= 0
                 ? "+\(String(format: "%.1f", cameraService.exposureBias))"
                 : String(format: "%.1f", cameraService.exposureBias))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(themeTextSecondary)
                .frame(width: 34, alignment: .trailing)

            Button {
                cameraService.exposureBias = 0
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(themePink.opacity(0.85))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .opacity(abs(cameraService.exposureBias) > 0.05 ? 1 : 0.3)
        }
        .padding(.horizontal, exposureHorizontalPadding)
    }

    private var presetStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    presetIcon(title: "Original", symbol: "camera", isSelected: cameraService.selectedEffectPresetID == PhotoEffectLibrary.customPresetID) {
                        cameraService.resetEffectsToNeutral()
                    }
                    .id(presetScrollTargetID(for: PhotoEffectLibrary.customPresetID))

                    ForEach(cameraService.effectPresets) { preset in
                        presetIcon(
                            title: shortPresetTitle(preset.name),
                            symbol: "camera.filters",
                            isSelected: cameraService.selectedEffectPresetID == preset.id
                        ) {
                            cameraService.applyEffectPreset(preset)
                        }
                        .id(presetScrollTargetID(for: preset.id))
                    }
                }
                .padding(.horizontal, 14)
            }
            .onAppear {
                DispatchQueue.main.async {
                    scrollPresetStrip(to: proxy, animated: false)
                }
            }
            .onChange(of: cameraService.selectedEffectPresetID) { _, _ in
                scrollPresetStrip(to: proxy, animated: true)
            }
            .onChange(of: cameraService.effectPresets.map(\.id)) { _, _ in
                DispatchQueue.main.async {
                    scrollPresetStrip(to: proxy, animated: false)
                }
            }
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
            .foregroundStyle(isSelected ? themeTeal : themePink.opacity(0.9))
            .frame(minWidth: 68)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(isSelected ? themeTeal : .clear)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
                    .offset(y: 4)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        controlButtons
    }

    private var controlButtons: some View {
        ZStack(alignment: .center) {
            HStack(alignment: .center) {
                lensSelector
                Spacer()
                galleryButton
            }
            
            shutterButton
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: - Buttons

    private var settingsButton: some View {
        Button {
            showSettingsSheet = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(themeTeal)
                .frame(width: 54, height: 54)
        }
        .rotationEffect(controlRotationAngle)
        .animation(.easeInOut(duration: 0.2), value: controlRotationAngle)
        .buttonStyle(.plain)
    }

    private var effectsButton: some View {
        Button {
            showEffectsSheet = true
        } label: {
            Image(systemName: "camera.filters")
                .font(.title3.weight(.semibold))
                .foregroundStyle(themePink)
                .frame(width: 54, height: 54)
        }
        .rotationEffect(controlRotationAngle)
        .animation(.easeInOut(duration: 0.2), value: controlRotationAngle)
        .buttonStyle(.plain)
    }

    private var cameraSwitchButton: some View {
        Button {
            cameraService.togglePosition()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.title2.weight(.semibold))
                .foregroundStyle(themeTeal)
                .frame(width: 54, height: 54)
        }
        .rotationEffect(controlRotationAngle)
        .animation(.easeInOut(duration: 0.2), value: controlRotationAngle)
        .buttonStyle(.plain)
    }

    private var shutterButton: some View {
        return Button {
            guard cameraService.isSessionRunning, !cameraService.isCaptureInProgress, captureProcessingStage == nil else { return }
            guard !backgroundQueueIsFull else {
                statusMessage = Self.queueFullStatusMessage
                return
            }
            pendingCaptureRequestContext = CaptureRequestContext(
                effectSettings: cameraService.effectSettingsSnapshot(),
                heifBitDepth: cameraService.styledHEIFBitDepth,
                heifCompressionQuality: cameraService.styledHEIFCompressionQuality,
                processingSource: cameraService.styledProcessingSource,
                saveRAWToLibrary: cameraService.saveRAWToLibrary
            )
            lastCaptureSucceeded = false
            startCaptureProcessingUI()
            cameraService.capturePhoto()
        } label: {
            ZStack {
                Circle()
                    .stroke(themeTeal.opacity(0.95), lineWidth: 4)
                    .frame(width: 82, height: 82)
                Circle()
                    .fill(captureProcessingStage == nil ? (lastCaptureSucceeded ? themePink : themeTeal) : themeTeal.opacity(0.7))
                    .frame(width: 66, height: 66)
                    .animation(.easeInOut(duration: 0.2), value: lastCaptureSucceeded)
            }
        }
        .disabled(cameraService.isCaptureInProgress || captureProcessingStage != nil || backgroundQueueIsFull)
        .opacity((cameraService.isCaptureInProgress || captureProcessingStage != nil || backgroundQueueIsFull) ? 0.72 : 1)
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
                .foregroundStyle(themePink)
                .frame(width: 54, height: 54)
        }
        .rotationEffect(controlRotationAngle)
        .animation(.easeInOut(duration: 0.2), value: controlRotationAngle)
        .buttonStyle(.plain)
    }

    private var lensSelector: some View {
        HStack(spacing: 0) {
            if let currentLens {
                lensTitle(currentLens, textFont: .footnote.weight(.semibold))
            } else {
                Text("Lens")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(themePink.opacity(0.95))
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .overlay {
            // Invisible menu overlapping the hit area
            Menu {
                if cameraService.availableLenses.isEmpty {
                    Button("No lenses available") {}
                        .disabled(true)
                } else {
                    ForEach(cameraService.availableLenses) { lens in
                        Button {
                            cameraService.selectLens(lens)
                        } label: {
                            HStack(spacing: 8) {
                                Text(lensMenuTitle(lens))
                                    .font(.body)
                                Spacer(minLength: 8)
                                if cameraService.selectedLens?.id == lens.id {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                }
                            }
                        }
                    }
                }
            } label: {
                Color.black.opacity(0.001)
            }
        }
        .disabled(cameraService.availableLenses.isEmpty)
        .tint(themePink)
        .rotationEffect(controlRotationAngle, anchor: .center)
        .animation(.easeInOut(duration: 0.2), value: controlRotationAngle)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func lensTitle(_ lens: CameraLens, textFont: Font) -> some View {
        HStack(spacing: 5) {
            Text(lens.name)
                .font(textFont)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if lens.isCropped {
                Text("●")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(themePink)
            }
        }
    }

    private func lensMenuTitle(_ lens: CameraLens) -> String {
        lens.isCropped ? "\(lens.name) ●" : lens.name
    }

    private var currentLens: CameraLens? {
        cameraService.selectedLens ?? cameraService.availableLenses.first
    }

    // MARK: - Permission denied view

    private var deniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(themeTeal)
            Text("Camera access is disabled.")
                .font(.headline)
                .foregroundStyle(themeTextPrimary)
            Text("Enable camera in iOS Settings for TrueCamera.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(themeTextSecondary)
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [themeBackgroundTop.opacity(0.9), themeBackgroundBottom.opacity(0.92)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(themePink.opacity(0.3), lineWidth: 1)
        )
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
                        Picker("Shutter Tone", selection: $cameraService.shutterSoundProfile) {
                            ForEach(CameraShutterSoundProfile.allCases) { tone in
                                Text(tone.label).tag(tone)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(!cameraService.shutterSoundEnabled)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Photo Priority")
                            .font(.subheadline.weight(.semibold))
                        Picker("Photo Priority", selection: $cameraService.capturePriority) {
                            ForEach(PhotoCapturePriority.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Max Resolution")
                            .font(.subheadline.weight(.semibold))
                        Picker("Max Resolution", selection: $cameraService.resolutionCap) {
                            ForEach(PhotoResolutionCap.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Toggle("Save Original RAW (.dng) Separately", isOn: $cameraService.saveRAWToLibrary)
                } header: {
                    Text("Capture")
                } footer: {
                    Text("Balanced is typically faster; Quality may improve low-light/detail at the cost of longer processing time. Lower max resolution can reduce capture and post-processing time. When RAW save is enabled, the original DNG is stored as a separate asset.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Processing Source")
                            .font(.subheadline.weight(.semibold))
                        Picker("Styled Processing Source", selection: $cameraService.styledProcessingSource) {
                            ForEach(StyledProcessingSource.allCases) { source in
                                Text(source.shortLabel).tag(source)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("HEIF Bit Depth")
                            .font(.subheadline.weight(.semibold))
                        Picker("Styled HEIF Bit Depth", selection: $cameraService.styledHEIFBitDepth) {
                            ForEach(StyledHEIFBitDepth.allCases) { bitDepth in
                                Text(bitDepth.shortLabel).tag(bitDepth)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("HEIF Compression")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(Int((cameraService.styledHEIFCompressionQuality * 100).rounded()))%")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(themeTextSecondary)
                        }

                        ThemedSlider(
                            value: heifCompressionPercentBinding,
                            range: StyledHEIFExportDefaults.compressionQualityRange.lowerBound * 100...StyledHEIFExportDefaults.compressionQualityRange.upperBound * 100,
                            minimumTrackColor: themeTeal,
                            maximumTrackColor: themePink.opacity(0.22),
                            thumbColor: themePink
                        )
                        .frame(height: 28)

                        HStack {
                            Text("85%")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(themeTextSecondary.opacity(0.8))
                            Spacer()
                            Text("100%")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(themeTextSecondary.opacity(0.8))
                        }
                    }
                } header: {
                    Text("Styled Export")
                } footer: {
                    Text("ProRAW source gives best quality. Processed source is faster. 10-bit HEIF keeps smoother gradients; 8-bit exports faster and smaller. Compression 100 keeps the largest files; 85 reduces size noticeably while keeping 48 MP.")
                }

                if !cameraService.appleProRAWSupported {
                    Section("Compatibility") {
                        Text("ProRAW is not supported on the current device/lens.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Format") {
                    Text("Capture uses Apple ProRAW at \(cameraService.resolutionCap.label) resolution.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("RAW .dng is stored as a separate original asset when enabled above.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

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
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showSettingsSheet = false }
                        .foregroundStyle(themePink)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var selectedUserPreset: PhotoEffectPreset? {
        cameraService.effectPresets.first(where: { $0.id == cameraService.selectedEffectPresetID })
    }

    private var selectedPresetHasUnsavedChanges: Bool {
        guard let selectedUserPreset else { return false }
        return selectedUserPreset.settings.clamped() != cameraService.effectSettings.clamped()
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
                                    title: "Original",
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
                            Button("Save New") {
                                cameraService.saveCurrentEffectsAsPreset(named: presetNameDraft)
                                presetNameDraft = ""
                            }
                            .disabled(presetNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            if selectedUserPreset != nil {
                                Button("Update") {
                                    cameraService.updateSelectedPresetFromCurrentSettings()
                                }
                                .disabled(!selectedPresetHasUnsavedChanges)
                            }
                        }

                        ForEach(cameraService.effectPresets) { preset in
                            HStack {
                                Text(preset.name)
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
                        cameraService.resetEffectsToNeutral()
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
    }

    private var referencePreview: some View {
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

    private func scheduleReferenceRender() {
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

    private var heifCompressionPercentBinding: Binding<Double> {
        Binding(
            get: { cameraService.styledHEIFCompressionQuality * 100 },
            set: { nextValue in
                cameraService.styledHEIFCompressionQuality = nextValue.rounded() / 100
            }
        )
    }

    private func effectSlider(
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

    private func presetScrollTargetID(for presetID: String) -> String {
        "main-preset-\(presetID)"
    }

    private func scrollPresetStrip(to proxy: ScrollViewProxy, animated: Bool) {
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
        guard result.rawData != nil || result.processedData != nil else {
            finishCaptureProcessingUI(success: false)
            if let unavailableMessage = unavailableCaptureFormatMessage {
                statusMessage = unavailableMessage
            } else {
                statusMessage = "Capture failed (missing photo data)."
            }
            lastCaptureSucceeded = false
            pendingCaptureRequestContext = nil
            return
        }
        let requestContext = pendingCaptureRequestContext ?? currentCaptureRequestContextSnapshot()
        pendingCaptureRequestContext = nil
        enqueueBackgroundCaptureJob(
            rawData: result.rawData,
            processedData: result.processedData,
            requestContext: requestContext
        )
    }

    private func currentCaptureRequestContextSnapshot() -> CaptureRequestContext {
        CaptureRequestContext(
            effectSettings: cameraService.effectSettingsSnapshot(),
            heifBitDepth: cameraService.styledHEIFBitDepth,
            heifCompressionQuality: cameraService.styledHEIFCompressionQuality,
            processingSource: cameraService.styledProcessingSource,
            saveRAWToLibrary: cameraService.saveRAWToLibrary
        )
    }

    private func enqueueBackgroundCaptureJob(
        rawData: Data?,
        processedData: Data?,
        requestContext: CaptureRequestContext
    ) {
        pendingCaptureJobs.append(
            PendingCaptureJob(
                rawData: rawData,
                processedData: processedData,
                requestContext: requestContext
            )
        )
        startBackgroundProcessingIfNeeded()
    }

    private func startBackgroundProcessingIfNeeded() {
        guard backgroundProcessorTask == nil else { return }
        backgroundProcessorTask = Task { @MainActor in
            await processPendingCaptureJobs()
        }
    }

    @MainActor
    private func processPendingCaptureJobs() async {
        while !Task.isCancelled, !pendingCaptureJobs.isEmpty {
            backgroundProcessingInFlight = true
            let job = pendingCaptureJobs.removeFirst()

            let styledResource = await cameraService.buildStyledPhotoData(
                rawData: job.rawData,
                processedData: job.processedData,
                settings: job.requestContext.effectSettings,
                preferredHEIFBitDepth: job.requestContext.heifBitDepth,
                preferredHEIFCompressionQuality: job.requestContext.heifCompressionQuality,
                preferredProcessingSource: job.requestContext.processingSource
            )
            let rawDataToSave = job.requestContext.saveRAWToLibrary ? job.rawData : nil
            let (saveOk, saveErrorMessage) = await saveToPhotoLibrary(rawData: rawDataToSave, styledResource: styledResource)
            lastCaptureSucceeded = saveOk

            if saveOk {
                if pendingCaptureJobs.isEmpty, statusMessage == Self.queueFullStatusMessage {
                    statusMessage = nil
                }
            } else {
                statusMessage = photoPermissionDenied
                    ? "Photos permission denied. Enable it in Settings."
                    : "Save failed: \(saveErrorMessage ?? "Unknown Photos error")"
            }
        }
        backgroundProcessingInFlight = false
        backgroundProcessorTask = nil
        if statusMessage == Self.queueFullStatusMessage {
            statusMessage = nil
        }
    }

    private var unavailableCaptureFormatMessage: String? {
        switch cameraService.captureFormat {
        case .appleProRAW:
            return cameraService.appleProRAWActive ? nil : "ProRAW is not available for the selected camera/lens."
        }
    }

    // MARK: - Photos library

    private func saveToPhotoLibrary(
        rawData: Data?,
        styledResource: (data: Data, uniformTypeIdentifier: String)?
    ) async -> (Bool, String?) {
        let authStatus = await ensurePhotoWriteAuthorization()
        guard authStatus == .authorized || authStatus == .limited else {
            return (false, "No Photos write permission")
        }
        guard rawData != nil || styledResource != nil else { return (false, "No photo data to save") }

        var tempPhotoFileURL: URL?
        if let rawData {
            guard let tempURL = await writeRawTempFile(rawData) else {
                return (false, "Couldn't prepare temporary DNG file")
            }
            tempPhotoFileURL = tempURL
        }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                let creationDate = Date()
                if let styledResource {
                    let request = PHAssetCreationRequest.forAsset()
                    request.creationDate = creationDate
                    let options = PHAssetResourceCreationOptions()
                    options.uniformTypeIdentifier = normalizedOutputUTI(styledResource.uniformTypeIdentifier)
                    request.addResource(with: .photo, data: styledResource.data, options: options)
                }
                if let tempPhotoFileURL {
                    let request = PHAssetCreationRequest.forAsset()
                    request.creationDate = creationDate
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = true
                    request.addResource(with: .photo, fileURL: tempPhotoFileURL, options: options)
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

    private func normalizedOutputUTI(_ candidate: String) -> String {
        if candidate == UTType.jpeg.identifier || candidate == "public.jpeg" {
            return UTType.jpeg.identifier
        }
        if candidate == UTType.heic.identifier || candidate == "public.heic" {
            return UTType.heic.identifier
        }
        return UTType.heic.identifier
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

    private var backgroundQueueIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(themePink)
                .frame(width: 5, height: 5)
            Text("processing, do not close the app.")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(themePink.opacity(0.96))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(themeBackgroundTop.opacity(0.78), in: Capsule())
        .overlay(Capsule().stroke(themePink.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
    }

    // MARK: - Processing UI

    private func startCaptureProcessingUI() {
        captureStageDismissTask?.cancel()
        processingSpinnerRotation = 0
        processingPulse = false
        setCaptureStage(.capturing)

        withAnimation(.linear(duration: 0.26)) {
            processingSpinnerRotation = 240
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            processingPulse = true
        }

        captureStageDismissTask = Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if captureProcessingStage == .capturing {
                    withAnimation(.easeOut(duration: 0.18)) {
                        captureProcessingStage = nil
                    }
                    processingPulse = false
                    processingSpinnerRotation = 0
                }
            }
        }
    }

    private func finishCaptureProcessingUI(success: Bool) {
        setCaptureStage(success ? .done : .failed)

        captureStageDismissTask?.cancel()
        captureStageDismissTask = Task {
            try? await Task.sleep(nanoseconds: 580_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.22)) {
                    captureProcessingStage = nil
                }
                processingPulse = false
                processingSpinnerRotation = 0
            }
        }
    }

    private func setCaptureStage(_ stage: CaptureProcessingStage) {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
            captureProcessingStage = stage
        }
    }

    @ViewBuilder
    private func captureProcessingOverlay(stage: CaptureProcessingStage) -> some View {
        ZStack {
            Rectangle()
                .fill(themeBackgroundBottom.opacity(0.7))
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.14), lineWidth: 6)
                        .frame(width: 84, height: 84)
                    Circle()
                        .trim(from: 0.16, to: 0.92)
                        .stroke(
                            AngularGradient(
                                colors: [themePink.opacity(0.2), stage.accentColor, themeTeal.opacity(0.95)],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .frame(width: 84, height: 84)
                        .rotationEffect(.degrees(processingSpinnerRotation))
                        .scaleEffect(processingPulse ? 1.06 : 0.95)

                    Image(systemName: stage.symbol)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(stage.accentColor)
                }

                VStack(spacing: 4) {
                    Text(stage.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(themeTextPrimary)
                    Text(stage.subtitle)
                        .font(.footnote)
                        .foregroundStyle(themeTextSecondary)
                }

                HStack(spacing: 8) {
                    processingStepChip(title: "RAW", isActive: stage.progressStep >= 1, accent: stage.accentColor)
                    processingStepChip(title: "Style", isActive: stage.progressStep >= 2, accent: stage.accentColor)
                    processingStepChip(title: "Save", isActive: stage.progressStep >= 3, accent: stage.accentColor)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
            .frame(maxWidth: 320)
            .background(
                LinearGradient(
                    colors: [
                        themeBackgroundTop.opacity(0.95),
                        themeBackgroundBottom.opacity(0.95),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [themeTeal.opacity(0.55), themePink.opacity(0.45)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 18)
            .padding(.horizontal, 24)
        }
        .allowsHitTesting(true)
    }

    private func processingStepChip(title: String, isActive: Bool, accent: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isActive ? themeTextPrimary : themeTextSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? accent.opacity(0.25) : themeBackgroundTop.opacity(0.45), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(isActive ? accent.opacity(0.9) : themePink.opacity(0.22), lineWidth: 1)
            )
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

    private static func loadEditorReferenceImage() -> UIImage? {
        for name in ["Image", "image", "bird"] {
            if let image = UIImage(named: name) {
                return image
            }
        }

        let bundledCandidates = [
            ("image", "DNG"),
            ("image", "dng"),
            ("Image", "DNG"),
            ("Image", "dng"),
            ("image", "jpg"),
            ("Image", "jpg"),
            ("bird", "jpg")
        ]

        for (name, ext) in bundledCandidates {
            guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { continue }
            if let image = loadEditorReferenceImage(from: url) {
                return image
            }
        }

        return nil
    }

    private static func loadEditorReferenceImage(from url: URL) -> UIImage? {
        if url.pathExtension.lowercased() == "dng" {
            return loadRawEditorReferenceImage(from: url)
        }
        return UIImage(contentsOfFile: url.path)
    }

    private static func loadRawEditorReferenceImage(from url: URL) -> UIImage? {
        let rawOptions: [CIRAWFilterOption: Any] = [.allowDraftMode: false]
        let input = (CIFilter(imageURL: url, options: rawOptions) as? CIRAWFilter)?.outputImage
            ?? CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        guard let input else { return nil }

        let extent = input.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }

        let scale = min(1, editorReferenceMaxDimension / max(extent.width, extent.height))
        let output = scale < 1
            ? input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : input

        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let context = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace
        ])
        guard let cgImage = context.createCGImage(output, from: output.extent.integral) else { return nil }
        return UIImage(cgImage: cgImage)
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

private struct ThemedSlider: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let minimumTrackColor: Color
    let maximumTrackColor: Color
    let thumbColor: Color

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider(frame: .zero)
        slider.isContinuous = true
        slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        return slider
    }

    func updateUIView(_ uiView: UISlider, context: Context) {
        uiView.minimumValue = Float(range.lowerBound)
        uiView.maximumValue = Float(range.upperBound)
        uiView.minimumTrackTintColor = UIColor(minimumTrackColor)
        uiView.maximumTrackTintColor = UIColor(maximumTrackColor)
        uiView.thumbTintColor = UIColor(thumbColor)

        let currentValue = Float(value)
        if abs(uiView.value - currentValue) > 0.0001 {
            uiView.value = currentValue
        }
    }

    final class Coordinator: NSObject {
        @Binding private var value: Double

        init(value: Binding<Double>) {
            _value = value
        }

        @objc func valueChanged(_ sender: UISlider) {
            value = Double(sender.value)
        }
    }
}

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
