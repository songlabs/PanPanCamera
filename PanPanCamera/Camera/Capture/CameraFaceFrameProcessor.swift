import AVFoundation
import ImageIO
import CoreImage

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
        // ImageIO names describe the encoded pixels relative to display. A
        // display-space horizontal mirror after a quarter-turn uses the
        // opposite mirrored orientation name.
        case (.right, true): .leftMirrored
        case (.down, true): .downMirrored
        case (.left, true): .rightMirrored
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
    let delivery = FaceAnalysisDelivery()
    let deviceID: String
    let orientation: FaceImageOrientation
    private let scheduler: FaceAnalysisScheduler
    private let frameStore: SilentFrameStore
    private let previewFrameStore: BeautyPreviewFrameStore
    private let beautyConfiguration: BeautyConfigurationStore
    private let position: CameraPosition
    private let device: AVCaptureDevice
    private let onResult: (FaceAnalysisDelivery) -> Void

    init(device: AVCaptureDevice, orientation: FaceImageOrientation, engine: FaceAnalysisEngine,
         frameStore: SilentFrameStore, previewFrameStore: BeautyPreviewFrameStore,
         beautyConfiguration: BeautyConfigurationStore,
         onResult: @escaping (FaceAnalysisDelivery) -> Void) {
        self.device = device
        self.deviceID = device.uniqueID
        self.position = device.position == .front ? .front : .back
        self.orientation = orientation
        self.scheduler = FaceAnalysisScheduler(engine: engine)
        self.frameStore = frameStore
        self.previewFrameStore = previewFrameStore
        self.beautyConfiguration = beautyConfiguration
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
                publishPreview(buffer, at: start)
            }
            if let buffer {
                let image = FaceImageNormalization.normalize(CIImage(cvPixelBuffer: buffer),
                    exif: SilentFrameOrientation.exif(captureOrientation: orientation, mirrored: false))
                scheduler.submit(image, timestamp: start, orientation: orientation, mirrored: false) { [weak self] result in
                    guard let self else { return }
                    if self.delivery.complete(result) { self.onResult(self.delivery) }
                }
            }
        }
    }

    func invalidate() {
        scheduler.invalidate()
        delivery.invalidate()
    }

    private func publishPreview(_ buffer: CVPixelBuffer, at time: TimeInterval) {
        let configuration = beautyConfiguration.snapshot()
        guard !configuration.isBypassed || FaceAnalysisDebugMode.isEnabled else {
            previewFrameStore.clear()
            return
        }
        previewFrameStore.replace(BeautyPreviewFrame(pixelBuffer: buffer, orientation: orientation,
            mirrored: position == .front, analysis: scheduler.snapshot(at: time), configuration: configuration))
    }
}
