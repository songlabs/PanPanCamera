import Foundation

/// Normalized rectangle in the display-oriented image, with a bottom-left origin.
/// No tracking identity or landmarks are implied. Mirroring/orientation is resolved
/// by the image loader before detection, never by the processing steps.
struct FaceRegion: Equatable, Sendable {
    enum ValidationError: Error { case invalidNormalizedBoundingBox }

    let boundingBox: CGRect

    init(boundingBox: CGRect) throws {
        let values = [boundingBox.origin.x, boundingBox.origin.y,
                      boundingBox.size.width, boundingBox.size.height]
        guard values.allSatisfy(\.isFinite), boundingBox.size.width > 0, boundingBox.size.height > 0,
              boundingBox.origin.x >= 0, boundingBox.origin.y >= 0,
              boundingBox.maxX <= 1, boundingBox.maxY <= 1 else {
            throw ValidationError.invalidNormalizedBoundingBox
        }
        self.boundingBox = boundingBox
    }

    /// Core Image uses the same bottom-left origin. Include a nonzero extent origin
    /// and clip floating-point roundoff; no preview-layer rotation/mirroring applies.
    func imageRect(in extent: CGRect) -> CGRect {
        guard !extent.isEmpty, !extent.isInfinite, !extent.isNull,
              [extent.minX, extent.minY, extent.width, extent.height].allSatisfy(\.isFinite) else {
            return .null
        }
        return CGRect(x: extent.minX + boundingBox.minX * extent.width,
                      y: extent.minY + boundingBox.minY * extent.height,
                      width: boundingBox.width * extent.width,
                      height: boundingBox.height * extent.height).intersection(extent)
    }
}
