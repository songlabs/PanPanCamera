import CoreImage
import Foundation

enum BeautyProcessingQuality: Equatable, Sendable { case preview, final }

/// The one product pipeline for Preview, PhotoOutput and Silent Frame.
/// Skin -> Makeup -> Face Shape -> Filter. No analysis or coordinate guessing here.
struct BeautyProcessor: Sendable {
    private let makeup = MakeupProcessingStep()
    private let faceCorrection = FaceCorrectionPreviewStep()
    private let filter = FilterProcessingStep()

    func process(_ source: CIImage, analysis: FaceAnalysisResult?, configuration: BeautyConfiguration,
                 quality: BeautyProcessingQuality,
                 diagnostics: PhotoCaptureDiagnostics = .disabled) throws -> CIImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !configuration.isBypassed else { return source }
        try SemanticSkinMaskComposer.validate(source.extent)
        // Contract mismatch is a face-effect bypass, while a global filter is safe.
        let faces = analysis?.outcome == .analyzed && analysis?.imageSize == source.extent.size
            ? analysis?.faces ?? [] : []
        var image = try diagnostics.measure("skin_graph") {
            try SkinBeautyProcessor().process(source, faces: faces, configuration: configuration, quality: quality)
        }
        let denseFaces = faces.filter { $0.landmarks.isAvailable }
        image = try diagnostics.measure("makeup_graph") {
            try makeup.makeOutput(source: image, faces: denseFaces, configuration: configuration.makeup) ?? image
        }
        if !configuration.isFaceCorrectionBypassed {
            let warps = FaceCorrectionGeometry.warps(faces: denseFaces, configuration: configuration, extent: source.extent)
            image = try diagnostics.measure("face_graph") {
                // Final maps belong only to this job. Preview retains at most one map.
                let step = quality == .final ? FaceCorrectionPreviewStep() : faceCorrection
                return try step.makeOutput(source: image, warps: warps) ?? image
            }
        }
        return try diagnostics.measure("filter_graph") {
            try filter.makeOutput(source: image, configuration: configuration.filter) ?? image
        }
    }
}
