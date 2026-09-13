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
                 diagnostics: PhotoCaptureDiagnostics = .disabled) throws -> CIImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let showSkin = quality == .preview && FaceAnalysisDebugMode.skin
        guard !configuration.isBypassed || showSkin else { return source }
        try AdaptiveSkinMaskGenerator.validate(source.extent)
        // Contract mismatch is a face-effect bypass, while a global filter is safe.
        let faces = analysis?.outcome == .analyzed && analysis?.imageSize == source.extent.size
            ? analysis?.faces ?? [] : []
        var foundation: SkinMaskResult?
        if !configuration.isSkinBypassed || showSkin {
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
        #if DEBUG
        if showSkin, let foundation {
            image = try CoreImageRendering.blend(CIImage(color: .green).cropped(to: source.extent),
                over: image, mask: CoreImageRendering.grayMask(foundation.mask, scale: 0.65))
        }
        #endif
        let landmarkFaces = faces.filter { $0.landmarks.isAvailable }
        image = try diagnostics.measure("makeup_graph") {
            try makeup.makeOutput(source: image, faces: landmarkFaces, configuration: configuration.makeup) ?? image
        }
        if !configuration.isFaceCorrectionBypassed {
            let warps = FaceCorrectionGeometry.warps(faces: landmarkFaces, configuration: configuration, extent: source.extent)
            image = try diagnostics.measure("face_graph") {
                // Final maps belong only to this job. Preview retains at most one map.
                let step = quality == .final ? FaceCorrectionPreviewStep() : faceCorrection
                var shaped = try step.makeOutput(source: image, warps: warps) ?? image
                for eye in FaceCorrectionGeometry.eyes(faces: landmarkFaces, configuration: configuration, extent: source.extent) {
                    shaped = try CoreImageRendering.filter("CIBumpDistortion", parameters: [
                        kCIInputImageKey: shaped, kCIInputCenterKey: CIVector(cgPoint: eye.center),
                        kCIInputRadiusKey: eye.radius, kCIInputScaleKey: eye.scale
                    ], in: source.extent)
                }
                return shaped
            }
        }
        return try diagnostics.measure("filter_graph") {
            try filter.makeOutput(source: image, configuration: configuration.filter) ?? image
        }
    }
}
