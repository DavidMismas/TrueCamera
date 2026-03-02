@preconcurrency internal import AVFoundation
import Foundation

nonisolated final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    nonisolated private let completionHandler: (CameraCaptureResult) -> Void
    nonisolated private let stateQueue = DispatchQueue(label: "com.movieshot.captureprocessor.state")
    nonisolated(unsafe) private var rawPhotoData: Data?
    nonisolated(unsafe) private var processedPhotoData: Data?

    init(completion: @escaping (CameraCaptureResult) -> Void) {
        self.completionHandler = completion
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil else { return }
        guard let data = photo.fileDataRepresentation() else { return }
        stateQueue.sync {
            if photo.isRawPhoto {
                rawPhotoData = data
            } else {
                processedPhotoData = data
            }
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error {
            print("PhotoCaptureProcessor: didFinishCaptureFor error: \(error)")
        }
        let result = stateQueue.sync {
            CameraCaptureResult(rawData: rawPhotoData, processedData: processedPhotoData)
        }
        let handler = completionHandler
        DispatchQueue.main.async {
            handler(result)
        }
    }
}
