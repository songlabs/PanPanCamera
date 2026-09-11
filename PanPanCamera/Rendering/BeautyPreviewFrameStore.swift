import AVFoundation
import Foundation

/// Temporary internal TestFlight diagnostic gate. Set this single value to false
/// before the production App Store release; there is intentionally no Settings UI.
enum FaceGeometryDebugMode {
    static let isEnabled = true
}

/// One immutable camera-frame handoff. The pixel buffer remains sensor-native;
/// orientation and mirroring are applied only by the preview renderer.
struct BeautyPreviewFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let orientation: FaceImageOrientation
    let mirrored: Bool
    let faces: [DetectedFace]
    let configuration: BeautyConfiguration
    // Only Slim consumes this Preview-only contour history. nil preserves the
    // stateless geometry path for callers without live detection timing.
    var slimFaces: [DetectedFace]? = nil
    // Independently smoothed feature history from the SAME Vision observations.
    var makeupFaces: [DetectedFace]? = nil
}

/// Owned by one CameraFaceFrameProcessor generation, on its serial video queue.
/// Smooth at camera-frame cadence (not only the <=8 Hz Vision cadence). No stable
/// identity is supplied by Vision: smooth only an unambiguous single face and reset
/// on loss, low confidence, topology/association changes or stale observations.
struct PreviewSlimLandmarkSmoother {
    // Reuse the established temporal/association policy for makeup, leaving the
    // default Slim contour-only behavior and its tuning unchanged.
    let includesAllFeatures: Bool
    private var previous: DetectedFace?
    private var previousRaw: DetectedFace?
    private var previousTime: TimeInterval?

    init(includesAllFeatures: Bool = false) {
        self.includesAllFeatures = includesAllFeatures
    }

    mutating func update(faces: [DetectedFace], observationTime: TimeInterval,
                         time: TimeInterval) -> [DetectedFace] {
        guard time.isFinite, observationTime.isFinite, time >= observationTime,
              time - observationTime <= 0.5 else { reset(); return [] }
        guard faces.count == 1, let face = faces.first else {
            reset()
            return faces // Never blend histories across a primary-face selection.
        }
        guard face.confidence.isFinite, face.confidence >= 0.5,
              let points = trackingPoints(face), points.count >= 5,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              face.boundingBox.width > 0, face.boundingBox.height > 0 else {
            reset()
            return []
        }
        defer { previousRaw = face; previousTime = time }
        guard let previous, let raw = previousRaw, let lastTime = previousTime,
              time >= lastTime, time - lastTime <= 0.25,
              let oldPoints = trackingPoints(previous), oldPoints.count == points.count,
              associated(raw, face) else {
            self.previous = face
            return [face]
        }
        // 60 ms for jitter: alpha ~= .24 at 60 FPS / .43 at 30 FPS. Large
        // movement continuously shortens tau toward 18 ms; no motion threshold jump.
        let box = face.boundingBox
        let motion = zip(oldPoints, points).reduce(CGFloat.zero) { largest, pair in
            max(largest, hypot((pair.0.x - pair.1.x) / box.width,
                               (pair.0.y - pair.1.y) / box.height))
        }
        let follow = min(1, motion / 0.08)
        let tau = 0.060 + (0.018 - 0.060) * Double(follow * follow * (3 - 2 * follow))
        let alpha = CGFloat(1 - exp(-(time - lastTime) / tau))
        func blend(_ old: CGFloat, _ current: CGFloat) -> CGFloat { old + (current - old) * alpha }
        let smoothedBox = CGRect(x: blend(previous.boundingBox.minX, box.minX),
            y: blend(previous.boundingBox.minY, box.minY),
            width: blend(previous.boundingBox.width, box.width),
            height: blend(previous.boundingBox.height, box.height))
        let smoothed = zip(oldPoints, points).map {
            CGPoint(x: blend($0.x, $1.x), y: blend($0.y, $1.y))
        }
        var landmarks: [FacialLandmarkRegion: [CGPoint]] = [.faceContour: smoothed]
        if includesAllFeatures {
            landmarks = face.landmarks
            for (name, current) in face.landmarks {
                guard let old = previous.landmarks[name], old.count == current.count else { continue }
                landmarks[name] = zip(old, current).map {
                    CGPoint(x: blend($0.x, $1.x), y: blend($0.y, $1.y))
                }
            }
        }
        let output = DetectedFace(boundingBox: smoothedBox, confidence: face.confidence,
                                  landmarks: landmarks)
        self.previous = output
        return [output]
    }

    mutating func reset() {
        previous = nil
        previousRaw = nil
        previousTime = nil
    }

    private func associated(_ old: DetectedFace, _ current: DetectedFace) -> Bool {
        let a = old.boundingBox, b = current.boundingBox
        guard (0.75...1.33).contains(b.width / a.width),
              (0.75...1.33).contains(b.height / a.height),
              hypot((a.midX - b.midX) / a.width, (a.midY - b.midY) / a.height) < 0.20,
              let oldPoints = trackingPoints(old),
              let newPoints = trackingPoints(current), oldPoints.count == newPoints.count else {
            return false
        }
        if includesAllFeatures && FacialLandmarkRegion.allCases.contains(where: {
            old.landmarks[$0]?.count != current.landmarks[$0]?.count
        }) { return false }
        return zip(oldPoints, newPoints).allSatisfy {
            hypot(($0.x - $1.x) / a.width, ($0.y - $1.y) / a.height) < 0.20
        }
    }

    private func trackingPoints(_ face: DetectedFace) -> [CGPoint]? {
        if !includesAllFeatures { return face.landmarks[.faceContour] }
        return FacialLandmarkRegion.allCases.flatMap { face.landmarks[$0] ?? [] }
    }
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
