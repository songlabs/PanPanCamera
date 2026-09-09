import AVFoundation
import ImageIO

enum SilentCaptureStrategy: Equatable {
    case suppressedPhotoOutput
    case silentVideoFrame

    static func select(suppressionSupported: Bool) -> Self {
        suppressionSupported ? .suppressedPhotoOutput : .silentVideoFrame
    }
}

struct SilentFrameOrientation {
    static func exif(captureOrientation: FaceImageOrientation, mirrored: Bool) -> CGImagePropertyOrientation {
        switch (captureOrientation, mirrored) {
        case (.up, false): .up
        case (.right, false): .right
        case (.down, false): .down
        case (.left, false): .left
        case (.up, true): .upMirrored
        case (.right, true): .rightMirrored
        case (.down, true): .downMirrored
        case (.left, true): .leftMirrored
        }
    }
}

struct SilentFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let timestamp: CMTime
    let orientation: FaceImageOrientation
    let position: CameraPosition
    let mirrored: Bool
    let metadata: [String: Any]
}

/// Retains at most one camera-output buffer. Taking a frame removes it immediately,
/// so encoding never holds a growing queue or waits for a future frame.
final class SilentFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: SilentFrame?

    func replace(_ frame: SilentFrame) {
        lock.lock(); defer { lock.unlock() }
        latest = frame
    }

    func take() -> SilentFrame? {
        lock.lock(); defer { lock.unlock() }
        defer { latest = nil }
        return latest
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        latest = nil
    }
}

/// An immutable delegate context per camera/orientation/activation generation. Replaced
/// delegates invalidate their mailbox; late buffers/results can never become a new generation.
final class CameraFaceFrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let delivery = FaceDetectionDelivery()
    let deviceID: String
    let orientation: FaceImageOrientation
    private let detector: VisionFaceDetector
    private let frameStore: SilentFrameStore
    private let position: CameraPosition
    private let device: AVCaptureDevice
    private let onResult: (FaceDetectionDelivery) -> Void

    init(device: AVCaptureDevice, orientation: FaceImageOrientation, detector: VisionFaceDetector,
         frameStore: SilentFrameStore,
         onResult: @escaping (FaceDetectionDelivery) -> Void) {
        self.device = device
        self.deviceID = device.uniqueID
        self.position = device.position == .front ? .front : .back
        self.orientation = orientation
        self.detector = detector
        self.frameStore = frameStore
        self.onResult = onResult
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let start = ProcessInfo.processInfo.systemUptime
        guard connection.isActive else { return }
        autoreleasepool {
            let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            if let buffer {
                let exposure = CMTimeGetSeconds(device.exposureDuration)
                let metadata: [String: Any] = [
                    kCGImagePropertyExifDictionary as String: [
                        kCGImagePropertyExifISOSpeedRatings as String: [device.iso],
                        kCGImagePropertyExifExposureTime as String: exposure,
                        kCGImagePropertyExifLensModel as String: device.localizedName
                    ],
                    kCGImagePropertyTIFFDictionary as String: [
                        kCGImagePropertyTIFFModel as String: device.localizedName
                    ]
                ]
                frameStore.replace(SilentFrame(pixelBuffer: buffer,
                                                timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                                orientation: orientation, position: position,
                                                mirrored: position == .front, metadata: metadata))
            }
            guard delivery.begin(at: start) else { return }
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
