import AVFoundation
import Foundation

/// One immutable camera-frame handoff. The pixel buffer remains sensor-native;
/// orientation and mirroring are applied only by the preview renderer.
struct BeautyPreviewFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let orientation: FaceImageOrientation
    let mirrored: Bool
    let faces: [DetectedFace]
    let configuration: BeautyConfiguration
}

/// Latest-only handoff between camera frame delivery and the renderer. A slow
/// renderer replaces old frames instead of accumulating camera buffers.
final class BeautyPreviewFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: BeautyPreviewFrame?

    func replace(_ frame: BeautyPreviewFrame) {
        lock.lock()
        latest = frame
        lock.unlock()
    }

    func take() -> BeautyPreviewFrame? {
        lock.lock()
        defer { lock.unlock() }
        defer { latest = nil }
        return latest
    }

    func clear() {
        lock.lock()
        latest = nil
        lock.unlock()
    }
}

/// Parameter updates originate on MainActor while frames arrive on the capture
/// callback queue. Only a small immutable value crosses that boundary.
final class BeautyConfigurationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: BeautyConfiguration

    init(_ value: BeautyConfiguration = .disabled) { self.value = value }

    func replace(_ value: BeautyConfiguration) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func snapshot() -> BeautyConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
