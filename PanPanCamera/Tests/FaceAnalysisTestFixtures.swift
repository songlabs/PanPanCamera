import CoreImage
import CoreVideo
import Foundation
@testable import PanPanCamera

/// Synthetic DTO fixtures only. Production has no dictionary landmark adapter.
extension AnalyzedFace {
    init(boundingBox: CGRect, confidence: Float, landmarks: [FacialLandmarkRegion: [CGPoint]]) {
        self.init(boundingBox: boundingBox, confidence: confidence,
            landmarks: FaceLandmarks(regions: landmarks))
    }
}

extension BeautyPreviewFrame {
    init(pixelBuffer: CVPixelBuffer, orientation: FaceImageOrientation, mirrored: Bool,
         faces: [AnalyzedFace], configuration: BeautyConfiguration) {
        let raw = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let size = orientation == .right || orientation == .left ? CGSize(width: raw.height, height: raw.width) : raw
        self.init(pixelBuffer: pixelBuffer, orientation: orientation, mirrored: mirrored,
            analysis: FaceAnalysisResult(timestamp: 1, imageSize: size, orientation: orientation,
                mirrored: false, faces: faces, outcome: .analyzed), configuration: configuration)
    }
}

/// Fixtures exercise the actual contract consumers, with no effect implementation.
struct BeautyTestHarness {
    private let beauty = BeautyProcessor()
    private let preview = BeautyPreviewProcessor()
    func process(_ source: CIImage, faces: [AnalyzedFace], configuration: BeautyConfiguration,
                 quality: BeautyProcessingQuality) throws -> CIImage {
        try beauty.process(source, analysis: FaceAnalysisResult(timestamp: 1, imageSize: source.extent.size,
            orientation: .up, mirrored: false, faces: faces, outcome: .analyzed), configuration: configuration, quality: quality)
    }
    func previewImage(for frame: BeautyPreviewFrame, displayRotationAngle: CGFloat, targetSize: CGSize) throws -> CIImage? {
        try preview.previewImage(for: frame, displayRotationAngle: displayRotationAngle, targetSize: targetSize)
    }
    func previewResult(for frame: BeautyPreviewFrame, displayRotationAngle: CGFloat, targetSize: CGSize) throws -> BeautyPreviewProcessingResult {
        try preview.previewResult(for: frame, displayRotationAngle: displayRotationAngle, targetSize: targetSize)
    }
    static func reorientedFaces(_ faces: [AnalyzedFace], from source: FaceImageOrientation,
                                to destination: FaceImageOrientation, mirrored: Bool) -> [AnalyzedFace] {
        FaceAnalysisCoordinates.map(faces, by: FaceAnalysisCoordinates.reorientation(from: source,
            sourceMirrored: false, to: destination, mirrored: mirrored))
    }
}

final class FixtureFaceAnalyzer: FaceAnalyzer {
    let result: [AnalyzedFace]
    let failure: Bool
    init(faces: [AnalyzedFace] = [], failure: Bool = false) { result = faces; self.failure = failure }
    func faces(in normalizedImage: CIImage) throws -> [AnalyzedFace] {
        if failure { throw FaceAnalysisFailure.invalidOutput }
        return result
    }
}

enum AnalysisFixture {
    static func result(_ faces: [AnalyzedFace], size: CGSize) -> FaceAnalysisResult {
        FaceAnalysisResult(timestamp: 1, imageSize: size, orientation: .up, mirrored: false, faces: faces, outcome: .analyzed)
    }
}
