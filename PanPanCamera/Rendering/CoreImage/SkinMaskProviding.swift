import CoreImage

/// Single-photo semantic weights on the existing worker, in the same oriented
/// ProcessingImage/FaceRegion coordinates. No image retention or preview state.
/// Return .unavailable(for:) for an expected segmentation miss; throw only for a
/// real processing error. A missing provider has the same per-face fallback.
protocol SkinMaskProviding: Sendable {
    func skinMask(in image: ProcessingImage, region: FaceRegion,
                  landmarks: FacialLandmarks?) throws -> SkinMaskResult
}

/// Job-local graph bound by immutable FaceRegion equality, never an array index.
/// nil means unavailable, NOT a black mask. An available mask has the exact finite
/// image extent, RGB scalar weights 0...1 and alpha 1. Black forbids processing;
/// white allows it. Input alpha multiplies the semantic weight (transparent = 0).
/// Providers import scalar rasters without color conversion, normalize orientation
/// before producing a result and never mirror again. Continuous edges are required.
struct SkinMaskResult {
    enum Failure: Error { case invalidImageExtent, mismatchedMaskExtent }

    let region: FaceRegion
    let mask: CIImage?

    init(region: FaceRegion, mask: CIImage, in extent: CGRect) throws {
        try Self.validate(extent)
        guard mask.extent == extent else { throw Failure.mismatchedMaskExtent }
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        self.region = region
        // Flatten alpha over zero before converting to an opaque scalar. Merely
        // replacing alpha with 1 would incorrectly permit transparent mask pixels.
        self.mask = try CoreImageRendering.grayMask(mask.composited(over: black).cropped(to: extent), scale: 1)
    }

    private init(region: FaceRegion) { self.region = region; mask = nil }
    static func unavailable(for region: FaceRegion) -> Self { Self(region: region) }

    static func validate(_ extent: CGRect) throws {
        guard !extent.isEmpty, !extent.isInfinite, !extent.isNull,
              [extent.minX, extent.minY, extent.maxX, extent.maxY,
               extent.width, extent.height].allSatisfy(\.isFinite) else {
            throw Failure.invalidImageExtent
        }
    }
}
