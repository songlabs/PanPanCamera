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
        diagnostics.value("resolved_photo_width", Int(resolvedSettings.photoDimensions.width))
        diagnostics.value("resolved_photo_height", Int(resolvedSettings.photoDimensions.height))
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        diagnostics.mark("avcapture_didFinishProcessingPhoto")
        #if DEBUG
        // Compressed PhotoOutput may expose no pixel buffer. Report this explicitly
        // instead of inventing a CV pixel format for encoded JPEG/HEIF bytes.
        let format = photo.pixelBuffer.map { String(CVPixelBufferGetPixelFormatType($0)) } ?? "encoded_no_pixel_buffer"
        diagnostics.input(width: Int(photo.resolvedSettings.photoDimensions.width),
                          height: Int(photo.resolvedSettings.photoDimensions.height), pixelFormat: format)
        #endif
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
        if let data {
            diagnostics.value("photo_data_bytes", data.count)
            diagnostics.mark("capture_data_ready")
        }
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
