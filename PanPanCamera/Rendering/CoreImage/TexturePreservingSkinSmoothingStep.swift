import CoreImage
import Foundation

/// Experimental frequency-aware retouch; currently called only from DEBUG tools.
/// No tone lift, skin-color classifier, defect removal or geometry modification.
struct TexturePreservingSkinSmoothingStep: ImageProcessingStep {
    let configuration: SkinRetouchConfiguration
    private let maskGenerator: any FaceMaskGenerating

    init(configuration: SkinRetouchConfiguration = .naturalDefault,
         maskGenerator: any FaceMaskGenerating = SoftFaceMaskGenerator()) {
        self.configuration = configuration
        self.maskGenerator = maskGenerator
    }

    func process(_ image: ProcessingImage, regions: [FaceRegion]) throws -> ProcessingImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        // Strict identity: no CIImage, filter, mask, context or temporary raster.
        guard configuration.intensity.value > 0, !regions.isEmpty else { return image }
        let source = CIImage(cgImage: image.cgImage)
        guard let output = try makeOutput(source: source, regions: regions) else { return image }
        return try CoreImageRendering.render(output, matching: image)
    }

    /// Job-local graph also exposes the nonzero-extent contract to Apple tests.
    /// No CIImage graph escapes the public ProcessingImage step or DEBUG entry.
    func makeOutput(source: CIImage, regions: [FaceRegion]) throws -> CIImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard configuration.intensity.value > 0, !regions.isEmpty else { return nil }
        guard let scale = SkinRetouchScale(regions: regions, in: source.extent),
              let faceMask = try maskGenerator.makeMask(regions: regions, in: source.extent) else { return nil }
        let detailGenerator = DetailProtectionMaskGenerator()
        let protection = try detailGenerator.makeMask(source: source, scale: scale)
        let effectiveMask = try detailGenerator.effectiveMask(faceMask: faceMask, protection: protection,
                                                              configuration: configuration)
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
        guard let kernel = Self.reconstruction,
              let adjusted = kernel.apply(extent: source.extent, arguments: [
                source, small, large, low, configuration.detailRetention, midRetention,
                policy.maximumChannelChange, policy.opaqueThreshold
              ]) else { throw CoreImageRendering.Failure.filterUnavailable }
        // All faces share one reconstructed candidate and exactly one photo blend.
        return try CoreImageRendering.blend(adjusted, over: source, mask: effectiveMask)
    }

    private func lowPass(_ source: CIImage, radius: Double) throws -> CIImage {
        // Gaussian is ONLY frequency decomposition, never a final blurred photo.
        try CoreImageRendering.filter("CIGaussianBlur", parameters: [
            kCIInputImageKey: source.clampedToExtent(), kCIInputRadiusKey: radius
        ], in: source.extent)
    }

    // One small pointwise Core Image color kernel keeps signed detail residuals
    // without using clamping/absolute-value blend modes as subtraction. No custom
    // Metal renderer/shader pipeline. Immutable kernel is shared; images are not.
    // init(source:) is Apple's legacy CI language API; Apple execution is pending.
    private static let reconstruction = CIColorKernel(source: """
        kernel vec4 reconstruct(__sample original, __sample small, __sample large,
                                __sample low, float detailRetention, float midRetention,
                                float maximumChange, float opaqueThreshold) {
            // Conservatively leave translucency and transparent neighborhoods alone.
            // Alpha is never smoothed/replaced by a filter's generated alpha.
            if (original.a < opaqueThreshold || small.a < opaqueThreshold ||
                large.a < opaqueThreshold || low.a < opaqueThreshold) { return original; }
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
