internal import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let activeDevice: AVCaptureDevice?
    var onTapToFocus: ((CGPoint, CGPoint) -> Void)?
    var onLongPressToFocusLock: ((CGPoint, CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.videoPreviewLayer.session = session
        view.updateActiveDevice(activeDevice)
        view.onTapToFocus = onTapToFocus
        view.onLongPressToFocusLock = onLongPressToFocusLock
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
        uiView.updateActiveDevice(activeDevice)
        uiView.onTapToFocus = onTapToFocus
        uiView.onLongPressToFocusLock = onLongPressToFocusLock
    }
}

final class PreviewView: UIView {
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var sessionObservation: NSObjectProtocol?
    private var activeDevice: AVCaptureDevice?
    var onTapToFocus: ((CGPoint, CGPoint) -> Void)?
    var onLongPressToFocusLock: ((CGPoint, CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupTapGesture()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTapGesture()
    }

    func updateActiveDevice(_ device: AVCaptureDevice?) {
        guard device != activeDevice else { return }
        activeDevice = device
        setupRotationIfReady()
    }

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setupRotationIfReady()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            setupRotationIfReady()
            // Also listen for session start so we can configure orientation
            // when the connection becomes available after session starts running.
            if sessionObservation == nil {
                sessionObservation = NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.didStartRunningNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.setupRotationIfReady()
                }
            }
        } else {
            teardownRotation()
            if let obs = sessionObservation {
                NotificationCenter.default.removeObserver(obs)
                sessionObservation = nil
            }
        }
    }

    func setupRotationIfReady() {
        guard let device = activeDevice else { return }
        guard videoPreviewLayer.connection != nil else { return }
        
        // If we already have a coordinator for this device, do nothing
        if let coordinator = rotationCoordinator, coordinator.device == device {
            return
        }

        teardownRotation()

        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: device,
            previewLayer: videoPreviewLayer
        )
        rotationCoordinator = coordinator

        applyRotation(coordinator.videoRotationAngleForHorizonLevelPreview)

        previewRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.new]
        ) { [weak self] coord, _ in
            DispatchQueue.main.async {
                self?.applyRotation(coord.videoRotationAngleForHorizonLevelPreview)
            }
        }
    }

    private func applyRotation(_ angle: CGFloat) {
        guard let connection = videoPreviewLayer.connection else { return }
        guard connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func teardownRotation() {
        previewRotationObservation?.invalidate()
        previewRotationObservation = nil
        rotationCoordinator = nil
    }

    private func setupTapGesture() {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPressToFocusLock(_:)))
        longPress.minimumPressDuration = 0.4
        addGestureRecognizer(longPress)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus(_:)))
        tap.require(toFail: longPress)
        addGestureRecognizer(tap)
    }

    @objc private func handleTapToFocus(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let layerPoint = recognizer.location(in: self)
        let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        onTapToFocus?(layerPoint, devicePoint)
    }

    @objc private func handleLongPressToFocusLock(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let layerPoint = recognizer.location(in: self)
        let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        onLongPressToFocusLock?(layerPoint, devicePoint)
    }

    deinit {
        teardownRotation()
        if let obs = sessionObservation {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}
