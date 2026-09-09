#if DEBUG
import CoreImage
import Foundation

/// DEVELOPMENT / TEST ONLY. Geometry fixtures, never image/color inspection,
/// detection, model inference or actual facial-feature measurements.
struct MockSkinMaskProvider: SkinMaskProviding {
    struct Configuration: Sendable {
        enum Mode: CaseIterable, Sendable { case normalSkin, hairExclusion, glassesOcclusion, beardReducedWeight, unavailable }
        enum Failure: Error { case invalidWeight, invalidFeather, invalidOcclusion }
        let mode: Mode
        let beardWeight: Double
        /// Fraction of face's shorter side; positive to keep every boundary soft.
        let featherFraction: CGFloat
        /// Uses the existing face-local normalized bottom-left landmark convention.
        let nonSkinOcclusion: CGRect?

        init(mode: Mode = .normalSkin, beardWeight: Double = Policy.beardWeight,
             featherFraction: CGFloat = Policy.featherFraction, nonSkinOcclusion: CGRect? = nil) throws {
            guard beardWeight.isFinite, (0...1).contains(beardWeight) else { throw Failure.invalidWeight }
            guard featherFraction.isFinite, (0.001...0.1).contains(featherFraction) else { throw Failure.invalidFeather }
            if let rect = nonSkinOcclusion {
                guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
                      rect.width > 0, rect.height > 0, rect.minX >= 0, rect.minY >= 0,
                      rect.maxX <= 1, rect.maxY <= 1 else { throw Failure.invalidOcclusion }
            }
            self.mode = mode
            self.beardWeight = beardWeight
            self.featherFraction = featherFraction
            self.nonSkinOcclusion = nonSkinOcclusion
        }

        static let normal = try! Self()
    }

    /// All synthetic defaults live here, not in SkinRetouchConfiguration.
    /// Engineering starting values only; no visual acceptance claim.
    enum Policy {
        static let beardWeight = 0.25
        static let featherFraction: CGFloat = 0.015
        static let normalHairBoundary: CGFloat = 0.88
        static let excludedHairBoundary: CGFloat = 0.72
        static let beardBoundary: CGFloat = 0.40
        static let glasses = CGRect(x: 0.12, y: 0.56, width: 0.76, height: 0.17)
        static let outer = CGRect(x: 0.02, y: 0.01, width: 0.96, height: 0.98)
        static let eyes = [CGRect(x: 0.18, y: 0.57, width: 0.24, height: 0.14),
                           CGRect(x: 0.58, y: 0.57, width: 0.24, height: 0.14)]
        static let lips = CGRect(x: 0.32, y: 0.23, width: 0.36, height: 0.13)
        static let eyeReduction = 0.85
        static let lipReduction = 0.80
    }

    /// Per-face overrides bind to regions, allowing mixed success in one photo.
    struct FaceConfiguration: Sendable {
        let region: FaceRegion
        let configuration: Configuration
    }

    let configuration: Configuration
    let faces: [FaceConfiguration]

    init(configuration: Configuration = .normal, faces: [FaceConfiguration] = []) {
        self.configuration = configuration
        self.faces = faces
    }

    func skinMask(in image: ProcessingImage, region: FaceRegion,
                  landmarks: FacialLandmarks?) throws -> SkinMaskResult {
        // Only dimensions are read. Even supplied landmarks are deliberately unused.
        try makeMask(region: region, in: CGRect(x: 0, y: 0, width: CGFloat(image.cgImage.width), height: CGFloat(image.cgImage.height)))
    }

