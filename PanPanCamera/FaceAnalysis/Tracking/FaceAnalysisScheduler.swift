import CoreImage
import Foundation

/// One in-flight input, no pending buffer queue. Rendering reads the last completed
/// result independently of main-thread debug delivery. Models live in the engine.
final class FaceAnalysisScheduler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "camera.panpan.analysis-admission", qos: .userInitiated)
    private let lock = NSLock()
    private let engine: FaceAnalysisEngine
    private var active = true
    private var busy = false
    private var nextStart: TimeInterval = 0
    private var latest: FaceAnalysisResult?
    private var smoother = FaceAnalysisSmoother() // queue only

    init(engine: FaceAnalysisEngine) { self.engine = engine }

    @discardableResult
    func submit(_ image: CIImage, timestamp: TimeInterval, orientation: FaceImageOrientation,
                mirrored: Bool, completion: @escaping (FaceAnalysisResult) -> Void) -> Bool {
        lock.lock()
        guard active, !busy, timestamp.isFinite, timestamp >= nextStart else { lock.unlock(); return false }
        busy = true
        lock.unlock()
        queue.async { [self] in
            autoreleasepool {
                lock.lock()
                let shouldAnalyze = active
                lock.unlock()
                guard shouldAnalyze else { return }
                let start = ProcessInfo.processInfo.systemUptime
                guard let raw = engine.analyzePreviewIfIdle(image, timestamp: timestamp,
                    orientation: orientation, mirrored: mirrored) else {
                    lock.lock()
                    busy = false; nextStart = timestamp + 1.0 / 12.0
                    lock.unlock()
                    return
                }
                let result = smoother.update(raw)
                let duration = ProcessInfo.processInfo.systemUptime - start
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-PanPanFaceAnalysisTiming") {
                    // Numeric timing/outcome only, never facial points or image data.
                    print("FaceAnalysis duration_ms=\(duration * 1_000) outcome=\(result.outcome) faces=\(result.faces.count)")
                }
                #endif
                lock.lock()
                busy = false
                // Target 12 Hz; slow devices get a cooldown rather than a backlog.
                nextStart = timestamp + max(1.0 / 12.0, duration * 1.15)
                let publish = active
                if publish { latest = result }
                lock.unlock()
                if publish { completion(result) }
            }
        }
        return true
    }

    func snapshot(at time: TimeInterval) -> FaceAnalysisResult? {
        lock.lock(); defer { lock.unlock() }
        guard active, let latest, time >= latest.timestamp, time - latest.timestamp <= 0.5 else { return nil }
        return latest
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        active = false; latest = nil
    }
}
