import CoreImage
import Foundation

/// Input pixels already have the exact orientation and mirror declared in result.
/// Implementations run synchronously on the engine's serial worker.
protocol FaceAnalyzer: AnyObject {
    func faces(in normalizedImage: CIImage) throws -> [AnalyzedFace]
}

enum FaceAnalysisFailure: Error { case invalidOutput, invalidImage }

final class FaceAnalysisEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "camera.panpan.face-analysis", qos: .userInitiated)
    // The reusable Vision request is initialized and used only on this worker.
    private lazy var analyzer: any FaceAnalyzer = makeAnalyzer()
    private let makeAnalyzer: () -> any FaceAnalyzer
    private let previewAdmission = NSLock()

    init(makeAnalyzer: @escaping () -> any FaceAnalyzer = { VisionFaceAnalyzer() }) {
        self.makeAnalyzer = makeAnalyzer
    }

    /// Shared across camera generations, so rapid rotation/switching cannot leave
    /// one retained input per obsolete scheduler waiting behind the same analyzer.
    func analyzePreviewIfIdle(_ image: CIImage, timestamp: TimeInterval,
                              orientation: FaceImageOrientation, mirrored: Bool) -> FaceAnalysisResult? {
        guard previewAdmission.try() else { return nil }
        defer { previewAdmission.unlock() }
        return analyze(image, timestamp: timestamp, orientation: orientation, mirrored: mirrored)
    }

    func analyze(_ image: CIImage, timestamp: TimeInterval, orientation: FaceImageOrientation,
                 mirrored: Bool) -> FaceAnalysisResult {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return queue.sync {
            autoreleasepool {
                var outcome = FaceAnalysisResult.Outcome.analyzed
                var faces: [AnalyzedFace] = []
                do {
                    guard image.extent.width >= 1, image.extent.height >= 1,
                          !image.extent.isInfinite, !image.extent.isNull,
                          timestamp.isFinite else { throw FaceAnalysisFailure.invalidImage }
                    faces = try analyzer.faces(in: image)
                } catch {
                    outcome = .failed
                }
                return FaceAnalysisResult(timestamp: timestamp, imageSize: image.extent.size,
                    orientation: orientation, mirrored: mirrored, faces: faces, outcome: outcome)
            }
        }
    }
}
