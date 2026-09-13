import CoreImage
import Foundation
import ImageIO
import Vision

/// One request per engine, reused on its serial worker. Input pixels have already
/// been normalized, so Vision always receives .up and never mirrors a second time.
final class VisionFaceAnalyzer: FaceAnalyzer {
    private let request: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        // Shipping since iOS 13, well below the unchanged iOS 17 deployment target.
        // Pin a stable revision instead of opting into a future OS's default.
        request.revision = VNDetectFaceLandmarksRequestRevision3
        request.constellation = .constellation76Points
        return request
    }()

    func faces(in normalizedImage: CIImage) throws -> [AnalyzedFace] {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try VNImageRequestHandler(ciImage: normalizedImage, orientation: .up, options: [:]).perform([request])
        return Self.faces(from: request.results ?? [])
    }

    static func faces(from observations: [VNFaceObservation]) -> [AnalyzedFace] {
        observations.compactMap { face in
            guard FaceAnalysisCoordinates.isUnitBox(face.boundingBox),
                  face.confidence.isFinite, face.confidence >= 0.5 else { return nil }
            let regions: [(FacialLandmarkRegion, VNFaceLandmarkRegion2D?)] = [
                (.faceContour, face.landmarks?.faceContour),
                (.leftEye, face.landmarks?.leftEye), (.rightEye, face.landmarks?.rightEye),
                (.leftEyebrow, face.landmarks?.leftEyebrow), (.rightEyebrow, face.landmarks?.rightEyebrow),
                (.nose, face.landmarks?.nose), (.noseCrest, face.landmarks?.noseCrest),
                (.outerLips, face.landmarks?.outerLips), (.innerLips, face.landmarks?.innerLips),
                (.leftPupil, face.landmarks?.leftPupil), (.rightPupil, face.landmarks?.rightPupil)
            ]
            let values = Dictionary(uniqueKeysWithValues: regions.map { name, region in
                (name, imagePoints(region?.normalizedPoints ?? [], boundingBox: face.boundingBox))
            })
            return AnalyzedFace(boundingBox: face.boundingBox, confidence: face.confidence,
                                landmarks: FaceLandmarks(regions: values))
        }
    }

    // Same face-local -> image mapping as the prior Vision implementation.
    static func imagePoints(_ points: [CGPoint], boundingBox: CGRect) -> [CGPoint] {
        points.filter(FaceAnalysisCoordinates.isUnitPoint).map {
            CGPoint(x: boundingBox.minX + $0.x * boundingBox.width,
                    y: boundingBox.minY + $0.y * boundingBox.height)
        }.filter(FaceAnalysisCoordinates.isUnitPoint)
    }
}
