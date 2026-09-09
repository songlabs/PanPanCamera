import CoreImage

/// Feature exclusion and generic edge protection have independent semantics.
/// Both graphs are opaque scalar masks; clamp at the arithmetic boundaries.
enum ProtectionMaskCombiner {
    static func combined(feature: CIImage?, detail: CIImage,
                         configuration: SkinRetouchConfiguration) throws -> CIImage {
        let edge = try CoreImageRendering.grayMask(detail, scale: configuration.edgeProtectionStrength)
        guard let feature else { return edge }
        let boundedFeature = try CoreImageRendering.grayMask(feature, scale: 1)
        let combined = try CoreImageRendering.filter("CIMaximumCompositing", parameters: [
            kCIInputImageKey: boundedFeature, kCIInputBackgroundImageKey: edge
        ], in: detail.extent)
        return try CoreImageRendering.grayMask(combined, scale: 1)
    }

    static func effective(face: CIImage, combined: CIImage,
                          configuration: SkinRetouchConfiguration) throws -> CIImage {
        // Compatibility for existing edge-only probes/tests; one effective formula.
        try EffectiveSkinMaskComposer.effective(face: face, combined: combined, configuration: configuration)
    }
}