    /// Exposes the same geometry graph for nonzero-extent Apple fixtures.
    func makeMask(region: FaceRegion, in extent: CGRect) throws -> SkinMaskResult {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try SkinMaskResult.validate(extent)
        let config = faces.first { $0.region == region }?.configuration ?? configuration
        let rect = region.imageRect(in: extent)
        guard config.mode != .unavailable, rect.width >= 1, rect.height >= 1 else { return .unavailable(for: region) }
        let feather = min(rect.width, rect.height) * config.featherFraction
        func mapped(_ local: CGRect) -> CGRect {
            CGRect(x: rect.minX + local.minX * rect.width, y: rect.minY + local.minY * rect.height,
                   width: local.width * rect.width, height: local.height * rect.height)
        }
        var skin = try ellipse(mapped(Policy.outer), feather: feather, in: extent)
        let hair = config.mode == .hairExclusion ? Policy.excludedHairBoundary : Policy.normalHairBoundary
        let hairY = rect.minY + hair * rect.height
        skin = try multiply(skin, ramp(from: CGPoint(x: rect.midX, y: hairY + feather),
                                       to: CGPoint(x: rect.midX, y: hairY - feather), in: extent))
        for eye in Policy.eyes {
            let allowed = try CoreImageRendering.grayMask(ellipse(mapped(eye), feather: feather, in: extent),
                                                          scale: -Policy.eyeReduction, bias: 1)
            skin = try multiply(skin, allowed)
        }
        let lips = try CoreImageRendering.grayMask(ellipse(mapped(Policy.lips), feather: feather, in: extent),
                                                   scale: -Policy.lipReduction, bias: 1)
        skin = try multiply(skin, lips)
        if config.mode == .beardReducedWeight {
            let beardY = rect.minY + Policy.beardBoundary * rect.height
            let transition = try ramp(from: CGPoint(x: rect.midX, y: beardY - feather),
                                      to: CGPoint(x: rect.midX, y: beardY + feather), in: extent)
            skin = try multiply(skin, CoreImageRendering.grayMask(transition,
                scale: 1 - config.beardWeight, bias: config.beardWeight))
        }
        if let occlusion = config.nonSkinOcclusion ?? (config.mode == .glassesOcclusion ? Policy.glasses : nil) {
            let exclusion = try softRectangle(mapped(occlusion), feather: feather, in: extent)
            skin = try multiply(skin, CoreImageRendering.grayMask(exclusion, scale: -1, bias: 1))
        }
        return try SkinMaskResult(region: region, mask: skin, in: extent)
    }

    private func ellipse(_ rect: CGRect, feather: CGFloat, in extent: CGRect) throws -> CIImage {
        let radius = rect.height / 2
        let innerRadius = max(0, radius * (1 - 2 * feather / min(rect.width, rect.height)))
        // Keep the gradient in image pixels. A fixed 100-unit reference scaled
        // down to a one-pixel feature can require an enormous intermediate ROI.
        guard let filter = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": innerRadius, "inputRadius1": radius,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0)
        ]), let radial = filter.outputImage else { throw CoreImageRendering.Failure.filterUnavailable }
        return radial.transformed(by: CGAffineTransform(a: rect.width / rect.height, b: 0, c: 0, d: 1,
                                                        tx: rect.midX, ty: rect.midY)).cropped(to: extent)
            .insertingIntermediate()
    }

    private func ramp(from start: CGPoint, to end: CGPoint, in extent: CGRect) throws -> CIImage {
        try CoreImageRendering.filter("CISmoothLinearGradient", parameters: [
            "inputPoint0": CIVector(cgPoint: start), "inputPoint1": CIVector(cgPoint: end),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1)
        ], in: extent)
    }

    private func softRectangle(_ rect: CGRect, feather: CGFloat, in extent: CGRect) throws -> CIImage {
        // Inner plateau is exactly 1. Inversion gives a zero-weight occluder with
        // a continuous outward transition. Cap feather so thin rectangles keep it.
        let f = min(feather, min(rect.width, rect.height) / 4)
        let left = try ramp(from: CGPoint(x: rect.minX - f, y: rect.midY), to: CGPoint(x: rect.minX + f, y: rect.midY), in: extent)
        let right = try ramp(from: CGPoint(x: rect.maxX + f, y: rect.midY), to: CGPoint(x: rect.maxX - f, y: rect.midY), in: extent)
        let bottom = try ramp(from: CGPoint(x: rect.midX, y: rect.minY - f), to: CGPoint(x: rect.midX, y: rect.minY + f), in: extent)
        let top = try ramp(from: CGPoint(x: rect.midX, y: rect.maxY + f), to: CGPoint(x: rect.midX, y: rect.maxY - f), in: extent)
        return try multiply(multiply(left, right), multiply(bottom, top))
    }

    private func multiply(_ a: CIImage, _ b: CIImage) throws -> CIImage {
        try CoreImageRendering.filter("CIMultiplyCompositing", parameters: [
            kCIInputImageKey: a, kCIInputBackgroundImageKey: b
        ], in: a.extent)
    }
}
#endif
