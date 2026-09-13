import Foundation

enum FaceSemanticClass: String, CaseIterable, Hashable, Sendable {
    case skin, hair, leftEye, rightEye, leftEyebrow, rightEyebrow, lips, mouth
    case background, glasses, neck, ear, face

    static let required: Set<Self> = [.skin, .hair, .leftEye, .rightEye, .leftEyebrow,
        .rightEyebrow, .lips, .mouth, .background, .glasses]
    static let protected: [Self] = [.hair, .leftEye, .rightEye, .leftEyebrow, .rightEyebrow,
        .lips, .mouth, .background, .glasses, .neck, .ear]
}

/// Scalar probabilities, row zero at the bottom. No color space, CIImage, buffer
/// or inference framework is retained. The unit raster maps into analysis space.
struct FaceSemanticPlane: Equatable, Sendable {
    enum Failure: Error { case invalidRaster }
    let width: Int
    let height: Int
    let values: [Float]
    let transform: FaceAnalysisTransform

    init(width: Int, height: Int, values: [Float], transform: FaceAnalysisTransform = .identity) throws {
        guard (1...1024).contains(width), (1...1024).contains(height), values.count == width * height,
              transform.isValid, values.allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { throw Failure.invalidRaster }
        self.width = width; self.height = height; self.values = values; self.transform = transform
    }

    func transformed(by next: FaceAnalysisTransform) -> Self {
        // Both transforms are validated at the analysis/render boundary.
        Self(width: width, height: height, values: values, validatedTransform: transform.then(next))
    }

    private init(width: Int, height: Int, values: [Float], validatedTransform: FaceAnalysisTransform) {
        self.width = width; self.height = height; self.values = values; transform = validatedTransform
    }
}

struct FaceSemanticMasks: Equatable, Sendable {
    enum Failure: Error { case incompleteClasses, mismatchedRaster }
    let confidence: Float
    let planes: [FaceSemanticClass: FaceSemanticPlane]

    init(confidence: Float, planes: [FaceSemanticClass: FaceSemanticPlane]) throws {
        guard confidence.isFinite, (0...1).contains(confidence),
              FaceSemanticClass.required.isSubset(of: Set(planes.keys))
        else { throw Failure.incompleteClasses }
        guard let skin = planes[.skin], planes.values.allSatisfy({
            $0.width == skin.width && $0.height == skin.height && $0.transform == skin.transform
        }) else { throw Failure.mismatchedRaster }
        self.confidence = confidence; self.planes = planes
    }

    func transformed(by transform: FaceAnalysisTransform) -> Self {
        Self(confidence: confidence, validatedPlanes: planes.mapValues { $0.transformed(by: transform) })
    }

    private init(confidence: Float, validatedPlanes: [FaceSemanticClass: FaceSemanticPlane]) {
        self.confidence = confidence; planes = validatedPlanes
    }

    /// No detector box or contour intersection. A forehead labeled skin survives.
    /// A confident protected class always vetoes skin, even for overlapping scores.
    func skinFoundation() throws -> FaceSemanticPlane? {
        guard confidence >= 0.5, let skin = planes[.skin] else { return nil }
        let protected = FaceSemanticClass.protected.compactMap { planes[$0] }
        let values = skin.values.indices.map { index -> Float in
            let exclusion = protected.reduce(Float.zero) { max($0, $1.values[index]) }
            return max(0, skin.values[index] - exclusion) * confidence
        }
        return try FaceSemanticPlane(width: skin.width, height: skin.height, values: values,
                                     transform: skin.transform)
    }
}
