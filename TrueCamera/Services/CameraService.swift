@preconcurrency internal import AVFoundation
import Combine
import Foundation
import ImageIO
import QuartzCore
import UIKit

nonisolated struct CameraLens: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let deviceType: AVCaptureDevice.DeviceType
    let position: AVCaptureDevice.Position
    /// Zoom factor to apply via videoZoomFactor (1.0 = native, 2.0 = 2x crop).
    let zoomFactor: CGFloat
    /// Sort order for UI display (lower = wider).
    let sortOrder: Int
}

nonisolated struct CameraCaptureResult: Sendable {
    let rawData: Data?
    let processedData: Data?
}

nonisolated enum CameraCaptureFormat: String, CaseIterable, Identifiable, Sendable {
    case appleProRAW

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleProRAW: return "ProRAW"
        }
    }
}

nonisolated enum StyledHEIFBitDepth: String, CaseIterable, Identifiable, Sendable {
    case tenBit = "10bit"
    case eightBit = "8bit"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .tenBit: return "10-bit"
        case .eightBit: return "8-bit"
        }
    }

    var label: String {
        switch self {
        case .tenBit: return "10-bit (Max Quality)"
        case .eightBit: return "8-bit (Faster)"
        }
    }
}

nonisolated enum StyledProcessingSource: String, CaseIterable, Identifiable, Sendable {
    case proRAW = "proraw"
    case processed = "processed"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .proRAW: return "ProRAW"
        case .processed: return "Processed"
        }
    }

    var label: String {
        switch self {
        case .proRAW: return "ProRAW (Max Quality)"
        case .processed: return "Processed (Faster)"
        }
    }
}

nonisolated enum PhotoCapturePriority: String, CaseIterable, Identifiable, Sendable {
    case balanced = "balanced"
    case quality = "quality"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .balanced: return "Balanced"
        case .quality: return "Quality"
        }
    }

    var photoQualityPrioritization: AVCapturePhotoOutput.QualityPrioritization {
        switch self {
        case .balanced: return .balanced
        case .quality: return .quality
        }
    }
}

nonisolated enum PhotoResolutionCap: String, CaseIterable, Identifiable, Sendable {
    case full = "full"
    case mp12 = "12mp"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: return "Full"
        case .mp12: return "12 MP"
        }
    }

    var targetPixelCount: Int64? {
        switch self {
        case .full: return nil
        case .mp12: return 12_000_000
        }
    }
}

final class CameraService: NSObject, ObservableObject {
    private enum PreferenceKey {
        static let hapticsEnabled = "camera.hapticsEnabled"
        static let shutterSoundEnabled = "camera.shutterSoundEnabled"
        static let captureFormat = "camera.captureFormat"
        static let capturePriority = "camera.capturePriority"
        static let resolutionCap = "camera.resolutionCap"
        static let styledHEIFBitDepth = "camera.styledHEIFBitDepth"
        static let styledProcessingSource = "camera.styledProcessingSource"
        static let saveRAWToLibrary = "camera.saveRAWToLibrary"
        static let selectedEffectPresetID = "camera.selectedEffectPresetID"
        static let effectSettingsBlob = "camera.effect.settingsBlob.v3"
        static let effectPresetsBlob = "camera.effect.userPresetsBlob.v2"
    }

