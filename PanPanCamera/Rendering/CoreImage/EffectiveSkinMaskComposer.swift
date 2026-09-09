import CoreImage
import Foundation

/// Composes coverage only; no smoothing, image render, provider or photo inspection.
struct EffectiveSkinMaskComposer: Sendable {
    struct Masks {
        let faceMask: CIImage
        /// max of each face's semantic weights, bounded to its region. Missing
        /// semantics appear white inside that region to make fallback inspectable.
        let skinMask: CIImage
        let featureProtectionMask: CIImage
        let detailProtectionMask: CIImage
        let combinedProtectionMask: CIImage
        let effectiveSkinMask: CIImage
    }

    private let faceMaskGenerator: any FaceMaskGenerating

    init(faceMaskGenerator: any FaceMaskGenerating = SoftFaceMaskGenerator()) {
        self.faceMaskGenerator = faceMaskGenerator
    }

    func compose(regions: [FaceRegion], skinMasks: [SkinMaskResult],
                 feature: CIImage?, detail: CIImage,
                 configuration: SkinRetouchConfiguration) throws -> Masks? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !regions.isEmpty else { return nil }
        let extent = detail.extent
        try SkinMaskResult.validate(extent)
        if let feature, feature.extent != extent { throw SkinMaskResult.Failure.mismatchedMaskExtent }
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        var faces = black, semantics = black, coveredSkin = black
        var hasCoverage = false
        var usedRegions: [FaceRegion] = []
        for region in regions where !usedRegions.contains(region) {
            usedRegions.append(region)
            guard let face = try faceMaskGenerator.makeMask(regions: [region], in: extent) else { continue }
            hasCoverage = true
            guard face.extent == extent else { throw SkinMaskResult.Failure.mismatchedMaskExtent }
            var semantic: CIImage?
            // Reordered/duplicate/partial results are safe. An unavailable duplicate
            // cannot override an available result; unrelated regions are ignored.
            for result in skinMasks where result.region == region {
                guard let mask = result.mask else { continue }
                guard mask.extent == extent else { throw SkinMaskResult.Failure.mismatchedMaskExtent }
                semantic = try maximum(semantic ?? black, mask)
            }
            let skin = semantic ?? white
            faces = try maximum(faces, face)
            let visibleSkin = skin.cropped(to: region.imageRect(in: extent)).composited(over: black).cropped(to: extent)
            semantics = try maximum(semantics, visibleSkin)
            // Pair BEFORE union: max(Fa*Sa, Fb*Sb), not max(Fa,Fb)*max(Sa,Sb).
            // Otherwise a missing face's white fallback would erase another face's
            // exclusions even outside the missing face's own coverage.
            coveredSkin = try maximum(coveredSkin, Self.multiply(face, skin))
        }
        guard hasCoverage else { return nil }
        let combined = try ProtectionMaskCombiner.combined(feature: feature, detail: detail, configuration: configuration)
        return Masks(faceMask: faces, skinMask: semantics, featureProtectionMask: feature ?? black,
                     detailProtectionMask: detail, combinedProtectionMask: combined,
                     effectiveSkinMask: try Self.effective(face: coveredSkin, combined: combined, configuration: configuration))
    }

    /// Single face formula, also retained as the old no-semantics helper's backend.
    static func effective(face: CIImage, skin: CIImage? = nil, combined: CIImage,
                          configuration: SkinRetouchConfiguration) throws -> CIImage {
        let allowed = try CoreImageRendering.grayMask(combined, scale: -1, bias: 1)
        let faceSkin = try skin.map { try multiply(face, $0) } ?? face
        let coverage = try multiply(faceSkin, allowed)
        return try CoreImageRendering.grayMask(coverage, scale: configuration.intensity.value)
    }

    private static func multiply(_ a: CIImage, _ b: CIImage) throws -> CIImage {
        try CoreImageRendering.filter("CIMultiplyCompositing", parameters: [
            kCIInputImageKey: a, kCIInputBackgroundImageKey: b
        ], in: a.extent)
    }

    private func maximum(_ a: CIImage, _ b: CIImage) throws -> CIImage {
        try CoreImageRendering.grayMask(CoreImageRendering.filter("CIMaximumCompositing", parameters: [
            kCIInputImageKey: a, kCIInputBackgroundImageKey: b
        ], in: a.extent), scale: 1)
    }
}
