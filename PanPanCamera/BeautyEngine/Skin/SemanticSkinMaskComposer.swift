import CoreImage
import Foundation

/// One same-frame semantic foundation reused by every Skin effect. Detector boxes
/// select frequency scale only; neither boxes nor contours restrict skin coverage.
struct SemanticSkinMaskComposer {
    enum Failure: Error { case invalidExtent }

    static func validate(_ extent: CGRect) throws {
        guard !extent.isNull, !extent.isInfinite, !extent.isEmpty,
              [extent.minX, extent.minY, extent.width, extent.height].allSatisfy(\.isFinite)
        else { throw Failure.invalidExtent }
    }

    func makeMask(source: CIImage, faces: [AnalyzedFace]) throws -> CIImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try Self.validate(source.extent)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: source.extent)
        var skin: CIImage?
        var protection = black
        var regions: [FaceRegion] = []
        for face in faces where face.confidence >= 0.5 {
            guard let masks = face.semanticMasks, let foundation = try masks.skinFoundation() else { continue }
            let allowed = try FaceSemanticRaster.image(foundation, in: source.extent)
            skin = try maximum(skin ?? black, allowed)
            // Global exclusion union stops one face's skin from overriding another
            // face's hair/eyes in overlapping instance masks. Background is per-face.
            for name in FaceSemanticClass.protected where name != .background {
                if let plane = masks.planes[name] {
                    protection = try maximum(protection, FaceSemanticRaster.image(plane, in: source.extent))
                }
            }
            if let region = try? FaceRegion(boundingBox: face.boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))) {
                regions.append(region)
            }
        }
        guard let skin, let scale = SkinRetouchScale(regions: regions, in: source.extent) else { return nil }
        let detail = try DetailProtectionMaskGenerator().makeMask(source: source, scale: scale)
        protection = try maximum(protection, detail)
        // Feather inward: multiplying by the original support prevents any skin
        // expansion into hair/background at the hairline or around glasses.
        let feathered = try LocalSkinCorrection.blur(skin, radius: CGFloat(scale.smallRadius))
        let support = try LocalSkinCorrection.multiply(skin, feathered)
        return try LocalSkinCorrection.multiply(support,
            CoreImageRendering.grayMask(protection, scale: -1, bias: 1))
    }

    private func maximum(_ a: CIImage, _ b: CIImage) throws -> CIImage {
        try CoreImageRendering.filter("CIMaximumCompositing", parameters: [
            kCIInputImageKey: a, kCIInputBackgroundImageKey: b
        ], in: a.extent)
    }
}
