import AVFoundation

/// Retained by CameraSession until didFinishCaptureFor, including failure paths.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private var photoData: Data?
    private var processingFailed = false
    private let diagnostics: PhotoCaptureDiagnostics
    private let completion: (Data?) -> Void

    init(diagnostics: PhotoCaptureDiagnostics = .disabled, completion: @escaping (Data?) -> Void) {
        self.diagnostics = diagnostics
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        diagnostics.mark("avcapture_start")
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        diagnostics.mark("avcapture_didFinishProcessingPhoto")
        let data = diagnostics.measure("capture_file_data") {
            error == nil ? photo.fileDataRepresentation() : nil
        }
        process(data: data, error: error)
    }

    // The AVFoundation callbacks feed these same transitions in production.
    func process(data: Data?, error: Error?) {
        guard error == nil else {
            processingFailed = true
            return
        }
        photoData = data
        if data != nil { diagnostics.mark("capture_data") }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        finish(error: error)
    }

    func finish(error: Error?) {
        diagnostics.mark("avcapture_didFinishCapture")
        completion(error == nil && !processingFailed ? photoData : nil)
    }
}
