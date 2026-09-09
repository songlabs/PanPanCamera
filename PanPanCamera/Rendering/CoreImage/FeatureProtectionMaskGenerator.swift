import CoreImage
import Foundation

/// Opaque grayscale [0,1]: white excludes smoothing. Every face/feature is max-
/// combined into one job-local CI graph. No photo render, CIContext or image cache.
struct FeatureProtectionMaskGenerator: Sendable {
    enum Failure: Error { case invalidImageExtent }

    /// Fractions of the individual face's shorter pixel side; no user parameters.
    /// Round strokes expand polygons and thicken curves before Gaussian feathering.
    struct Policy {
        let expansion: CGFloat
        let feather: CGFloat
        let strength: Double

        static func feature(_ feature: FacialLandmarkRegion) -> Self {
            switch feature {
            case .leftEye, .rightEye: return Self(expansion: 0.025, feather: 0.010, strength: 1)
            case .leftEyebrow, .rightEyebrow: return Self(expansion: 0.020, feather: 0.008, strength: 1)
            case .outerLips: return Self(expansion: 0.020, feather: 0.008, strength: 1)
            default: return Self(expansion: 0.018, feather: 0.010, strength: 0.55)
            }
        }
    }

    func makeMask(landmarks: [FacialLandmarks], regions: [FaceRegion], in extent: CGRect) throws -> CIImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !landmarks.isEmpty, !regions.isEmpty else { return nil }
        guard !extent.isEmpty, !extent.isInfinite, !extent.isNull,
              [extent.minX, extent.minY, extent.maxX, extent.maxY, extent.width, extent.height].allSatisfy(\.isFinite) else {
            throw Failure.invalidImageExtent
        }
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        var combined: CIImage?
        // Association is structural equality of the immutable region, never zip/index.
        for face in landmarks where regions.contains(face.region) {
            let rect = face.region.imageRect(in: extent)
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { continue }
            for feature in FacialLandmarkRegion.protectedFeatures {
                let points = face.imagePoints(for: feature, in: extent)
                guard !points.isEmpty else { continue }
                let policy = Policy.feature(feature)
                let side = min(rect.width, rect.height)
                guard let raster = rasterize(points, polygon: feature.isProtectionPolygon,
                                             expansion: side * policy.expansion, feather: side * policy.feather) else {
                    // Allocation/path rasterization failure drops only this feature.
                    continue
                }
                let feathered = try CoreImageRendering.filter("CIGaussianBlur", parameters: [
                    kCIInputImageKey: raster.composited(over: black), kCIInputRadiusKey: side * policy.feather
                ], in: extent)
                // Restore a full exclusion plateau, with a continuous outer ramp.
                let plateau = try CoreImageRendering.grayMask(feathered, scale: 1 / 0.98)
                let mask = try CoreImageRendering.grayMask(plateau, scale: policy.strength)
                combined = try CoreImageRendering.filter("CIMaximumCompositing", parameters: [
                    kCIInputImageKey: mask, kCIInputBackgroundImageKey: combined ?? black
                ], in: extent)
            }
        }
        return combined
    }

    private func rasterize(_ points: [CGPoint], polygon: Bool, expansion: CGFloat, feather: CGFloat) -> CIImage? {
        let path = CGMutablePath()
        path.addLines(between: points)
        if polygon { path.closeSubpath() }
        // Rasterize only a feature's bounds plus a 4-sigma black margin. A bounded
        // tile avoids whole-photo CPU rasterization per feature, including huge inputs.
        let padding = expansion + 4 * feather + 2
        let bounds = path.boundingBoxOfPath.insetBy(dx: -padding, dy: -padding).integral
        guard !bounds.isEmpty, [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite) else { return nil }
        let rasterScale = min(1, 1024 / max(bounds.width, bounds.height))
        let width = max(1, Int(ceil(bounds.width * rasterScale)))
        let height = max(1, Int(ceil(bounds.height * rasterScale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.scaleBy(x: rasterScale, y: rasterScale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.setFillColor(gray: 1, alpha: 1)
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(2 * expansion)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.drawPath(using: polygon ? .fillStroke : .stroke)
        guard let image = context.makeImage() else { return nil }
        // Scalar coverage must not undergo source-photo color-space conversion.
        return CIImage(cgImage: image, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(a: 1 / rasterScale, b: 0, c: 0, d: 1 / rasterScale,
                                              tx: bounds.minX, ty: bounds.minY))
    }
}
