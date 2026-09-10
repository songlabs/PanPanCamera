import ImageIO
import Vision

/// Each instance is confined to one serial processing queue and reuses one request.
/// Camera preview and final-photo workers use separate instances so Vision requests
/// never race; both paths share this detector and result contract.
final class VisionFaceDetector {
    private let request = VNDetectFaceLandmarksRequest()

    func detect(_ pixelBuffer: CVPixelBuffer, orientation: FaceImageOrientation) throws -> [DetectedFace] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                           orientation: orientation.visionOrientation, options: [:])
        try handler.perform([request])
        return Self.faces(from: request.results ?? [])
    }

    func detect(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> [DetectedFace] {
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        try handler.perform([request])
        return Self.faces(from: request.results ?? [])
    }

    static func faces(from observations: [VNFaceObservation]) -> [DetectedFace] {
        observations.map { face in
            let regions: [(DetectedFace.Landmark, VNFaceLandmarkRegion2D?)] = [
                (.leftEye, face.landmarks?.leftEye), (.rightEye, face.landmarks?.rightEye),
                (.leftEyebrow, face.landmarks?.leftEyebrow), (.rightEyebrow, face.landmarks?.rightEyebrow),
                (.nose, face.landmarks?.nose), (.noseCrest, face.landmarks?.noseCrest),
                (.outerLips, face.landmarks?.outerLips), (.innerLips, face.landmarks?.innerLips),
                (.faceContour, face.landmarks?.faceContour)
            ]
            var landmarks: [DetectedFace.Landmark: [CGPoint]] = [:]
            for (name, region) in regions {
                landmarks[name] = FaceCoordinates.imageLandmarks(region?.normalizedPoints,
                                                                 boundingBox: face.boundingBox)
            }
            return DetectedFace(boundingBox: face.boundingBox, confidence: face.confidence,
                                landmarks: landmarks)
        }
    }
}

extension FaceImageOrientation {
    var visionOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .up
        case .right: return .right
        case .down: return .down
        case .left: return .left
        }
    }
}
