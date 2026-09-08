import AVFoundation

/// An immutable delegate context per camera/orientation/activation generation. Replaced
/// delegates invalidate their mailbox; late buffers/results can never become a new generation.
final class CameraFaceFrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let delivery = FaceDetectionDelivery()
    let deviceID: String
    let orientation: FaceImageOrientation
    private let detector: VisionFaceDetector
    private let onResult: (FaceDetectionDelivery) -> Void

    init(deviceID: String, orientation: FaceImageOrientation, detector: VisionFaceDetector,
         onResult: @escaping (FaceDetectionDelivery) -> Void) {
        self.deviceID = deviceID
        self.orientation = orientation
        self.detector = detector
        self.onResult = onResult
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let start = ProcessInfo.processInfo.systemUptime
        guard connection.isActive, delivery.begin(at: start) else { return }
        autoreleasepool {
            let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            let size = buffer.map {
                CGSize(width: CGFloat(CVPixelBufferGetWidth($0)), height: CGFloat(CVPixelBufferGetHeight($0)))
            } ?? .zero
            var faces: [DetectedFace] = []
            var outcome = FaceDetectionFrame.Outcome.missingPixelBuffer
            if let buffer {
                do {
                    faces = try detector.detect(buffer, orientation: orientation)
                    outcome = .detected
                } catch {
                    // A failed frame clears old faces; later frames may retry. No face data is logged.
                    outcome = .visionFailed
                }
            }
            let frame = FaceDetectionFrame(faces: faces, orientation: orientation, deviceID: deviceID,
                                           pixelSize: size,
                                           timestamp: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
                                           outcome: outcome)
            if delivery.complete(frame, at: ProcessInfo.processInfo.systemUptime) { onResult(delivery) }
        }
    }
}
