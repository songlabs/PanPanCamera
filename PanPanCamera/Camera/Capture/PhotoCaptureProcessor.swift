import AVFoundation

/// Retained by CameraSession until didFinishCaptureFor, including failure paths.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private var photoData: Data?
    private var processingFailed = false
    private let completion: (Data?) -> Void

    init(completion: @escaping (Data?) -> Void) { self.completion = completion }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        process(data: error == nil ? photo.fileDataRepresentation() : nil, error: error)
    }

    // The AVFoundation callbacks feed these same transitions in production.
    func process(data: Data?, error: Error?) {
        guard error == nil else {
            processingFailed = true
            return
        }
        photoData = data
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        finish(error: error)
    }

    func finish(error: Error?) {
        completion(error == nil && !processingFailed ? photoData : nil)
    }
}
