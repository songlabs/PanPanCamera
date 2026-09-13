import CoreImage
import CoreML

struct CoreMLFaceParser {
    let prediction: CoreMLFacePrediction
    let classes: [FaceSemanticClass]

    /// Exported probabilities [C,H,W], row zero bottom; full-image, INSTANCE-aware
    /// segmentation selected by face_box. A whole-scene semantic map is not valid
    /// for this interface because it could attach another person's skin to this ID.
    func parse(_ image: CIImage, faceBox: CGRect) throws -> FaceSemanticMasks {
        guard Set(classes).count == classes.count,
              FaceSemanticClass.required.isSubset(of: Set(classes)) else { throw FaceAnalysisFailure.invalidModel }
        let output = try prediction.predict(image, faceBox: faceBox)
        let shape = output.shape.map(\.intValue)
        guard output.dataType == .float32, shape.count == 3, shape[0] == classes.count,
              (1...512).contains(shape[1]), (1...512).contains(shape[2]) else { throw FaceAnalysisFailure.invalidOutput }
        let strides = output.strides.map(\.intValue)
        guard strides.allSatisfy({ $0 > 0 }) else { throw FaceAnalysisFailure.invalidOutput }
        let scalars = output.dataPointer.assumingMemoryBound(to: Float.self)
        var planes: [FaceSemanticClass: FaceSemanticPlane] = [:]
        for (channel, name) in classes.enumerated() {
            var values: [Float] = []
            values.reserveCapacity(shape[1] * shape[2])
            for y in 0..<shape[1] {
                for x in 0..<shape[2] {
                    values.append(scalars[channel * strides[0] + y * strides[1] + x * strides[2]])
                }
            }
            planes[name] = try FaceSemanticPlane(width: shape[2], height: shape[1], values: values)
        }
        // Per-pixel scores retain uncertainty; this adapter does not convert logits
        // by guesswork. Calibration/instance quality must be established at export.
        return try FaceSemanticMasks(confidence: 1, planes: planes)
    }
}
