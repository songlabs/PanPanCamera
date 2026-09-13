import CoreImage
import ImageIO

enum FaceImageNormalization {
    static func normalize(_ source: CIImage, exif: CGImagePropertyOrientation) -> CIImage {
        let image = source.oriented(exif)
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    /// ImageIO's mirrored quarter-turn names represent encoded/display axes.
    static func metadata(_ exif: CGImagePropertyOrientation) -> (FaceImageOrientation, Bool) {
        switch exif {
        case .up: (.up, false)
        case .right: (.right, false)
        case .down: (.down, false)
        case .left: (.left, false)
        case .upMirrored: (.up, true)
        case .leftMirrored: (.right, true)
        case .downMirrored: (.down, true)
        case .rightMirrored: (.left, true)
        @unknown default: (.up, false)
        }
    }
}
