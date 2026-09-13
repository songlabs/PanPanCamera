import CoreImage
import Foundation

enum BeautyProcessingQuality: Equatable, Sendable { case preview, final }

/// The one product pipeline for Preview, PhotoOutput and Silent Frame.
/// Skin -> Makeup -> Face Shape -> Filter. No analysis or coordinate guessing here.
struct BeautyProcessor: Sendable {
    typealias MaskBuilder = @Sendable (CIImage, [AnalyzedFace], BeautyProcessingQuality) throws -> SkinMaskResult?
    private let makeSkinMask: MaskBuilder
    init(makeSkinMask: @escaping MaskBuilder = { source, faces, quality in
        try AdaptiveSkinMaskGenerator().makeMask(source: source, faces: faces, quality: quality)
    }) { self.makeSkinMask = makeSkinMask }

    private let makeup = MakeupProcessingStep()
    private let faceCorrection = FaceCorrectionPreviewStep()
    private let filter = FilterProcessingStep()

    func process(_ source: CIImage, analysis: FaceAnalysisResult?, configuration: BeautyConfiguration,
                 quality: BeautyProcessingQuality,
                 diagnostics: PhotoCaptureDiagnostics = .disabled,
                 previewDebug: ((CIImage?, FaceCorrectionGeometryResult,
                                 [FaceCorrectionGeometry.EyeAdjustment]) -> Void)? = nil) throws -> CIImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        // Observation only: Debug never enables an effect or builds an extra mask.
        let debug = quality == .preview ? previewDebug : nil
        guard !configuration.isBypassed else { return source }
        try AdaptiveSkinMaskGenerator.validate(source.extent)
        // Contract mismatch is a face-effect bypass, while a global filter is safe.
        let faces = analysis?.outcome == .analyzed && analysis?.imageSize == source.extent.size
            ? analysis?.faces ?? [] : []
        var foundation: SkinMaskResult?
        if !configuration.isSkinBypassed {
            do {
                foundation = try diagnostics.measure("skin_mask_graph_and_samples") {
                    try makeSkinMask(source, faces, quality)
                }
            } catch {
                diagnostics.mark("skin_mask_failed")
            }
        }
        var image = try diagnostics.measure("skin_graph") {
            try SkinBeautyProcessor().process(source, faces: faces, foundation: foundation,
                configuration: configuration, quality: quality)
        }
        let landmarkFaces = faces.filter { $0.landmarks.isAvailable }
        image = try diagnostics.measure("makeup_graph") {
            try makeup.makeOutput(source: image, faces: landmarkFaces, configuration: configuration.makeup) ?? image
        }
        let geometry = !configuration.isFaceCorrectionBypassed || debug != nil
            ? FaceCorrectionGeometry.result(faces: landmarkFaces, configuration: configuration, extent: source.extent) : .empty
        let eyes = !configuration.isFaceCorrectionBypassed
            ? FaceCorrectionGeometry.eyes(faces: landmarkFaces, configuration: configuration, extent: source.extent) : []
        if !configuration.isFaceCorrectionBypassed {
            image = try diagnostics.measure("face_graph") {
                // Final maps belong only to this job. Preview retains at most one map.
                let step = quality == .final ? FaceCorrectionPreviewStep() : faceCorrection
                var shaped = try step.makeOutput(source: image, warps: geometry.warps) ?? image
                for eye in eyes {
                    shaped = try CoreImageRendering.filter("CIBumpDistortion", parameters: [
                        kCIInputImageKey: shaped, kCIInputCenterKey: CIVector(cgPoint: eye.center),
                        kCIInputRadiusKey: eye.radius, kCIInputScaleKey: eye.scale
                    ], in: source.extent)
                }
                return shaped
            }
        }
        debug?(foundation?.mask, geometry, eyes)
        return try diagnostics.measure("filter_graph") {
            try filter.makeOutput(source: image, configuration: configuration.filter) ?? image
        }
    }
}
