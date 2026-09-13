import CoreImage
import Foundation

/// Opaque grayscale protection, white = protect, black = allow processing.
/// This is local image structure, not semantic skin/landmark/identity detection.
/// The returned CIImage can later be max-combined with a landmark protection mask.
struct DetailProtectionMaskGenerator: Sendable {
    func makeMask(source: CIImage, scale: SkinRetouchScale) throws -> CIImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let extent = source.extent
        let policy = SkinRetouchConfiguration.Policy.self
        let edges = try CoreImageRendering.filter("CIEdges", parameters: [
            kCIInputImageKey: source.clampedToExtent(), kCIInputIntensityKey: policy.edgeIntensity
        ], in: extent)
        // Max RGB responds to chromatic edges as well as neutral contrast. There
        // are no absolute RGB/HSV skin-color thresholds or complexion exclusions.
        let maximum = try CoreImageRendering.filter("CIMaximumComponent", parameters: [
            kCIInputImageKey: edges
        ], in: extent)
        let protection = try CoreImageRendering.grayMask(maximum, scale: policy.edgeGain)
        // Expand protection across a small neighborhood to cover thin lines and
        // both sides of edges. Maximum, rather than blur, does not weaken peaks.
        return try CoreImageRendering.filter("CIMorphologyMaximum", parameters: [
            kCIInputImageKey: protection.clampedToExtent(), kCIInputRadiusKey: scale.smallRadius
        ], in: extent)
    }

}
