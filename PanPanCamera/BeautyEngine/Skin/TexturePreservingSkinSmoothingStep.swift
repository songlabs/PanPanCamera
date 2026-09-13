import CoreImage
import Foundation

/// Frequency reconstruction only. Coverage comes exclusively from the shared adaptive skin mask.
struct TexturePreservingSkinSmoothingStep: Sendable {
    let configuration: SkinRetouchConfiguration

    func makeOutput(source: CIImage, regions: [FaceRegion], effectiveMask: CIImage) throws -> CIImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard configuration.intensity.value > 0,
              let scale = SkinRetouchScale(regions: regions, in: source.extent) else { return nil }
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
