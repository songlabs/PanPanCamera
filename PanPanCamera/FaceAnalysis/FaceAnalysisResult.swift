import Foundation

/// One contract for every source: normalized, bottom-left coordinates in the
/// orientation-normalized image. Mirroring is already reflected in these values.
/// No ML, camera, or rendering framework types cross this boundary.
struct FaceAnalysisResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case analyzed, unavailable, failed }
    let timestamp: TimeInterval
    let imageSize: CGSize
    let orientation: FaceImageOrientation
    let mirrored: Bool
    let faces: [AnalyzedFace]
    let outcome: Outcome

    func replacing(faces: [AnalyzedFace]) -> Self {
        Self(timestamp: timestamp, imageSize: imageSize, orientation: orientation,
             mirrored: mirrored, faces: faces, outcome: outcome)
    }
}

struct AnalyzedFace: Equatable, Sendable {
    // Ephemeral session identity, never biometric recognition or persisted.
    let trackingID: UUID
    let boundingBox: CGRect
    let confidence: Float
    let landmarks: DenseFaceLandmarks
    let semanticMasks: FaceSemanticMasks?

    init(trackingID: UUID = UUID(), boundingBox: CGRect, confidence: Float,
         landmarks: DenseFaceLandmarks = .unavailable, semanticMasks: FaceSemanticMasks? = nil) {
        self.trackingID = trackingID
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.landmarks = landmarks
        self.semanticMasks = semanticMasks
    }
}

/// Typed regions have explicit anatomical meaning. Raw model indices belong only
/// to the versioned topology in the model adapter, never to Beauty effects.
enum FacialLandmarkRegion: String, CaseIterable, Hashable, Sendable {
    case leftEye, rightEye, leftEyebrow, rightEyebrow
    case nose, noseCrest, outerLips, innerLips, jawline, faceOval
}

struct DenseFaceLandmarks: Equatable, Sendable {
    let topologyID: String
    let points: [CGPoint]
    let regions: [FacialLandmarkRegion: [CGPoint]]
    static let unavailable = Self(topologyID: "unavailable", points: [], regions: [:])

    subscript(_ region: FacialLandmarkRegion) -> [CGPoint]? { regions[region] }
    var isAvailable: Bool { !points.isEmpty }

    func map(_ transform: (CGPoint) -> CGPoint) -> Self {
        Self(topologyID: topologyID, points: points.map(transform),
             regions: regions.mapValues { $0.map(transform) })
    }

    func imagePoints(for region: FacialLandmarkRegion, in extent: CGRect) -> [CGPoint] {
        (self[region] ?? []).map {
            CGPoint(x: extent.minX + $0.x * extent.width, y: extent.minY + $0.y * extent.height)
        }
    }
}

struct FaceLandmarkTopology: Sendable {
    enum Failure: Error { case invalidTopology, invalidPoints }
    let identifier: String
    let pointCount: Int
    let indices: [FacialLandmarkRegion: [Int]]

    init(identifier: String, pointCount: Int, indices: [FacialLandmarkRegion: [Int]]) throws {
        guard !identifier.isEmpty, pointCount >= 100, pointCount <= 2048,
              !indices.isEmpty, indices.values.allSatisfy({ values in
                  !values.isEmpty && Set(values).count == values.count &&
                  values.allSatisfy { (0..<pointCount).contains($0) }
              }) else { throw Failure.invalidTopology }
        self.identifier = identifier
        self.pointCount = pointCount
        self.indices = indices
    }

    func landmarks(points: [CGPoint]) throws -> DenseFaceLandmarks {
        guard points.count == pointCount, points.allSatisfy(FaceAnalysisCoordinates.isUnitPoint)
        else { throw Failure.invalidPoints }
        return DenseFaceLandmarks(topologyID: identifier, points: points,
            regions: indices.mapValues { $0.map { points[$0] } })
    }
}
