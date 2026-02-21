@preconcurrency internal import AVFoundation
import Combine
import Foundation
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
}

nonisolated enum CameraCaptureFormat: String, CaseIterable, Identifiable, Sendable {
    case appleProRAW
    case pureRAW

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleProRAW:
            return "ProRAW"
        case .pureRAW:
            return "RAW"
        }
    }
}

nonisolated enum ExposureControlMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "A"
    case manual = "M"
    case shutterPriority = "S"

    var id: String { rawValue }
}

final class CameraService: NSObject, ObservableObject {
    private enum PreferenceKey {
        static let hapticsEnabled = "camera.hapticsEnabled"
        static let shutterSoundEnabled = "camera.shutterSoundEnabled"
        static let captureFormat = "camera.captureFormat"
        static let exposureMode = "camera.exposureMode"
        static let manualISO = "camera.manualISO"
        static let manualShutterDuration = "camera.manualShutterDuration"
    }

    @Published private(set) var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var activeVideoDevice: AVCaptureDevice?
    @Published private(set) var isSessionRunning = false
    @Published private(set) var availableLenses: [CameraLens] = []
    @Published private(set) var currentPosition: AVCaptureDevice.Position = .back
    @Published private(set) var selectedLens: CameraLens?
    @Published private(set) var deviceChangeCount = 0
    @Published private(set) var appleProRAWSupported = false
    @Published private(set) var appleProRAWActive = false
    @Published private(set) var pureRAWSupported = false
    @Published private(set) var pureRAWActive = false
    @Published private(set) var manualExposureSupported = false
    @Published private(set) var manualISORange: ClosedRange<Float> = 25.0...6400.0
    @Published private(set) var manualShutterRange: ClosedRange<Double> = (1.0 / 8_000.0)...1.0
    @Published private(set) var currentISO: Float = 100.0
    @Published private(set) var currentShutterDuration: Double = 1.0 / 120.0
    @Published private(set) var focusPointSupported = false
    @Published private(set) var focusLocked = false
    @Published var hapticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticsEnabled, forKey: PreferenceKey.hapticsEnabled)
        }
    }
    @Published var shutterSoundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(shutterSoundEnabled, forKey: PreferenceKey.shutterSoundEnabled)
        }
    }
    @Published var captureFormat: CameraCaptureFormat {
        didSet {
            UserDefaults.standard.set(captureFormat.rawValue, forKey: PreferenceKey.captureFormat)
            refreshCaptureConfigurationForCurrentFormat()
        }
    }
    @Published var exposureMode: ExposureControlMode {
        didSet {
            UserDefaults.standard.set(exposureMode.rawValue, forKey: PreferenceKey.exposureMode)
            applyExposureModeToCurrentDevice()
        }
    }
    @Published var selectedISO: Float {
        didSet {
            let clamped = min(max(selectedISO, manualISORange.lowerBound), manualISORange.upperBound)
            if abs(selectedISO - clamped) > 0.0001 {
                selectedISO = clamped
                return
            }
            UserDefaults.standard.set(Double(clamped), forKey: PreferenceKey.manualISO)
            if exposureMode == .manual {
                applyExposureModeToCurrentDevice()
            }
        }
    }
    @Published var selectedShutterDuration: Double {
        didSet {
            let clamped = min(max(selectedShutterDuration, manualShutterRange.lowerBound), manualShutterRange.upperBound)
            if abs(selectedShutterDuration - clamped) > 0.000_000_1 {
                selectedShutterDuration = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: PreferenceKey.manualShutterDuration)
            if exposureMode == .manual || exposureMode == .shutterPriority {
                applyExposureModeToCurrentDevice()
            }
        }
    }

    let session = AVCaptureSession()
    var onPhotoCapture: ((CameraCaptureResult) -> Void)?

    private let photoOutput = AVCapturePhotoOutput()
    private var currentInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var captureRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var captureRotationObservation: NSKeyValueObservation?

    private var activeProcessors: [Int64: PhotoCaptureProcessor] = [:]

    private let backDiscoverySession: AVCaptureDevice.DiscoverySession
    private let frontDiscoverySession: AVCaptureDevice.DiscoverySession

    private let sessionQueue = DispatchQueue(label: "com.movieshot.session")
    private let tapToContinuousFocusDelay: TimeInterval = 0.75
    private let longPressFocusLockDelay: TimeInterval = 0.25
    private let shutterPriorityAutoISOUpdateInterval: TimeInterval = 0.18
    private let shutterPriorityTargetToleranceEV: Float = 0.10
    private let shutterPriorityGain: Float = 0.50
    private var focusLockRequested = false
    private var pendingFocusLockWorkItem: DispatchWorkItem?
    private var pendingContinuousFocusWorkItem: DispatchWorkItem?
    private var autoISOAdjustmentTimer: DispatchSourceTimer?

    var activeCaptureBadgeText: String? {
        switch captureFormat {
        case .appleProRAW:
            return appleProRAWActive ? "ProRAW" : nil
        case .pureRAW:
            return pureRAWActive ? "RAW" : nil
        }
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
        let storedExposureModeRaw = UserDefaults.standard.string(forKey: PreferenceKey.exposureMode)
        self.exposureMode = ExposureControlMode(rawValue: storedExposureModeRaw ?? "") ?? .auto
        let storedISO = UserDefaults.standard.object(forKey: PreferenceKey.manualISO) as? Double ?? 100.0
        self.selectedISO = Float(storedISO)
        let storedShutter = UserDefaults.standard.object(forKey: PreferenceKey.manualShutterDuration) as? Double ?? (1.0 / 120.0)
        self.selectedShutterDuration = storedShutter
        let storedCaptureFormatRaw = UserDefaults.standard.string(forKey: PreferenceKey.captureFormat)
        self.captureFormat = CameraCaptureFormat(rawValue: storedCaptureFormatRaw ?? "") ?? .appleProRAW

        super.init()
        session.sessionPreset = .photo

        // Pre-populate lenses synchronously so the UI is never empty on first render.
        // DiscoverySession.devices is safe to read on any thread.
        availableLenses = buildLenses(for: .back)
    }

    func capturePhoto() {
        guard isSessionRunning else { return }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.prepareExposureForCapture {
                self.capturePhotoNow()
            }
        }
    }

    var isShutterSoundToggleAvailable: Bool {
        if #available(iOS 18.0, *) {
            return photoOutput.isShutterSoundSuppressionSupported
        }
        return false
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

            // Add output in its own configuration block
            self.session.beginConfiguration()
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.maxPhotoQualityPrioritization = .balanced
            }
            self.updateRAWAvailability(inConfiguration: true)
            self.session.commitConfiguration()

            self.isConfigured = true

            // Configure initial input separately (has its own begin/commit)
            let initialPosition: AVCaptureDevice.Position = .back
            let lenses = self.reloadLenses(for: initialPosition)
            self.configureInput(for: lenses.first)

            DispatchQueue.main.async {
                self.currentPosition = initialPosition
            }
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = self.session.isRunning
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.stopAutoISOAdjustment()
            self.session.stopRunning()
            DispatchQueue.main.async {
                self.isSessionRunning = self.session.isRunning
            }
        }
    }

    func togglePosition() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let newPosition: AVCaptureDevice.Position = self.currentPosition == .back ? .front : .back
            let lenses = self.reloadLenses(for: newPosition)
            self.configureInput(for: lenses.first)
            DispatchQueue.main.async {
                self.currentPosition = newPosition
            }
        }
    }

    func selectLens(_ lens: CameraLens) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard lens.position == self.currentPosition else { return }
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
            DispatchQueue.main.async {
                self.focusLocked = lockFocus
            }

            let point = CGPoint(
                x: min(max(devicePoint.x, 0.0), 1.0),
                y: min(max(devicePoint.y, 0.0), 1.0)
            )

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                }

                // Start with one-shot focus to honor the tapped position.
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }

                // Tap returns to tracking mode; long-press keeps a lock.
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

    /// Builds the lens list without any side-effects. Safe to call from any thread.
    private func buildLenses(for position: AVCaptureDevice.Position) -> [CameraLens] {
        let discovery = position == .back ? backDiscoverySession : frontDiscoverySession

        let uniqueDevices = Dictionary(grouping: discovery.devices, by: \.deviceType)
            .compactMap { $0.value.first }

        let lenses: [CameraLens] = uniqueDevices.map { device in
            let (name, order) = lensInfo(for: device.deviceType, position: position)
            return CameraLens(
                id: "\(device.position.rawValue)-\(device.deviceType.rawValue)",
                name: name,
                deviceType: device.deviceType,
                position: device.position,
                zoomFactor: 1.0,
                sortOrder: order
            )
        }

        return lenses.sorted { $0.sortOrder < $1.sortOrder }
    }

    private func reloadLenses(for position: AVCaptureDevice.Position) -> [CameraLens] {
        let sorted = buildLenses(for: position)
        DispatchQueue.main.async {
            self.availableLenses = sorted
        }
        return sorted
    }

    private func configureInput(for lens: CameraLens?) {
        guard let lens else { return }

        guard let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: lens.position)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: lens.position)
        else { return }

        cancelPendingFocusTransitions()
        focusLockRequested = false
        DispatchQueue.main.async {
            self.focusLocked = false
        }

        defer {
            DispatchQueue.main.async {
                self.selectedLens = lens
            }
        }

        // Same physical device — just update zoom, no session reconfiguration needed
        if let currentInput, currentInput.device == device {
            applyZoom(lens.zoomFactor, to: device)
            updateFocusCapabilities(for: device)
            updateManualExposureCapabilities(for: device)
            applyExposureMode(to: device)
            updateMaxPhotoDimensions()
            updateRAWAvailability(inConfiguration: false)
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
            updateManualExposureCapabilities(for: device)
            applyExposureMode(to: device)
            updateRAWAvailability(inConfiguration: true)
            setupCaptureRotationCoordinator(for: device)

            DispatchQueue.main.async {
                self.activeVideoDevice = device
                self.deviceChangeCount += 1
            }
        } catch {
            print("CameraService: input error: \(error)")
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
            DispatchQueue.main.async {
                self.focusLocked = false
            }
            scheduleReturnToContinuousFocusIfNeeded(for: device)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.focusLockRequested else { return }
            guard self.currentInput?.device == device else { return }

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
            guard let self else { return }
            guard !self.focusLockRequested else { return }
            guard self.currentInput?.device == device else { return }

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
        let supported =
            device.isFocusPointOfInterestSupported &&
            (device.isFocusModeSupported(.autoFocus) || device.isFocusModeSupported(.continuousAutoFocus))

        if !supported {
            focusLockRequested = false
            cancelPendingFocusTransitions()
        }

        DispatchQueue.main.async {
            self.focusPointSupported = supported
            if !supported {
                self.focusLocked = false
            }
        }
    }

    private func updateManualExposureCapabilities(for device: AVCaptureDevice) {
        let supportsManualExposure = device.isExposureModeSupported(.custom)
        let minISO = Float(device.activeFormat.minISO)
        let maxISO = Float(device.activeFormat.maxISO)
        let minDuration = max(1.0 / 24_000.0, CMTimeGetSeconds(device.activeFormat.minExposureDuration))
        let maxDuration = max(minDuration, CMTimeGetSeconds(device.activeFormat.maxExposureDuration))
        let currentISO = Float(device.iso)
        let currentShutter = max(minDuration, CMTimeGetSeconds(device.exposureDuration))

        DispatchQueue.main.async {
            self.manualExposureSupported = supportsManualExposure
            self.manualISORange = minISO...maxISO
            self.manualShutterRange = minDuration...maxDuration
            self.currentISO = currentISO
            self.currentShutterDuration = currentShutter

            let clampedISO = min(max(self.selectedISO, minISO), maxISO)
            if abs(self.selectedISO - clampedISO) > 0.0001 {
                self.selectedISO = clampedISO
            }

            let clampedShutter = min(max(self.selectedShutterDuration, minDuration), maxDuration)
            if abs(self.selectedShutterDuration - clampedShutter) > 0.000_000_1 {
                self.selectedShutterDuration = clampedShutter
            }

            if !supportsManualExposure, self.exposureMode != .auto {
                self.exposureMode = .auto
            }
        }
    }

    private func applyExposureModeToCurrentDevice() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentInput?.device else { return }
            self.applyExposureMode(to: device)
        }
    }

    private func applyExposureMode(to device: AVCaptureDevice) {
        switch exposureMode {
        case .auto:
            stopAutoISOAdjustment()
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                DispatchQueue.main.async {
                    self.currentISO = Float(device.iso)
                    self.currentShutterDuration = max(1.0 / 24_000.0, CMTimeGetSeconds(device.exposureDuration))
                }
            } catch {
                print("CameraService: exposure mode error: \(error)")
            }
        case .manual:
            stopAutoISOAdjustment()
            applyManualExposure(to: device)
        case .shutterPriority:
            startAutoISOAdjustment(for: device)
            applyShutterPriorityExposure(to: device)
        }
    }

    private func applyManualExposure(to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            guard device.isExposureModeSupported(.custom) else { return }
            let iso = clampedISO(selectedISO, for: device)
            let shutterDuration = clampedShutterDuration(selectedShutterDuration, for: device)
            let duration = CMTimeMakeWithSeconds(shutterDuration, preferredTimescale: 1_000_000_000)
            device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
            DispatchQueue.main.async {
                self.currentISO = iso
                self.currentShutterDuration = shutterDuration
            }
        } catch {
            print("CameraService: manual exposure error: \(error)")
        }
    }

    private func applyShutterPriorityExposure(to device: AVCaptureDevice) {
        guard device.isExposureModeSupported(.custom) else { return }

        let shutterDuration = clampedShutterDuration(selectedShutterDuration, for: device)
        let currentISO = clampedISO(Float(device.iso), for: device)
        let currentShutter = max(1.0 / 24_000.0, CMTimeGetSeconds(device.exposureDuration))
        let offset = Float(device.exposureTargetOffset)

        var targetISO = currentISO
        if abs(offset) > shutterPriorityTargetToleranceEV {
            // Keep shutter fixed and nudge ISO toward the metered target.
            let ratio = powf(2.0, offset * shutterPriorityGain)
            targetISO = clampedISO(currentISO * ratio, for: device)
        }

        let shouldApply =
            device.exposureMode != .custom ||
            abs(currentShutter - shutterDuration) > 0.000_001 ||
            abs(currentISO - targetISO) > 0.5

        if shouldApply {
            do {
                try device.lockForConfiguration()
                let duration = CMTimeMakeWithSeconds(shutterDuration, preferredTimescale: 1_000_000_000)
                device.setExposureModeCustom(duration: duration, iso: targetISO, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                print("CameraService: shutter priority exposure error: \(error)")
            }
        }

        DispatchQueue.main.async {
            self.currentISO = targetISO
            self.currentShutterDuration = shutterDuration
        }
    }

    private func startAutoISOAdjustment(for device: AVCaptureDevice) {
        stopAutoISOAdjustment()

        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: shutterPriorityAutoISOUpdateInterval, leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.exposureMode == .shutterPriority else {
                self.stopAutoISOAdjustment()
                return
            }
            guard self.currentInput?.device == device else {
                self.stopAutoISOAdjustment()
                return
            }
            self.applyShutterPriorityExposure(to: device)
        }
        autoISOAdjustmentTimer = timer
        timer.resume()
    }

    private func stopAutoISOAdjustment() {
        autoISOAdjustmentTimer?.setEventHandler {}
        autoISOAdjustmentTimer?.cancel()
        autoISOAdjustmentTimer = nil
    }

    private func clampedISO(_ value: Float, for device: AVCaptureDevice) -> Float {
        let minISO = Float(device.activeFormat.minISO)
        let maxISO = Float(device.activeFormat.maxISO)
        return min(max(value, minISO), maxISO)
    }

    private func clampedShutterDuration(_ value: Double, for device: AVCaptureDevice) -> Double {
        let minDuration = max(1.0 / 24_000.0, CMTimeGetSeconds(device.activeFormat.minExposureDuration))
        let maxDuration = max(minDuration, CMTimeGetSeconds(device.activeFormat.maxExposureDuration))
        return min(max(value, minDuration), maxDuration)
    }

    /// 12MP cap: 4032×3024
    private static let captureMaxPixelCount: Int32 = 4032 * 3024

    private func updateMaxPhotoDimensions() {
        guard let device = currentInput?.device else { return }

        let supported = device.activeFormat.supportedMaxPhotoDimensions
        guard !supported.isEmpty else { return }

        // Keep all capture formats at 12MP max for stability.
        let capped = supported
            .filter { $0.width * $0.height <= Self.captureMaxPixelCount }
            .max(by: { $0.width * $0.height < $1.width * $1.height })
        let dimensions = capped ?? supported.min(by: { $0.width * $0.height < $1.width * $1.height })
        guard let dimensions else { return }

        // Only update if the value actually changed — avoids a crash when the
        // current value is already valid for the new format.
        let current = photoOutput.maxPhotoDimensions
        if current.width != dimensions.width || current.height != dimensions.height {
            photoOutput.maxPhotoDimensions = dimensions
        }
    }

    private func lensInfo(for type: AVCaptureDevice.DeviceType, position: AVCaptureDevice.Position) -> (name: String, sortOrder: Int) {
        if position == .front { return ("Front", 0) }
        switch type {
        case .builtInUltraWideCamera: return ("14mm", 5)
        case .builtInWideAngleCamera: return ("24mm", 0)  // sortOrder 0 = default first lens
        case .builtInTelephotoCamera: return ("Tele", 20)
        default: return ("Camera", 50)
        }
    }

    private func setupCaptureRotationCoordinator(for device: AVCaptureDevice) {
        captureRotationObservation?.invalidate()
        captureRotationObservation = nil

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        captureRotationCoordinator = coordinator

        applyCaptureRotation(coordinator.videoRotationAngleForHorizonLevelCapture)

        captureRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.new]
        ) { [weak self] coord, _ in
            let angle = coord.videoRotationAngleForHorizonLevelCapture
            self?.sessionQueue.async {
                self?.applyCaptureRotation(angle)
            }
        }
    }

    private func applyCaptureRotation(_ angle: CGFloat) {
        guard let connection = photoOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
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

    private func prepareExposureForCapture(_ completion: @escaping () -> Void) {
        guard let device = currentInput?.device else {
            completion()
            return
        }

        guard device.isExposureModeSupported(.custom) else {
            completion()
            return
        }

        guard exposureMode == .manual || exposureMode == .shutterPriority else {
            completion()
            return
        }

        let shutterDuration = clampedShutterDuration(selectedShutterDuration, for: device)
        let iso: Float = {
            switch exposureMode {
            case .manual:
                return clampedISO(selectedISO, for: device)
            case .shutterPriority:
                return clampedISO(Float(device.iso), for: device)
            case .auto:
                return clampedISO(Float(device.iso), for: device)
            }
        }()
        let duration = CMTimeMakeWithSeconds(shutterDuration, preferredTimescale: 1_000_000_000)

        var finished = false
        let finishIfNeeded: () -> Void = {
            guard !finished else { return }
            finished = true
            completion()
        }

        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: duration, iso: iso) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.currentISO = iso
                    self?.currentShutterDuration = shutterDuration
                }
                self?.sessionQueue.async {
                    finishIfNeeded()
                }
            }
            device.unlockForConfiguration()

            // Safety fallback: avoid a stuck capture if exposure callback is delayed.
            sessionQueue.asyncAfter(deadline: .now() + 0.4) {
                finishIfNeeded()
            }
        } catch {
            print("CameraService: prepare exposure error: \(error)")
            completion()
        }
    }

    private func capturePhotoNow() {
        guard let settings = makePhotoSettings() else {
            DispatchQueue.main.async {
                self.onPhotoCapture?(CameraCaptureResult(rawData: nil))
            }
            return
        }

        if let connection = photoOutput.connection(with: .video),
           connection.isVideoMirroringSupported {
            connection.isVideoMirrored = currentPosition == .front
        }

        let outputDimensions = photoOutput.maxPhotoDimensions
        if outputDimensions.width > 0 && outputDimensions.height > 0 {
            settings.maxPhotoDimensions = outputDimensions
        }

        let captureID = settings.uniqueID
        let processor = PhotoCaptureProcessor { [weak self] result in
            guard let self else { return }
            self.sessionQueue.async {
                self.activeProcessors[captureID] = nil
                if result.rawData == nil {
                    print("CameraService: Photo capture failed (no data)")
                }
                DispatchQueue.main.async {
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
        return photoOutput.availableRawPhotoPixelFormatTypes.first(where: { type in
            AVCapturePhotoOutput.isAppleProRAWPixelFormat(type)
        })
    }

    private func preferredPureRAWPixelFormatForCapture() -> OSType? {
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        guard !rawTypes.isEmpty else { return nil }

        if #available(iOS 14.3, *) {
            return rawTypes.first(where: { !AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) })
        }

        return rawTypes.first
    }

    private func makePhotoSettings() -> AVCapturePhotoSettings? {
        let bracketedSettings: [AVCaptureBracketedStillImageSettings]?
        if let device = currentInput?.device {
            bracketedSettings = manualBracketedExposureSettings(for: device)
        } else {
            bracketedSettings = nil
        }

        switch captureFormat {
        case .appleProRAW:
            guard let rawPixelType = preferredAppleProRAWPixelFormatForCapture() else { return nil }
            if let bracketedSettings {
                return AVCapturePhotoBracketSettings(
                    rawPixelFormatType: rawPixelType,
                    processedFormat: nil,
                    bracketedSettings: bracketedSettings
                )
            }
            return AVCapturePhotoSettings(rawPixelFormatType: rawPixelType, processedFormat: nil)
        case .pureRAW:
            guard let rawPixelType = preferredPureRAWPixelFormatForCapture() else { return nil }
            if let bracketedSettings {
                return AVCapturePhotoBracketSettings(
                    rawPixelFormatType: rawPixelType,
                    processedFormat: nil,
                    bracketedSettings: bracketedSettings
                )
            }
            return AVCapturePhotoSettings(rawPixelFormatType: rawPixelType, processedFormat: nil)
        }
    }

    private func manualBracketedExposureSettings(for device: AVCaptureDevice) -> [AVCaptureBracketedStillImageSettings]? {
        guard device.isExposureModeSupported(.custom) else { return nil }
        guard exposureMode == .manual || exposureMode == .shutterPriority else { return nil }

        let iso: Float = {
            switch exposureMode {
            case .manual:
                return clampedISO(selectedISO, for: device)
            case .shutterPriority:
                return clampedISO(Float(device.iso), for: device)
            case .auto:
                return clampedISO(Float(device.iso), for: device)
            }
        }()
        let shutterDuration = clampedShutterDuration(selectedShutterDuration, for: device)
        let duration = CMTimeMakeWithSeconds(shutterDuration, preferredTimescale: 1_000_000_000)
        let manual = AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
            exposureDuration: duration,
            iso: iso
        )
        return [manual]
    }

    private func bestLensAfterFormatChange(from previouslySelectedLens: CameraLens?, availableLenses: [CameraLens]) -> CameraLens? {
        guard let previouslySelectedLens else { return availableLenses.first }

        if let exactMatch = availableLenses.first(where: { $0.id == previouslySelectedLens.id }) {
            return exactMatch
        }

        if let samePhysicalLens = availableLenses.first(where: { lens in
            lens.position == previouslySelectedLens.position &&
            lens.deviceType == previouslySelectedLens.deviceType &&
            lens.zoomFactor == 1.0
        }) {
            return samePhysicalLens
        }

        return availableLenses.first
    }

    private func updateRAWAvailability(inConfiguration: Bool) {
        guard #available(iOS 14.3, *) else {
            DispatchQueue.main.async {
                self.appleProRAWSupported = false
                self.appleProRAWActive = false
                self.pureRAWSupported = false
                self.pureRAWActive = false
            }
            return
        }

        let appleProRAWSupported = photoOutput.isAppleProRAWSupported
        let pureRAWSupported = preferredPureRAWPixelFormatForCapture() != nil

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
        let pureRAWActive = captureFormat == .pureRAW && preferredPureRAWPixelFormatForCapture() != nil
        DispatchQueue.main.async {
            self.appleProRAWSupported = appleProRAWSupported
            self.appleProRAWActive = appleProRAWActive
            self.pureRAWSupported = pureRAWSupported
            self.pureRAWActive = pureRAWActive
        }
    }
}
