import CoreImage
import CoreML

struct CoreMLFaceLandmarkDetector {
    let prediction: CoreMLFacePrediction
    let topology: FaceLandmarkTopology

    /// Exported output [pointCount,2], full-image normalized bottom-left points.
    /// face_box selects this instance; no raw index escapes the topology adapter.
    func detect(_ image: CIImage, faceBox: CGRect) throws -> DenseFaceLandmarks {
        let output = try prediction.predict(image, faceBox: faceBox)
        guard output.shape.map(\.intValue) == [topology.pointCount, 2] else { throw FaceAnalysisFailure.invalidOutput }
        let points = (0..<topology.pointCount).map { index in
            CGPoint(x: output[[NSNumber(value: index), 0]].doubleValue,
                    y: output[[NSNumber(value: index), 1]].doubleValue)
        }
        return try topology.landmarks(points: points)
    }
}
