import CoreImage
import CoreML

struct CoreMLFaceDetector {
    struct Detection { let box: CGRect; let confidence: Float }
    let prediction: CoreMLFacePrediction

    /// Exported output [N,5]: x,y,w,h,confidence in normalized bottom-left space.
    /// NMS and a bounded maximum keep duplicate/large outputs out of downstream work.
    func detect(_ image: CIImage) throws -> [Detection] {
        let output = try prediction.predict(image)
        guard output.shape.count == 2, output.shape[1].intValue == 5,
              (0...1024).contains(output.shape[0].intValue) else { throw FaceAnalysisFailure.invalidOutput }
        var candidates: [Detection] = []
        for row in 0..<output.shape[0].intValue {
            func value(_ column: Int) -> Double { output[[NSNumber(value: row), NSNumber(value: column)]].doubleValue }
            let box = CGRect(x: value(0), y: value(1), width: value(2), height: value(3))
            let confidence = Float(value(4))
            guard FaceAnalysisCoordinates.isUnitBox(box), confidence.isFinite, (0.5...1).contains(confidence) else { continue }
            candidates.append(Detection(box: box, confidence: confidence))
        }
        var accepted: [Detection] = []
        for face in candidates.sorted(by: { $0.confidence > $1.confidence }) {
            if accepted.contains(where: { FaceAnalysisSmoother.overlap($0.box, face.box) > 0.5 }) { continue }
            accepted.append(face)
            if accepted.count == 8 { break }
        }
        return accepted
    }
}
