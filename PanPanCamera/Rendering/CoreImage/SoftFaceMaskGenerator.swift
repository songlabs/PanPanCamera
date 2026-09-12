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
            // Use a 100-unit reference circle, then scale to a portrait ellipse.
            // Both colors are opaque: this is coverage, not source image alpha.
            guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0),
                "inputRadius0": 65.0,
                "inputRadius1": 100.0,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            ]), let radial = gradient.outputImage else { throw Failure.filterUnavailable }
            // Radial output is black outside radius1. Transform before cropping so
            // there is no transparent rectangle edge to interpolate into the mask.
            let mask = radial.transformed(by: CGAffineTransform(a: radiusX / 100, b: 0,
                                                               c: 0, d: radiusY / 100,
                                                               tx: rect.midX, ty: rect.midY))
                .cropped(to: extent)
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

/// Production, image-aware skin selection inside the independent beauty ROI.
/// It combines luminance, chroma, channel dominance and saturation confidence;
/// no single RGB/HSV threshold can enable a pixel. A conservative forehead prior
/// restores central forehead coverage while its upper fade protects the hairline.
struct BeautySkinMaskGenerator: Sendable {
    enum Failure: Error { case filterUnavailable }

    func makeMasks(source: CIImage, regions: [FaceRegion]) throws -> [SkinMaskResult] {
        guard let classifier = Self.classifier else { throw Failure.filterUnavailable }
        let extent = source.extent
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        var results: [SkinMaskResult] = []
        for region in regions {
            let roi = region.imageRect(in: extent)
            guard roi.width >= 1, roi.height >= 1,
                  let face = try SoftFaceMaskGenerator().makeMask(regions: [region], in: extent) else { continue }
            guard let classified = classifier.apply(extent: extent, arguments: [source]) else {
                throw Failure.filterUnavailable
            }
            let semantic = try CoreImageRendering.filter("CIMultiplyCompositing", parameters: [
                kCIInputImageKey: classified, kCIInputBackgroundImageKey: face
            ], in: extent)
            let forehead = try foreheadMask(roi: roi, extent: extent)
            let union = try CoreImageRendering.filter("CIMaximumCompositing", parameters: [
                kCIInputImageKey: semantic, kCIInputBackgroundImageKey: forehead
            ], in: extent)
            // A small final feather is shared by smoothing, brightening and tone.
            let feathered = try CoreImageRendering.filter("CIGaussianBlur", parameters: [
                kCIInputImageKey: union.composited(over: black),
                kCIInputRadiusKey: max(1, min(roi.width, roi.height) * 0.008)
            ], in: extent)
            results.append(try SkinMaskResult(region: region, mask: feathered, in: extent))
        }
        return results
    }

    private func foreheadMask(roi: CGRect, extent: CGRect) throws -> CIImage {
        // The ROI top is 15% above Vision's face box. Keep the prior below that
        // added band: this covers the forehead centre and fades before the hairline.
        guard let filter = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": 62.0,
            "inputRadius1": 100.0,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0)
        ]), let radial = filter.outputImage else { throw Failure.filterUnavailable }
        return radial.transformed(by: CGAffineTransform(a: roi.width * 0.34 / 100, b: 0,
            c: 0, d: roi.height * 0.18 / 100, tx: roi.midX, ty: roi.minY + roi.height * 0.70))
            .cropped(to: extent)
    }

    private static let classifier = CIColorKernel(source: """
        kernel vec4 beautySkin(__sample p) {
            vec3 c = unpremultiply(p).rgb;
            float hi = max(c.r, max(c.g, c.b));
            float lo = min(c.r, min(c.g, c.b));
            float chroma = hi - lo;
            float y = dot(c, vec3(0.299, 0.587, 0.114));
            float warm = c.r - c.b;
            float greenBalance = c.r - c.g;
            float exposure = smoothstep(0.06, 0.20, y) * (1.0 - smoothstep(0.92, 1.0, y));
            float hueFamily = smoothstep(-0.035, 0.035, warm) *
                              (1.0 - smoothstep(0.30, 0.52, warm)) *
                              (1.0 - smoothstep(0.22, 0.42, abs(greenBalance)));
            float colorfulness = smoothstep(0.018, 0.075, chroma) *
                                 (1.0 - smoothstep(0.62, 0.88, chroma));
            float confidence = exposure * hueFamily * mix(0.58, 1.0, colorfulness);
            confidence *= step(0.001, p.a);
            return vec4(vec3(clamp(confidence, 0.0, 1.0)), 1.0);
        }
        """)
}
