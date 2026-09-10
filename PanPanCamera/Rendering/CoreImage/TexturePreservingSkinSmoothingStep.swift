import CoreImage
import Foundation

/// Frequency-aware retouch shared by product Beauty processing and DEBUG diagnostics.
/// No tone lift, skin-color classifier, defect removal or geometry modification.
struct TexturePreservingSkinSmoothingStep: ImageProcessingStep {
    let configuration: SkinRetouchConfiguration
    private let maskGenerator: any FaceMaskGenerating
    private let landmarkDetector: (any FaceLandmarkDetecting<ProcessingImage>)?
    private let skinMaskProvider: (any SkinMaskProviding)?

    init(configuration: SkinRetouchConfiguration = .naturalDefault,
         maskGenerator: any FaceMaskGenerating = SoftFaceMaskGenerator(),
         landmarkDetector: (any FaceLandmarkDetecting<ProcessingImage>)? = nil,
         skinMaskProvider: (any SkinMaskProviding)? = nil) {
        self.configuration = configuration
        self.maskGenerator = maskGenerator
        self.landmarkDetector = landmarkDetector
        self.skinMaskProvider = skinMaskProvider
    }

    func process(_ image: ProcessingImage, regions: [FaceRegion]) throws -> ProcessingImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        // Strict identity: no CIImage, filter, mask, context or temporary raster.
        guard configuration.intensity.value > 0, !regions.isEmpty else { return image }
        let source = CIImage(cgImage: image.cgImage)
        // Missing/failed optional detection keeps the existing face + edge path.
        let landmarks = (try? landmarkDetector?.detectLandmarks(in: image, regions: regions)) ?? []
        let semantics = try skinMasks(in: image, regions: regions, landmarks: landmarks)
        guard let output = try makeOutput(source: source, regions: regions, landmarks: landmarks, skinMasks: semantics) else { return image }
        return try CoreImageRendering.render(output, matching: image)
    }

    /// Job-local graph also exposes the nonzero-extent contract to Apple tests.
    /// No CIImage graph escapes the public ProcessingImage step or DEBUG entry.
    func makeOutput(source: CIImage, regions: [FaceRegion], landmarks: [FacialLandmarks] = [],
                    skinMasks: [SkinMaskResult] = []) throws -> CIImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard configuration.intensity.value > 0, !regions.isEmpty else { return nil }
        guard let scale = SkinRetouchScale(regions: regions, in: source.extent),
              let masks = try makeMasks(source: source, regions: regions, landmarks: landmarks, skinMasks: skinMasks) else { return nil }
        let effectiveMask = masks.effectiveSkinMask
        let small = try lowPass(source, radius: scale.smallRadius)
        let large = try lowPass(source, radius: scale.largeRadius)
        let low: CIImage
        if configuration.noiseReductionStrength == 0 {
            low = large
        } else {
            low = try CoreImageRendering.filter("CINoiseReduction", parameters: [
                kCIInputImageKey: large.clampedToExtent(),
                "inputNoiseLevel": configuration.noiseReductionStrength,
                "inputSharpness": SkinRetouchConfiguration.Policy.noiseSharpness
            ], in: source.extent)
        }
        let policy = SkinRetouchConfiguration.Policy.self
        let midRetention = 1 - policy.midFrequencyAttenuation * (1 - configuration.detailRetention)
        let opacitySupport = try makeOpacitySupport(source: source, scale: scale)
        guard let kernel = Self.reconstruction,
              let adjusted = kernel.apply(extent: source.extent, arguments: [
                source, small, large, low, opacitySupport, configuration.detailRetention, midRetention,
                policy.maximumChannelChange, policy.opaqueThreshold
              ]) else { throw CoreImageRendering.Failure.filterUnavailable }
        // All faces share one reconstructed candidate and exactly one photo blend.
        return try CoreImageRendering.blend(adjusted, over: source, mask: effectiveMask)
    }

    /// Shared with explicit DEBUG diagnostics. These may inspect masks at zero
    /// intensity, while process() still bypasses every provider/graph at zero.
    func makeMasks(source: CIImage, regions: [FaceRegion], landmarks: [FacialLandmarks] = [],
                   skinMasks: [SkinMaskResult] = []) throws -> EffectiveSkinMaskComposer.Masks? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let scale = SkinRetouchScale(regions: regions, in: source.extent) else { return nil }
        let detail = try DetailProtectionMaskGenerator().makeMask(source: source, scale: scale)
        let feature = try FeatureProtectionMaskGenerator().makeMask(landmarks: landmarks, regions: regions, in: source.extent)
        return try EffectiveSkinMaskComposer(faceMaskGenerator: maskGenerator).compose(
            regions: regions, skinMasks: skinMasks, feature: feature, detail: detail, configuration: configuration)
    }

    func skinMasks(in image: ProcessingImage, regions: [FaceRegion],
                   landmarks: [FacialLandmarks]) throws -> [SkinMaskResult] {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let skinMaskProvider else { return [] }
        var results: [SkinMaskResult] = []
        for region in regions where !results.contains(where: { $0.region == region }) {
            let result = try skinMaskProvider.skinMask(in: image, region: region,
                landmarks: landmarks.first { $0.region == region })
            // A provider cannot relabel another face through the per-face call.
            results.append(result.region == region ? result : .unavailable(for: region))
        }
        return results
    }

    private func lowPass(_ source: CIImage, radius: Double) throws -> CIImage {
        // Gaussian is ONLY frequency decomposition, never a final blurred photo.
        try CoreImageRendering.filter("CIGaussianBlur", parameters: [
            kCIInputImageKey: source.clampedToExtent(), kCIInputRadiusKey: radius
        ], in: source.extent)
    }

    /// Gaussian half-float accumulation can turn alpha 1 into 0.9990. Use the
    /// original neighborhood's minimum alpha for the transparency decision;
    /// morphology does not accumulate rounding error. Cover the large blur's
    /// three-sigma support without changing any frequency or strength parameter.
    func makeOpacitySupport(source: CIImage, scale: SkinRetouchScale) throws -> CIImage {
        try CoreImageRendering.filter("CIMorphologyMinimum", parameters: [
            kCIInputImageKey: source.clampedToExtent(),
            kCIInputRadiusKey: ceil(scale.largeRadius * 3)
        ], in: source.extent)
    }

    // One small pointwise Core Image color kernel keeps signed detail residuals
    // without using clamping/absolute-value blend modes as subtraction. No custom
    // Metal renderer/shader pipeline. Immutable kernel is shared; images are not.
    // init(source:) is Apple's legacy CI language API; Apple execution is pending.
    private static let reconstruction = CIColorKernel(source: """
        kernel vec4 reconstruct(__sample original, __sample small, __sample large,
                                __sample low, __sample opacitySupport, float detailRetention, float midRetention,
                                float maximumChange, float opaqueThreshold) {
            // Conservatively leave translucency and transparent neighborhoods alone.
            // Alpha is never smoothed/replaced by a filter's generated alpha.
            if (original.a < opaqueThreshold || opacitySupport.a < opaqueThreshold) { return original; }
            vec3 o = unpremultiply(original).rgb;
            vec3 s = unpremultiply(small).rgb;
            vec3 l = unpremultiply(large).rgb;
            vec3 n = unpremultiply(low).rgb;
            vec3 highDetail = o - s;
            vec3 midTexture = s - l;
            vec3 reconstructed = n + midRetention * midTexture + detailRetention * highDetail;
            vec3 change = clamp(reconstructed - o, vec3(-maximumChange), vec3(maximumChange));
            return premultiply(vec4(o + change, original.a));
        }
        """)
}
