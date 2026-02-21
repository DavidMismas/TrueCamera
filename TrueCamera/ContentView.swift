import Photos
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var cameraService = CameraService()
    @Environment(\.scenePhase) private var scenePhase

    @State private var isSaving = false
    @State private var statusMessage: String?
    @State private var lastCaptureSucceeded = false
    @State private var controlRotationAngle: Angle = .zero
    @State private var showSettingsSheet = false
    private let previewVerticalOffset: CGFloat = -44

    var body: some View {
        GeometryReader { _ in
            ZStack {
                Color(red: 0.055, green: 0.055, blue: 0.06).ignoresSafeArea()

                previewView

                controlsOverlay
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
        }
        .onAppear {
            cameraService.onPhotoCapture = handleCaptureResult
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
        .onChange(of: cameraService.pureRAWSupported) { _, _ in
            normalizeCaptureFormatSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateControlRotation(for: UIDevice.current.orientation)
        }
        .sheet(isPresented: $showSettingsSheet) {
            settingsSheet
        }
    }

    @ViewBuilder
    private var previewView: some View {
        switch cameraService.authorizationStatus {
        case .authorized:
            CameraPreviewView(
                session: cameraService.session,
                activeDevice: cameraService.activeVideoDevice
            )
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 16)
            .offset(y: previewVerticalOffset)
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

    @ViewBuilder
    private var controlsOverlay: some View {
        if cameraService.authorizationStatus == .authorized {
            VStack {
                HStack {
                    settingsButton
                    Spacer()
                    cameraSwitchButton
                }
                .padding(.top, 22)

                Spacer()

                controls
                    .padding(.bottom, 28)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var controls: some View {
        Group {
            if isSaving {
                ProgressView("Saving...")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.6), in: Capsule())
            } else {
                VStack(spacing: 10) {
                    exposureStrip
                    controlButtons
                }
            }
        }
    }

    private var exposureStrip: some View {
        VStack(spacing: 8) {
            exposureModeSelector

            if cameraService.exposureMode == .manual || cameraService.exposureMode == .shutterPriority {
                shutterSliderRow
            } else {
                readoutRow
            }

            if cameraService.exposureMode == .manual {
                isoSliderRow
            } else if cameraService.exposureMode == .shutterPriority {
                autoISORow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.20), lineWidth: 1)
        )
        .rotationEffect(controlRotationAngle)
        .animation(.easeInOut(duration: 0.2), value: controlRotationAngle)
    }

    private var exposureModeSelector: some View {
        HStack(spacing: 8) {
            ForEach(ExposureControlMode.allCases) { mode in
                let isSelected = cameraService.exposureMode == mode
                let isEnabled = mode == .auto || cameraService.manualExposureSupported

                Button {
                    guard isEnabled else { return }
                    cameraService.exposureMode = mode
                } label: {
                    Text(mode.rawValue)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            isSelected ? .orange.opacity(0.45) : .white.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(.white.opacity(isSelected ? 0.42 : 0.20), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .opacity(isEnabled ? 1.0 : 0.4)
            }
        }
    }

    private var readoutRow: some View {
        HStack(spacing: 12) {
            readoutChip(title: "S", value: Self.shutterDisplayString(for: cameraService.currentShutterDuration))
            readoutChip(title: "ISO", value: Self.isoDisplayString(for: cameraService.currentISO))
        }
    }

    private var shutterSliderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("S")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text(shutterReadoutText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Slider(value: shutterSliderProgressBinding, in: 0...1)
                .tint(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.20), lineWidth: 1)
        )
    }

    private var isoSliderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("ISO")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text(Self.isoDisplayString(for: cameraService.selectedISO))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Slider(value: isoSliderBinding, in: cameraService.manualISORange)
                .tint(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.20), lineWidth: 1)
        )
    }

    private var autoISORow: some View {
        HStack {
            Text("ISO")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.72))
            Spacer()
            Text("AUTO  \(isoReadoutText)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.20), lineWidth: 1)
        )
    }

    private func readoutChip(title: String, value: String) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.70))
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.20), lineWidth: 1)
        )
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

    private var settingsButton: some View {
        Button {
            showSettingsSheet = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(.black.opacity(0.45), in: Circle())
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.25), lineWidth: 1)
                )
        }
        .rotationEffect(controlRotationAngle)
        .animation(.easeInOut(duration: 0.2), value: controlRotationAngle)
    }

    private var shutterButton: some View {
        Button {
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
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.25), lineWidth: 1)
                )
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
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.25), lineWidth: 1)
                )
        }
        .rotationEffect(controlRotationAngle)
        .animation(.easeInOut(duration: 0.2), value: controlRotationAngle)
    }

    private var lensSelector: some View {
        Menu {
            Picker("Lens", selection: selectedLensID) {
                ForEach(cameraService.availableLenses) { lens in
                    Text(lens.name).tag(lens.id)
                }
            }
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
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            )
        }
        // Keep this fixed so the lens control doesn't visually "jump" near shutter.
        .frame(width: 106, alignment: .leading)
        .rotationEffect(controlRotationAngle)
        .animation(.easeInOut(duration: 0.2), value: controlRotationAngle)
    }

    private var currentLensName: String {
        cameraService.selectedLens?.name ?? cameraService.availableLenses.first?.name ?? "Lens"
    }

    private var selectedLensID: Binding<String> {
        Binding(
            get: { cameraService.selectedLens?.id ?? cameraService.availableLenses.first?.id ?? "" },
            set: { newValue in
                guard let lens = cameraService.availableLenses.first(where: { $0.id == newValue }) else { return }
                cameraService.selectLens(lens)
            }
        )
    }

    private var shutterReadoutText: String {
        let shutter: Double
        switch cameraService.exposureMode {
        case .auto:
            shutter = cameraService.currentShutterDuration
        case .manual, .shutterPriority:
            shutter = cameraService.selectedShutterDuration
        }
        return Self.shutterDisplayString(for: shutter)
    }

    private var isoReadoutText: String {
        let iso: Float
        switch cameraService.exposureMode {
        case .manual:
            iso = cameraService.selectedISO
        case .auto, .shutterPriority:
            iso = cameraService.currentISO
        }
        return Self.isoDisplayString(for: iso)
    }

    private var shutterSliderProgressBinding: Binding<Double> {
        Binding(
            get: {
                progressForShutter(
                    cameraService.selectedShutterDuration,
                    in: cameraService.manualShutterRange
                )
            },
            set: { progress in
                cameraService.selectedShutterDuration = shutterForProgress(
                    progress,
                    in: cameraService.manualShutterRange
                )
            }
        )
    }

    private var isoSliderBinding: Binding<Float> {
        Binding(
            get: { cameraService.selectedISO },
            set: { cameraService.selectedISO = $0 }
        )
    }

    private func progressForShutter(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let low = log(range.lowerBound)
        let high = log(range.upperBound)
        guard high > low else { return 0 }
        return (log(clamped) - low) / (high - low)
    }

    private func shutterForProgress(_ progress: Double, in range: ClosedRange<Double>) -> Double {
        let clampedProgress = min(max(progress, 0.0), 1.0)
        let low = log(range.lowerBound)
        let high = log(range.upperBound)
        guard high > low else { return range.lowerBound }
        return exp(low + (high - low) * clampedProgress)
    }

    private static func shutterDisplayString(for seconds: Double) -> String {
        guard seconds > 0 else { return "--" }

        if seconds >= 1.0 {
            if abs(seconds.rounded() - seconds) < 0.05 {
                return String(format: "%.0fs", seconds.rounded())
            }
            return String(format: "%.1fs", seconds)
        }

        let denominator = Int((1.0 / seconds).rounded())
        return "1/\(max(1, denominator))"
    }

    private static func isoDisplayString(for iso: Float) -> String {
        "ISO \(Int(iso.rounded()))"
    }

    private func handleCaptureResult(_ result: CameraCaptureResult) {
        guard result.rawData != nil else {
            if let unavailableMessage = unavailableCaptureFormatMessage {
                statusMessage = unavailableMessage
            } else {
                statusMessage = "Capture failed."
            }
            lastCaptureSucceeded = false
            return
        }

        Task { @MainActor in
            isSaving = true
            defer { isSaving = false }
            let (saveOk, saveErrorMessage) = await saveToPhotoLibrary(result)
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
        case .pureRAW:
            return cameraService.pureRAWActive ? nil : "RAW ni na voljo za izbrano kamero/lečo."
        }
    }

    private func saveToPhotoLibrary(_ result: CameraCaptureResult) async -> (Bool, String?) {
        let authStatus = await ensurePhotoWriteAuthorization()
        guard authStatus == .authorized || authStatus == .limited else {
            return (false, "No Photos write permission")
        }

        guard let rawData = result.rawData else {
            return (false, "No DNG data to save")
        }

        guard let tempPhotoFileURL = await writeRawTempFile(rawData) else {
            return (false, "Couldn't prepare temporary DNG file")
        }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResource(with: .photo, fileURL: tempPhotoFileURL, options: options)
            }, completionHandler: { success, error in
                if let error {
                    print("Photos save error: \(error)")
                }
                if !success {
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
        case .authorized:
            return .authorized
        case .notDetermined:
            let requested = await requestPhotoAuthorization(for: .addOnly)
            if requested == .authorized {
                return requested
            }
        default:
            break
        }

        let readWriteCurrent = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch readWriteCurrent {
        case .authorized, .limited:
            return readWriteCurrent
        case .notDetermined:
            return await requestPhotoAuthorization(for: .readWrite)
        default:
            return readWriteCurrent
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

        Task {
            _ = await ensurePhotoWriteAuthorization()
        }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Capture Format") {
                    Picker("Format", selection: $cameraService.captureFormat) {
                        ForEach(CameraCaptureFormat.allCases) { format in
                            Text(format.label)
                                .tag(format)
                                .disabled(!isCaptureFormatSupported(format))
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Shranjevanje je vedno čisti .dng brez processing pipeline.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !cameraService.appleProRAWSupported {
                        Text("ProRAW ni podprt na trenutni napravi/leči.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !cameraService.pureRAWSupported {
                        Text("RAW ni podprt na trenutni napravi/leči.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showSettingsSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func normalizeCaptureFormatSelection() {
        if isCaptureFormatSupported(cameraService.captureFormat) {
            return
        }

        if cameraService.appleProRAWSupported {
            cameraService.captureFormat = .appleProRAW
            return
        }

        if cameraService.pureRAWSupported {
            cameraService.captureFormat = .pureRAW
        }
    }

    private func isCaptureFormatSupported(_ format: CameraCaptureFormat) -> Bool {
        switch format {
        case .appleProRAW:
            return cameraService.appleProRAWSupported
        case .pureRAW:
            return cameraService.pureRAWSupported
        }
    }

    private func setInitialControlRotation() {
        let deviceOrientation = UIDevice.current.orientation
        switch deviceOrientation {
        case .landscapeLeft:
            controlRotationAngle = .degrees(90)
        case .landscapeRight:
            controlRotationAngle = .degrees(-90)
        case .portrait:
            controlRotationAngle = .degrees(0)
        default:
            guard let interfaceOrientation = currentInterfaceOrientation() else { return }
            switch interfaceOrientation {
            case .landscapeLeft:
                controlRotationAngle = .degrees(90)
            case .landscapeRight:
                controlRotationAngle = .degrees(-90)
            default:
                controlRotationAngle = .degrees(0)
            }
        }
    }

    private func updateControlRotation(for orientation: UIDeviceOrientation) {
        withAnimation(.easeInOut(duration: 0.22)) {
            switch orientation {
            case .landscapeLeft:
                controlRotationAngle = .degrees(90)
            case .landscapeRight:
                controlRotationAngle = .degrees(-90)
            case .portrait:
                controlRotationAngle = .degrees(0)
            default:
                break
            }
        }
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
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
