internal import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let activeDevice: AVCaptureDevice?
    let focusLocked: Bool
    var onTapToFocus: ((CGPoint, CGPoint) -> Void)?
    var onLongPressToFocusLock: ((CGPoint, CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.videoGravity = .resizeAspect
        view.videoPreviewLayer.session = session
        view.updateActiveDevice(activeDevice)
        view.setFocusLocked(focusLocked, animated: false)
        view.onTapToFocus = onTapToFocus
        view.onLongPressToFocusLock = onLongPressToFocusLock
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
        uiView.updateActiveDevice(activeDevice)
        uiView.setFocusLocked(focusLocked, animated: true)
        uiView.onTapToFocus = onTapToFocus
        uiView.onLongPressToFocusLock = onLongPressToFocusLock
    }
}

final class PreviewView: UIView {
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var sessionObservation: NSObjectProtocol?
    private var activeDevice: AVCaptureDevice?
    private var focusIndicatorDismissWorkItem: DispatchWorkItem?
    private var isFocusLocked = false
    private let focusIndicatorSize: CGFloat = 76
    private let focusLockLabelSize = CGSize(width: 58, height: 16)
    private let focusLockLabelVerticalGap: CGFloat = 8
    private let focusIndicatorView: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 76, height: 76))
        view.isUserInteractionEnabled = false
        view.alpha = 0
        view.transform = CGAffineTransform(scaleX: 1.18, y: 1.18)

        let ring = CAShapeLayer()
        ring.path = UIBezierPath(ovalIn: CGRect(x: 4, y: 4, width: 68, height: 68)).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor(red: 0.07, green: 0.74, blue: 0.70, alpha: 0.96).cgColor
        ring.lineWidth = 2.2

        let centerDot = CAShapeLayer()
        centerDot.path = UIBezierPath(ovalIn: CGRect(x: 35, y: 35, width: 6, height: 6)).cgPath
        centerDot.fillColor = UIColor(red: 0.95, green: 0.54, blue: 0.75, alpha: 0.95).cgColor

        view.layer.addSublayer(ring)
        view.layer.addSublayer(centerDot)
        return view
    }()
    private let focusLockLabel: UILabel = {
        let label = UILabel(frame: .zero)
        label.text = "AF LOCK"
        label.textAlignment = .center
        label.font = .monospacedSystemFont(ofSize: 8.5, weight: .bold)
        label.textColor = UIColor.white
        label.backgroundColor = UIColor(red: 0.95, green: 0.54, blue: 0.75, alpha: 0.90)
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        label.alpha = 0
        return label
    }()
    var onTapToFocus: ((CGPoint, CGPoint) -> Void)?
    var onLongPressToFocusLock: ((CGPoint, CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupFocusIndicator()
        setupTapGesture()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupFocusIndicator()
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

    private func setupFocusIndicator() {
        focusLockLabel.bounds = CGRect(origin: .zero, size: focusLockLabelSize)
        addSubview(focusIndicatorView)
        addSubview(focusLockLabel)
    }

    private func positionFocusLockLabel(near point: CGPoint) {
        let halfLabelWidth = focusLockLabelSize.width / 2
        let halfLabelHeight = focusLockLabelSize.height / 2
        let topPadding: CGFloat = 6
        let bottomPadding: CGFloat = 6

        let aboveY = point.y - (focusIndicatorSize / 2) - focusLockLabelVerticalGap - halfLabelHeight
        let belowY = point.y + (focusIndicatorSize / 2) + focusLockLabelVerticalGap + halfLabelHeight

        let canPlaceAbove = aboveY - halfLabelHeight >= topPadding
        let preferredY = canPlaceAbove ? aboveY : belowY
        let clampedY = min(max(preferredY, topPadding + halfLabelHeight), bounds.height - bottomPadding - halfLabelHeight)
        let clampedX = min(max(point.x, topPadding + halfLabelWidth), bounds.width - topPadding - halfLabelWidth)

        focusLockLabel.center = CGPoint(x: clampedX, y: clampedY)
    }

    func setFocusLocked(_ locked: Bool, animated: Bool) {
        guard locked != isFocusLocked else { return }
        isFocusLocked = locked
        if locked {
            focusIndicatorDismissWorkItem?.cancel()
            if focusIndicatorView.alpha < 0.01 {
                focusIndicatorView.alpha = 1
                focusIndicatorView.transform = .identity
            }
            positionFocusLockLabel(near: focusIndicatorView.center)
        } else if focusIndicatorView.alpha > 0.01 {
            scheduleFocusIndicatorDismiss(after: 0.28)
        }
        applyFocusLockVisualState(animated: animated)
    }

    private func applyFocusLockVisualState(animated: Bool) {
        let changes = {
            self.focusLockLabel.alpha = self.isFocusLocked ? 1 : 0
        }
        guard animated else {
            changes()
            return
        }
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            changes()
        }
    }

    private func showFocusIndicator(at point: CGPoint, locked: Bool) {
        setFocusLocked(locked, animated: true)
        focusIndicatorDismissWorkItem?.cancel()

        let half = focusIndicatorSize / 2
        let clamped = CGPoint(
            x: min(max(point.x, half), bounds.width - half),
            y: min(max(point.y, half), bounds.height - half)
        )

        focusIndicatorView.center = clamped
        positionFocusLockLabel(near: clamped)
        focusIndicatorView.alpha = 0
        focusIndicatorView.transform = CGAffineTransform(scaleX: 1.18, y: 1.18)

        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.focusIndicatorView.alpha = 1
            self.focusIndicatorView.transform = .identity
        }

        if !locked {
            scheduleFocusIndicatorDismiss(after: 0.9)
        }
    }

    private func scheduleFocusIndicatorDismiss(after delay: TimeInterval) {
        let dismiss = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
                self.focusIndicatorView.alpha = 0
            }
        }
        focusIndicatorDismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: dismiss)
    }

    @objc private func handleTapToFocus(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let layerPoint = recognizer.location(in: self)
        showFocusIndicator(at: layerPoint, locked: false)
        let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        onTapToFocus?(layerPoint, devicePoint)
    }

    @objc private func handleLongPressToFocusLock(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let layerPoint = recognizer.location(in: self)
        showFocusIndicator(at: layerPoint, locked: true)
        let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        onLongPressToFocusLock?(layerPoint, devicePoint)
    }

    deinit {
        teardownRotation()
        focusIndicatorDismissWorkItem?.cancel()
        if let obs = sessionObservation {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}
