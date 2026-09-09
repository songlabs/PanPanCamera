import CoreImage
import Foundation

/// Bounding-box approximation only, replaceable without changing the pipeline.
/// The mask does not identify skin or exclude eyes, lips, eyebrows or facial hair.
struct SoftFaceMaskGenerator: FaceMaskGenerating {
    enum Failure: Error { case invalidImageExtent, filterUnavailable }

    func makeMask(regions: [FaceRegion], in extent: CGRect) throws -> CIImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !regions.isEmpty else { return nil }
        guard !extent.isEmpty, !extent.isInfinite, !extent.isNull,
              [extent.minX, extent.minY, extent.maxX, extent.maxY,
               extent.width, extent.height].allSatisfy(\.isFinite) else {
            throw Failure.invalidImageExtent
        }

        var combined: CIImage?
        for region in regions {
            let rect = region.imageRect(in: extent)
            // Subpixel boxes have no reliable face detail. Skip instead of enlarging
            // them or creating near-singular transforms. No CI filters on this path.
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { continue }
            let radiusY = rect.height * 0.48
            let radiusX = min(rect.width * 0.45, radiusY * 0.8)
            // Generate at image scale so CI never rasterizes a large reference
            // circle only to downsample it differently when a union is added.
            // Both colors are opaque: this is coverage, not source image alpha.
            guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0),
                "inputRadius0": radiusY * 0.65,
                "inputRadius1": radiusY,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            ]), let radial = gradient.outputImage else { throw Failure.filterUnavailable }
            // Radial output is black outside radius1. Transform before cropping so
            // there is no transparent rectangle edge to interpolate into the mask.
            let mask = radial.transformed(by: CGAffineTransform(a: radiusX / radiusY, b: 0,
                                                               c: 0, d: 1,
                                                               tx: rect.midX, ty: rect.midY))
                .cropped(to: extent)
                .insertingIntermediate()
                .samplingNearest()
            if let previous = combined {
                guard let union = CIFilter(name: "CIMaximumCompositing", parameters: [
                    kCIInputImageKey: mask,
                    kCIInputBackgroundImageKey: previous
                ]), let output = union.outputImage else { throw Failure.filterUnavailable }
                // max(a,b), not sum or source-over: even feather overlaps cannot
                // strengthen the adjustment. Values stay in 0...1, alpha stays 1.
                combined = output.cropped(to: extent)
            } else {
                combined = mask
            }
        }
        return combined
    }
}