    @Published private(set) var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var activeVideoDevice: AVCaptureDevice?
    @Published private(set) var isSessionRunning = false
    @Published private(set) var isCaptureInProgress = false
    @Published private(set) var availableLenses: [CameraLens] = []
    @Published private(set) var currentPosition: AVCaptureDevice.Position = .back
    @Published private(set) var selectedLens: CameraLens?
    @Published private(set) var deviceChangeCount = 0
    @Published private(set) var appleProRAWSupported = false
    @Published private(set) var appleProRAWActive = false
    @Published private(set) var focusPointSupported = false
    @Published private(set) var focusLocked = false
    @Published var hapticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticsEnabled, forKey: PreferenceKey.hapticsEnabled)
            if hapticsEnabled {
                DispatchQueue.main.async { [weak self] in
                    self?.shutterHapticGenerator.prepare()
                }
            }
        }
    }
    @Published var shutterSoundEnabled: Bool {
        didSet { UserDefaults.standard.set(shutterSoundEnabled, forKey: PreferenceKey.shutterSoundEnabled) }
    }
    @Published var captureFormat: CameraCaptureFormat {
        didSet {
            UserDefaults.standard.set(captureFormat.rawValue, forKey: PreferenceKey.captureFormat)
            refreshCaptureConfigurationForCurrentFormat()
        }
    }
    @Published var capturePriority: PhotoCapturePriority {
        didSet { UserDefaults.standard.set(capturePriority.rawValue, forKey: PreferenceKey.capturePriority) }
    }
    @Published var resolutionCap: PhotoResolutionCap {
        didSet {
            UserDefaults.standard.set(resolutionCap.rawValue, forKey: PreferenceKey.resolutionCap)
            sessionQueue.async { [weak self] in self?.updateMaxPhotoDimensions() }
        }
    }
    @Published var styledHEIFBitDepth: StyledHEIFBitDepth {
        didSet { UserDefaults.standard.set(styledHEIFBitDepth.rawValue, forKey: PreferenceKey.styledHEIFBitDepth) }
    }
    @Published var styledProcessingSource: StyledProcessingSource {
        didSet { UserDefaults.standard.set(styledProcessingSource.rawValue, forKey: PreferenceKey.styledProcessingSource) }
    }
    @Published var saveRAWToLibrary: Bool {
        didSet { UserDefaults.standard.set(saveRAWToLibrary, forKey: PreferenceKey.saveRAWToLibrary) }
    }
    @Published var exposureBias: Float = 0 {
        didSet { applyExposureBias() }
    }
    @Published private(set) var exposureBiasRange: ClosedRange<Float> = -2.0...2.0
    @Published private(set) var livePreviewImage: UIImage?
    @Published private(set) var selectedEffectPresetID: String = PhotoEffectLibrary.customPresetID {
        didSet { UserDefaults.standard.set(selectedEffectPresetID, forKey: PreferenceKey.selectedEffectPresetID) }
    }
    @Published private(set) var effectPresets: [PhotoEffectPreset] = [] {
        didSet { persistEffectPresets(effectPresets) }
    }
    @Published var effectSettings: PhotoEffectSettings = .neutral {
        didSet {
            let normalized = effectSettings.clamped()
            if normalized != effectSettings {
                effectSettings = normalized
                return
            }
            schedulePersistEffectSettings(normalized)
            schedulePrewarmExportPipeline(for: normalized)
            let snapshot = normalized
            previewStateQueue.async { [weak self] in
                self?.previewEffectSettings = snapshot
            }
        }
    }

    let session = AVCaptureSession()
    var onPhotoCapture: ((CameraCaptureResult) -> Void)?

    private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let videoDataOutput = AVCaptureVideoDataOutput()
    private let effectsProcessor = PhotoEffectsProcessor()
    private let exportEffectsProcessor = PhotoEffectsProcessor()
    private var currentInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var captureRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var captureRotationObservation: NSKeyValueObservation?

    private var activeProcessors: [Int64: PhotoCaptureProcessor] = [:]
    private var isPhotoCaptureInFlight = false

    private let backDiscoverySession: AVCaptureDevice.DiscoverySession
    private let frontDiscoverySession: AVCaptureDevice.DiscoverySession

    private let sessionQueue = DispatchQueue(label: "com.movieshot.session")
    private let previewOutputQueue = DispatchQueue(label: "com.movieshot.preview.output")
    private let previewStateQueue = DispatchQueue(label: "com.movieshot.preview.state")
    private let persistenceQueue = DispatchQueue(label: "com.movieshot.persistence", qos: .utility)
    private let prewarmQueue = DispatchQueue(label: "com.movieshot.export.prewarm", qos: .utility)
    private let exportQueue = DispatchQueue(label: "com.movieshot.export", qos: .userInitiated)
    private let shutterHapticGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let tapToContinuousFocusDelay: TimeInterval = 0.75
    private let longPressFocusLockDelay: TimeInterval = 0.25
    private var focusLockRequested = false
    private var pendingFocusLockWorkItem: DispatchWorkItem?
    private var pendingContinuousFocusWorkItem: DispatchWorkItem?
    nonisolated(unsafe) private var previewEffectSettings: PhotoEffectSettings = .neutral
    nonisolated(unsafe) private var previewIsFrontCamera = false
    nonisolated(unsafe) private var previewRenderingEnabled = true
    nonisolated(unsafe) private var previewOverlayActive = false
    nonisolated(unsafe) private var lastPreviewRenderTime: CFTimeInterval = 0
    private var persistEffectSettingsWorkItem: DispatchWorkItem?
    private var prewarmExportWorkItem: DispatchWorkItem?

    var activeCaptureBadgeText: String? {
        appleProRAWActive ? "ProRAW" : nil
    }

    var isShutterSoundToggleAvailable: Bool {
        if #available(iOS 18.0, *) { return photoOutput.isShutterSoundSuppressionSupported }
        return false
    }

    override init() {
        let physicalTypes: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera,
            .builtInWideAngleCamera,
            .builtInTelephotoCamera,
        ]
        self.backDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: physicalTypes,
            mediaType: .video,
            position: .back
        )
        let frontTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInTrueDepthCamera,
        ]
        self.frontDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: frontTypes,
            mediaType: .video,
            position: .front
        )
        self.hapticsEnabled = UserDefaults.standard.object(forKey: PreferenceKey.hapticsEnabled) as? Bool ?? true
        self.shutterSoundEnabled = UserDefaults.standard.object(forKey: PreferenceKey.shutterSoundEnabled) as? Bool ?? true
        let storedCaptureFormatRaw = UserDefaults.standard.string(forKey: PreferenceKey.captureFormat)
        self.captureFormat = CameraCaptureFormat(rawValue: storedCaptureFormatRaw ?? "") ?? .appleProRAW
        let storedCapturePriorityRaw = UserDefaults.standard.string(forKey: PreferenceKey.capturePriority)
        self.capturePriority = PhotoCapturePriority(rawValue: storedCapturePriorityRaw ?? "") ?? .quality
        let storedResolutionCapRaw = UserDefaults.standard.string(forKey: PreferenceKey.resolutionCap)
        self.resolutionCap = PhotoResolutionCap(rawValue: storedResolutionCapRaw ?? "") ?? .full
        let storedBitDepthRaw = UserDefaults.standard.string(forKey: PreferenceKey.styledHEIFBitDepth)
        self.styledHEIFBitDepth = StyledHEIFBitDepth(rawValue: storedBitDepthRaw ?? "") ?? .tenBit
        let storedProcessingSourceRaw = UserDefaults.standard.string(forKey: PreferenceKey.styledProcessingSource)
        self.styledProcessingSource = StyledProcessingSource(rawValue: storedProcessingSourceRaw ?? "") ?? .proRAW
        self.saveRAWToLibrary = UserDefaults.standard.object(forKey: PreferenceKey.saveRAWToLibrary) as? Bool ?? false
        let loadedPresets = Self.loadStoredEffectPresets()
        self.effectPresets = loadedPresets
        self.effectSettings = Self.loadStoredEffectSettings().clamped()
        let storedPresetID = UserDefaults.standard.string(forKey: PreferenceKey.selectedEffectPresetID) ?? PhotoEffectLibrary.customPresetID
        if storedPresetID == PhotoEffectLibrary.customPresetID ||
            loadedPresets.contains(where: { $0.id == storedPresetID }) {
            self.selectedEffectPresetID = storedPresetID
        } else {
            self.selectedEffectPresetID = PhotoEffectLibrary.customPresetID
        }

        super.init()
        session.sessionPreset = .photo
        availableLenses = buildLenses(for: .back)
        previewEffectSettings = effectSettings
        if hapticsEnabled {
            DispatchQueue.main.async { [weak self] in
                self?.shutterHapticGenerator.prepare()
            }
        }
    }

    func capturePhoto() {
        guard isSessionRunning else { return }
        prewarmExportWorkItem?.cancel()
        prewarmExportWorkItem = nil
        if hapticsEnabled {
            DispatchQueue.main.async { [weak self] in
                self?.shutterHapticGenerator.impactOccurred(intensity: 0.9)
                self?.shutterHapticGenerator.prepare()
            }
        }
        sessionQueue.async { [weak self] in
            guard let self, !self.isPhotoCaptureInFlight else { return }
            self.isPhotoCaptureInFlight = true
            DispatchQueue.main.async { self.isCaptureInProgress = true }
            self.capturePhotoNow()
        }
    }

    func requestPermissionIfNeeded() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        authorizationStatus = status
        guard status == .notDetermined else {
            if status == .authorized {
                configureSessionIfNeeded()
                startSession()
            }
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationStatus = granted ? .authorized : .denied
                if granted {
                    self.configureSessionIfNeeded()
                    self.startSession()
                }
            }
        }
    }

    func configureSessionIfNeeded() {
        guard authorizationStatus == .authorized else { return }
        sessionQueue.async { [weak self] in
            guard let self, !self.isConfigured else { return }
            self.session.beginConfiguration()
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.maxPhotoQualityPrioritization = .quality
            }
            if self.session.canAddOutput(self.videoDataOutput) {
                self.session.addOutput(self.videoDataOutput)
                self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
                self.videoDataOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                self.videoDataOutput.setSampleBufferDelegate(self, queue: self.previewOutputQueue)
            }
            self.updateRAWAvailability(inConfiguration: true)
            self.session.commitConfiguration()
            self.isConfigured = true
            let initialPosition: AVCaptureDevice.Position = .back
            let lenses = self.reloadLenses(for: initialPosition)
            self.configureInput(for: self.defaultLens(from: lenses))
            DispatchQueue.main.async { self.currentPosition = initialPosition }
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async { self.isSessionRunning = self.session.isRunning }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            self.previewOverlayActive = false
            DispatchQueue.main.async {
                self.isSessionRunning = self.session.isRunning
                self.livePreviewImage = nil
            }
        }
    }

    func togglePosition() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let newPosition: AVCaptureDevice.Position = self.currentPosition == .back ? .front : .back
            let lenses = self.reloadLenses(for: newPosition)
            self.configureInput(for: self.defaultLens(from: lenses))
            DispatchQueue.main.async { self.currentPosition = newPosition }
        }
    }

    func applyEffectPreset(_ preset: PhotoEffectPreset) {
        selectedEffectPresetID = preset.id
        effectSettings = preset.settings.clamped()
    }

    func resetEffectsToNeutral() {
        selectedEffectPresetID = PhotoEffectLibrary.customPresetID
        effectSettings = .neutral
    }

    func updateEffectSetting(_ update: (inout PhotoEffectSettings) -> Void) {
        var next = effectSettings
        update(&next)
        effectSettings = next.clamped()
    }

    func saveCurrentEffectsAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let existingNames = Set(effectPresets.map { $0.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) })
        var resolvedName = trimmed
        var suffix = 2
        while existingNames.contains(resolvedName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)) {
            resolvedName = "\(trimmed) \(suffix)"
            suffix += 1
        }

        let preset = PhotoEffectPreset(
            id: UUID().uuidString,
            name: resolvedName,
            settings: effectSettings.clamped()
        )
        effectPresets.append(preset)
        selectedEffectPresetID = preset.id
    }

    func updateSelectedPresetFromCurrentSettings() {
        guard let selectedIndex = effectPresets.firstIndex(where: { $0.id == selectedEffectPresetID }) else { return }
        var nextPresets = effectPresets
        nextPresets[selectedIndex].settings = effectSettings.clamped()
        effectPresets = nextPresets
    }

    func deleteEffectPreset(_ preset: PhotoEffectPreset) {
        effectPresets.removeAll { $0.id == preset.id }
        if selectedEffectPresetID == preset.id {
            selectedEffectPresetID = PhotoEffectLibrary.customPresetID
        }
    }

    func effectSettingsSnapshot() -> PhotoEffectSettings {
        previewStateQueue.sync { previewEffectSettings }
    }

    func setLivePreviewEnabled(_ enabled: Bool) {
        previewStateQueue.async { [weak self] in
            self?.previewRenderingEnabled = enabled
        }
        if !enabled {
            previewOverlayActive = false
            livePreviewImage = nil
        }
    }

    func buildStyledPhotoData(
        rawData: Data?,
        processedData: Data?
    ) async -> (data: Data, uniformTypeIdentifier: String)? {
        guard rawData != nil || processedData != nil else { return nil }
        let settings = effectSettingsSnapshot()
        let exportBitDepth = styledHEIFBitDepth
        let processingSource = styledProcessingSource
        return await buildStyledPhotoData(
            rawData: rawData,
            processedData: processedData,
            settings: settings,
            preferredHEIFBitDepth: exportBitDepth,
            preferredProcessingSource: processingSource
        )
    }

    func buildStyledPhotoData(
        rawData: Data?,
        processedData: Data?,
        settings: PhotoEffectSettings,
        preferredHEIFBitDepth: StyledHEIFBitDepth,
        preferredProcessingSource: StyledProcessingSource
    ) async -> (data: Data, uniformTypeIdentifier: String)? {
        guard rawData != nil || processedData != nil else { return nil }
        return await withCheckedContinuation { continuation in
            exportQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let rendered = self.exportEffectsProcessor.renderProcessedImageData(
                    rawData: rawData,
                    processedData: processedData,
                    settings: settings,
                    preferredHEIFBitDepth: preferredHEIFBitDepth,
                    preferredProcessingSource: preferredProcessingSource
                )
                continuation.resume(returning: rendered)
            }
        }
    }

    private func defaultLens(from lenses: [CameraLens]) -> CameraLens? {
        lenses.first(where: { $0.deviceType == .builtInWideAngleCamera && $0.zoomFactor == 1.0 }) ?? lenses.first
    }

    func selectLens(_ lens: CameraLens) {
        sessionQueue.async { [weak self] in
            guard let self, lens.position == self.currentPosition else { return }
            self.configureInput(for: lens)
        }
    }

    func focus(at devicePoint: CGPoint, lockFocus: Bool = false) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            guard device.isFocusPointOfInterestSupported else { return }
            guard device.isFocusModeSupported(.autoFocus) || device.isFocusModeSupported(.continuousAutoFocus) else { return }

            self.cancelPendingFocusTransitions()
            self.focusLockRequested = lockFocus
            DispatchQueue.main.async { self.focusLocked = lockFocus }

            let point = CGPoint(x: min(max(devicePoint.x, 0), 1), y: min(max(devicePoint.y, 0), 1))
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.focusPointOfInterest = point
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                device.isSubjectAreaChangeMonitoringEnabled = !lockFocus
            } catch {
                print("CameraService: focus error: \(error)")
                return
            }

            if lockFocus {
                self.scheduleFocusLockIfNeeded(for: device)
            } else {
                self.scheduleReturnToContinuousFocusIfNeeded(for: device)
            }
        }
    }

    // MARK: - Private

    private func buildLenses(for position: AVCaptureDevice.Position) -> [CameraLens] {
        let discovery = position == .back ? backDiscoverySession : frontDiscoverySession
        let uniqueDevices = Dictionary(grouping: discovery.devices, by: \.deviceType).compactMap { $0.value.first }
        guard position == .back else {
            return uniqueDevices.map { device in
                CameraLens(
                    id: "\(device.position.rawValue)-\(device.deviceType.rawValue)",
                    name: "Front",
                    deviceType: device.deviceType,
                    position: device.position,
                    zoomFactor: 1.0,
                    sortOrder: 10
                )
            }
        }

        let ultraDevice = uniqueDevices.first(where: { $0.deviceType == .builtInUltraWideCamera })
        let wideDevice = uniqueDevices.first(where: { $0.deviceType == .builtInWideAngleCamera })
        let teleDevice = uniqueDevices.first(where: { $0.deviceType == .builtInTelephotoCamera })
        var lenses: [CameraLens] = []

        if let ultraDevice {
            lenses.append(
                CameraLens(
                    id: "\(ultraDevice.position.rawValue)-\(ultraDevice.deviceType.rawValue)",
                    name: "14mm",
                    deviceType: ultraDevice.deviceType,
                    position: ultraDevice.position,
                    zoomFactor: 1.0,
                    sortOrder: 140
                )
            )
        }

        if let wideDevice {
            let pos = wideDevice.position.rawValue
            let type = wideDevice.deviceType.rawValue
            lenses.append(
                CameraLens(
                    id: "\(pos)-\(type)",
                    name: "24mm",
                    deviceType: wideDevice.deviceType,
                    position: wideDevice.position,
                    zoomFactor: 1.0,
                    sortOrder: 240
                )
            )
            let maxWideZoom = Double(wideDevice.activeFormat.videoMaxZoomFactor)
            let crop35Zoom = 35.0 / 24.0
            let crop50Zoom = 50.0 / 24.0
            if maxWideZoom >= crop35Zoom {
                lenses.append(
                    CameraLens(
                        id: "\(pos)-\(type)-35mm-crop",
                        name: "35mm crop",
                        deviceType: wideDevice.deviceType,
                        position: wideDevice.position,
                        zoomFactor: CGFloat(crop35Zoom),
                        sortOrder: 350
                    )
                )
            }
            if maxWideZoom >= crop50Zoom {
                lenses.append(
                    CameraLens(
                        id: "\(pos)-\(type)-50mm-crop",
                        name: "50mm crop",
                        deviceType: wideDevice.deviceType,
                        position: wideDevice.position,
                        zoomFactor: CGFloat(crop50Zoom),
                        sortOrder: 500
                    )
                )
            }
        }

        if let teleDevice {
            let teleMM = inferredTeleEquivalentMM(for: teleDevice, relativeTo: wideDevice)
            let pos = teleDevice.position.rawValue
            let type = teleDevice.deviceType.rawValue
            lenses.append(
                CameraLens(
                    id: "\(pos)-\(type)",
                    name: "\(teleMM)mm",
                    deviceType: teleDevice.deviceType,
                    position: teleDevice.position,
                    zoomFactor: 1.0,
                    sortOrder: teleMM * 10
                )
            )

            let maxTeleZoom = Double(teleDevice.activeFormat.videoMaxZoomFactor)
            if maxTeleZoom >= 1.95 {
                let teleCropMM = roundedMillimeters(Double(teleMM) * 2.0)
                lenses.append(
                    CameraLens(
                        id: "\(pos)-\(type)-tele-2x-crop",
                        name: "\(teleCropMM)mm crop",
                        deviceType: teleDevice.deviceType,
                        position: teleDevice.position,
                        zoomFactor: 2.0,
                        sortOrder: teleCropMM * 10 + 1
                    )
                )
            }
        }

        // Fallback to a generic wide lens if discovery did not return expected camera types.
        if lenses.isEmpty, let fallback = uniqueDevices.first {
            lenses.append(
                CameraLens(
                    id: "\(fallback.position.rawValue)-\(fallback.deviceType.rawValue)",
                    name: "24mm",
                    deviceType: fallback.deviceType,
                    position: fallback.position,
                    zoomFactor: 1.0,
                    sortOrder: 240
                )
            )
        }

        return lenses.sorted { $0.sortOrder < $1.sortOrder }
    }

    private func reloadLenses(for position: AVCaptureDevice.Position) -> [CameraLens] {
        let sorted = buildLenses(for: position)
        DispatchQueue.main.async { self.availableLenses = sorted }
        return sorted
    }

    private func configureInput(for lens: CameraLens?) {
        guard let lens else { return }
        guard let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: lens.position)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: lens.position)
        else { return }

        cancelPendingFocusTransitions()
        focusLockRequested = false
        DispatchQueue.main.async { self.focusLocked = false }

        defer { DispatchQueue.main.async { self.selectedLens = lens } }

        if let currentInput, currentInput.device == device {
            applyZoom(lens.zoomFactor, to: device)
            updateFocusCapabilities(for: device)
            updateExposureBiasRange(for: device)
            applyAutoExposure(to: device)
            applyExposureBiasToDevice(device)
            updateMaxPhotoDimensions()
            updateRAWAvailability(inConfiguration: false)
            updatePreviewCameraPosition(isFront: lens.position == .front)
            updateVideoOutputMirroring()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            defer {
                session.commitConfiguration()
                updateMaxPhotoDimensions()
            }
            if let currentInput {
                session.removeInput(currentInput)
                self.currentInput = nil
            }
            guard session.canAddInput(input) else {
                print("CameraService: canAddInput failed for \(lens.name)")
                return
            }
            session.addInput(input)
            currentInput = input
            applyZoom(lens.zoomFactor, to: device)
            updateFocusCapabilities(for: device)
            updateExposureBiasRange(for: device)
            applyAutoExposure(to: device)
            applyExposureBiasToDevice(device)
            updateRAWAvailability(inConfiguration: true)
            setupCaptureRotationCoordinator(for: device)
            updatePreviewCameraPosition(isFront: lens.position == .front)
            updateVideoOutputMirroring()
            DispatchQueue.main.async {
                self.activeVideoDevice = device
                self.deviceChangeCount += 1
            }
        } catch {
            print("CameraService: input error: \(error)")
        }
    }

    private func applyAutoExposure(to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        } catch {
            print("CameraService: auto exposure error: \(error)")
        }
    }

    private func applyExposureBias() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            self.applyExposureBiasToDevice(device)
        }
    }

    private func applyExposureBiasToDevice(_ device: AVCaptureDevice) {
        let bias = min(max(exposureBias, device.minExposureTargetBias), device.maxExposureTargetBias)
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(bias, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            print("CameraService: exposure bias error: \(error)")
        }
    }

    private func updateExposureBiasRange(for device: AVCaptureDevice) {
        let minBias = device.minExposureTargetBias
        let maxBias = device.maxExposureTargetBias
        DispatchQueue.main.async {
            self.exposureBiasRange = minBias...maxBias
            let clamped = min(max(self.exposureBias, minBias), maxBias)
            if self.exposureBias != clamped { self.exposureBias = clamped }
        }
    }

    private func applyZoom(_ factor: CGFloat, to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = min(factor, device.activeFormat.videoMaxZoomFactor)
            device.unlockForConfiguration()
        } catch {
            print("CameraService: zoom error: \(error)")
        }
    }

    private func cancelPendingFocusTransitions() {
        pendingFocusLockWorkItem?.cancel()
        pendingFocusLockWorkItem = nil
        pendingContinuousFocusWorkItem?.cancel()
        pendingContinuousFocusWorkItem = nil
    }

    private func scheduleFocusLockIfNeeded(for device: AVCaptureDevice) {
        guard device.isFocusModeSupported(.locked) else {
            focusLockRequested = false
            DispatchQueue.main.async { self.focusLocked = false }
            scheduleReturnToContinuousFocusIfNeeded(for: device)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.focusLockRequested, self.currentInput?.device == device else { return }
            do {
                try device.lockForConfiguration()
                device.focusMode = .locked
                device.isSubjectAreaChangeMonitoringEnabled = false
                device.unlockForConfiguration()
            } catch {
                print("CameraService: focus lock error: \(error)")
            }
        }
        pendingFocusLockWorkItem = work
        sessionQueue.asyncAfter(deadline: .now() + longPressFocusLockDelay, execute: work)
    }

    private func scheduleReturnToContinuousFocusIfNeeded(for device: AVCaptureDevice) {
        guard device.isFocusModeSupported(.continuousAutoFocus) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.focusLockRequested, self.currentInput?.device == device else { return }
            do {
                try device.lockForConfiguration()
                device.focusMode = .continuousAutoFocus
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {
                print("CameraService: focus resume error: \(error)")
            }
        }
        pendingContinuousFocusWorkItem = work
        sessionQueue.asyncAfter(deadline: .now() + tapToContinuousFocusDelay, execute: work)
    }

    private func updateFocusCapabilities(for device: AVCaptureDevice) {
        let supported = device.isFocusPointOfInterestSupported &&
            (device.isFocusModeSupported(.autoFocus) || device.isFocusModeSupported(.continuousAutoFocus))
        if !supported {
            focusLockRequested = false
            cancelPendingFocusTransitions()
        }
        DispatchQueue.main.async {
            self.focusPointSupported = supported
            if !supported { self.focusLocked = false }
        }
    }

    private func capturePhotoNow() {
        guard let settings = makePhotoSettings() else {
            isPhotoCaptureInFlight = false
            DispatchQueue.main.async {
                self.isCaptureInProgress = false
                self.onPhotoCapture?(CameraCaptureResult(rawData: nil, processedData: nil))
            }
            return
        }
        settings.photoQualityPrioritization = capturePriority.photoQualityPrioritization
        if #available(iOS 18.0, *), photoOutput.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = !shutterSoundEnabled
        }
        if let connection = photoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.isVideoMirrored = currentPosition == .front
        }
        // Keep dimensions predictable and avoid forcing the heaviest RAW mode by default.
        if let device = currentInput?.device {
            if let preferredDimensions = preferredPhotoDimensions(for: device) {
                if photoOutput.maxPhotoDimensions.width != preferredDimensions.width ||
                   photoOutput.maxPhotoDimensions.height != preferredDimensions.height {
                    photoOutput.maxPhotoDimensions = preferredDimensions
                }
                settings.maxPhotoDimensions = preferredDimensions
            }
        }
        let captureID = settings.uniqueID
        let processor = PhotoCaptureProcessor { [weak self] result in
            guard let self else { return }
            self.sessionQueue.async {
                self.activeProcessors[captureID] = nil
                self.isPhotoCaptureInFlight = false
                if result.rawData == nil && result.processedData == nil {
                    print("CameraService: Photo capture failed (no data)")
                }
                DispatchQueue.main.async {
                    self.isCaptureInProgress = false
                    self.onPhotoCapture?(result)
                }
            }
        }
        activeProcessors[captureID] = processor
        photoOutput.capturePhoto(with: settings, delegate: processor)
    }

    private func preferredAppleProRAWPixelFormatForCapture() -> OSType? {
        guard #available(iOS 14.3, *) else { return nil }
        guard captureFormat == .appleProRAW, photoOutput.isAppleProRAWEnabled else { return nil }
        return photoOutput.availableRawPhotoPixelFormatTypes.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
    }

    private func preferredProcessedCodec() -> AVVideoCodecType {
        photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
    }

    private func makePhotoSettings() -> AVCapturePhotoSettings? {
        guard let rawPixelType = preferredAppleProRAWPixelFormatForCapture() else { return nil }
        let processedFormat: [String: Any] = [AVVideoCodecKey: preferredProcessedCodec()]
        return AVCapturePhotoSettings(rawPixelFormatType: rawPixelType, processedFormat: processedFormat)
    }

    nonisolated private func shouldSkipProcessedPreview(for settings: PhotoEffectSettings) -> Bool {
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

    private func bestLensAfterFormatChange(from previouslySelectedLens: CameraLens?, availableLenses: [CameraLens]) -> CameraLens? {
        guard let previouslySelectedLens else { return availableLenses.first }
        if let exactMatch = availableLenses.first(where: { $0.id == previouslySelectedLens.id }) { return exactMatch }
        if let samePhysicalLens = availableLenses.first(where: {
            $0.position == previouslySelectedLens.position &&
            $0.deviceType == previouslySelectedLens.deviceType &&
            $0.zoomFactor == 1.0
        }) { return samePhysicalLens }
        return availableLenses.first
    }

    private func updateMaxPhotoDimensions() {
        guard let device = currentInput?.device else { return }
        guard let dimensions = preferredPhotoDimensions(for: device) else { return }
        let current = photoOutput.maxPhotoDimensions
        if current.width != dimensions.width || current.height != dimensions.height {
            photoOutput.maxPhotoDimensions = dimensions
        }
    }

    private func preferredPhotoDimensions(for device: AVCaptureDevice) -> CMVideoDimensions? {
        let supported = device.activeFormat.supportedMaxPhotoDimensions
        let valid = supported.filter { $0.width > 0 && $0.height > 0 }
        guard !valid.isEmpty else { return nil }
        func pixelCount(_ dimensions: CMVideoDimensions) -> Int64 {
            Int64(dimensions.width) * Int64(dimensions.height)
        }
        let sorted = valid.sorted { lhs, rhs in
            let lhsPixels = pixelCount(lhs)
            let rhsPixels = pixelCount(rhs)
            return lhsPixels < rhsPixels
        }
        guard let targetPixels = resolutionCap.targetPixelCount else {
            return sorted.last
        }
        let candidates = sorted.filter {
            let pixels = pixelCount($0)
            return pixels >= 10_000_000 && pixels <= 15_000_000
        }
        if let nearestInRange = candidates.min(by: {
            abs(pixelCount($0) - targetPixels) < abs(pixelCount($1) - targetPixels)
        }) {
            return nearestInRange
        }

        return sorted.min(by: {
            abs(pixelCount($0) - targetPixels) < abs(pixelCount($1) - targetPixels)
        }) ?? sorted.last
    }

    private func inferredTeleEquivalentMM(for teleDevice: AVCaptureDevice, relativeTo wideDevice: AVCaptureDevice?) -> Int {
        let baseWideMM = 24.0
        guard let wideDevice else {
            return 120
        }
        let wideFOV = Double(wideDevice.activeFormat.videoFieldOfView)
        let teleFOV = Double(teleDevice.activeFormat.videoFieldOfView)
        guard wideFOV > 0, teleFOV > 0 else {
            return 120
        }
        let ratio = wideFOV / teleFOV
        let estimatedMM = baseWideMM * min(max(ratio, 1.8), 8.5)
        return roundedMillimeters(estimatedMM)
    }

    private func roundedMillimeters(_ value: Double) -> Int {
        let roundedToFive = (value / 5.0).rounded() * 5.0
        let clamped = min(max(roundedToFive, 10), 300)
        return Int(clamped)
    }

    private func setupCaptureRotationCoordinator(for device: AVCaptureDevice) {
        captureRotationObservation?.invalidate()
        captureRotationObservation = nil
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        captureRotationCoordinator = coordinator
        applyCaptureRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
        captureRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture, options: [.new]
        ) { [weak self] coord, _ in
            let angle = coord.videoRotationAngleForHorizonLevelCapture
            self?.sessionQueue.async { self?.applyCaptureRotation(angle) }
        }
    }

    private func applyCaptureRotation(_ angle: CGFloat) {
        if let photoConnection = photoOutput.connection(with: .video),
           photoConnection.isVideoRotationAngleSupported(angle) {
            photoConnection.videoRotationAngle = angle
        }
    }

    private func updateVideoOutputMirroring() {
        if let previewConnection = videoDataOutput.connection(with: .video), previewConnection.isVideoMirroringSupported {
            // Front-camera mirroring is handled in PhotoEffectsProcessor orientation mapping.
            previewConnection.isVideoMirrored = false
        }
    }

    private func updatePreviewCameraPosition(isFront: Bool) {
        previewStateQueue.async { [weak self] in
            self?.previewIsFrontCamera = isFront
        }
    }

    private func refreshCaptureConfigurationForCurrentFormat() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.updateRAWAvailability(inConfiguration: false)
            let lenses = self.reloadLenses(for: self.currentPosition)
            let preferredLens = self.bestLensAfterFormatChange(from: self.selectedLens, availableLenses: lenses)
            self.configureInput(for: preferredLens)
        }
    }

    private func schedulePersistEffectSettings(_ settings: PhotoEffectSettings) {
        persistEffectSettingsWorkItem?.cancel()
        let snapshot = settings.clamped()
        let workItem = DispatchWorkItem { [weak self] in
            self?.persistEffectSettings(snapshot)
        }
        persistEffectSettingsWorkItem = workItem
        persistenceQueue.asyncAfter(deadline: .now() + 0.22, execute: workItem)
    }

    private func schedulePrewarmExportPipeline(for settings: PhotoEffectSettings) {
        prewarmExportWorkItem?.cancel()
        let snapshot = settings.clamped()
        let workItem = DispatchWorkItem { [weak self] in
            self?.prewarmQueue.async { [weak self] in
                self?.exportEffectsProcessor.prewarmExportPipeline(for: snapshot)
            }
        }
        prewarmExportWorkItem = workItem
        persistenceQueue.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func persistEffectSettings(_ settings: PhotoEffectSettings) {
        do {
            let data = try JSONEncoder().encode(settings.clamped())
            UserDefaults.standard.set(data, forKey: PreferenceKey.effectSettingsBlob)
        } catch {
            print("CameraService: effect settings encode error: \(error)")
        }
    }

    private static func loadStoredEffectSettings() -> PhotoEffectSettings {
        guard let data = UserDefaults.standard.data(forKey: PreferenceKey.effectSettingsBlob) else {
            return .neutral
        }
        do {
            return try JSONDecoder().decode(PhotoEffectSettings.self, from: data).clamped()
        } catch {
            print("CameraService: effect settings decode error: \(error)")
            return .neutral
        }
    }

    private func persistEffectPresets(_ presets: [PhotoEffectPreset]) {
        do {
            let data = try JSONEncoder().encode(presets)
            UserDefaults.standard.set(data, forKey: PreferenceKey.effectPresetsBlob)
        } catch {
            print("CameraService: presets encode error: \(error)")
        }
    }

    private static func loadStoredEffectPresets() -> [PhotoEffectPreset] {
        guard let data = UserDefaults.standard.data(forKey: PreferenceKey.effectPresetsBlob) else {
            return []
        }
        do {
            let decoded = try JSONDecoder().decode([PhotoEffectPreset].self, from: data)
            return decoded.map { preset in
                var sanitized = preset
                sanitized.name = sanitized.name.trimmingCharacters(in: .whitespacesAndNewlines)
                sanitized.settings = sanitized.settings.clamped()
                if sanitized.name.isEmpty { sanitized.name = "Preset" }
                return sanitized
            }
        } catch {
            print("CameraService: presets decode error: \(error)")
            return []
        }
    }

    private func updateRAWAvailability(inConfiguration: Bool) {
        guard #available(iOS 14.3, *) else {
            DispatchQueue.main.async {
                self.appleProRAWSupported = false
                self.appleProRAWActive = false
            }
            return
        }
        let appleProRAWSupported = photoOutput.isAppleProRAWSupported
        let shouldEnableAppleProRAW = appleProRAWSupported && captureFormat == .appleProRAW
        if photoOutput.isAppleProRAWEnabled != shouldEnableAppleProRAW {
            if inConfiguration {
                photoOutput.isAppleProRAWEnabled = shouldEnableAppleProRAW
            } else {
                session.beginConfiguration()
                photoOutput.isAppleProRAWEnabled = shouldEnableAppleProRAW
                session.commitConfiguration()
            }
        }
        let appleProRAWActive = shouldEnableAppleProRAW && preferredAppleProRAWPixelFormatForCapture() != nil
        DispatchQueue.main.async {
            self.appleProRAWSupported = appleProRAWSupported
            self.appleProRAWActive = appleProRAWActive
        }
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard output === videoDataOutput else { return }
        guard previewRenderingEnabled else { return }

        let now = CACurrentMediaTime()
        if now - lastPreviewRenderTime < (1.0 / 12.0) { return }
        lastPreviewRenderTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let (settings, isFrontCamera) = previewStateQueue.sync { (previewEffectSettings, previewIsFrontCamera) }
        if shouldSkipProcessedPreview(for: settings) {
            if previewOverlayActive {
                previewOverlayActive = false
                DispatchQueue.main.async { [weak self] in
                    self?.livePreviewImage = nil
                }
            }
            return
        }

        autoreleasepool {
            guard let previewImage = effectsProcessor.renderPreviewImage(
                from: pixelBuffer,
                settings: settings,
                isFrontCamera: isFrontCamera
            ) else { return }
            previewOverlayActive = true

            DispatchQueue.main.async { [weak self] in
                self?.livePreviewImage = previewImage
            }
        }
    }
}
