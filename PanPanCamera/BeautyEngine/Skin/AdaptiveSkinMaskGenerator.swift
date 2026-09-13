import CoreImage
import Foundation

struct SkinMaskResult {
    let mask: CIImage
    let instances: [UUID: CIImage]
}

/// Builds exactly one original-source mask graph per frame. Color sampling is
/// bounded to three 6x6 patches per face; photo-sized pixels are classified on GPU.
struct AdaptiveSkinMaskGenerator {
    enum Failure: Error { case invalidExtent }
    struct Policy: Sendable {
        // Adjustable starting points. Device FPS/quality/thermal tuning is pending.
        var previewMaximumDimension: CGFloat = 320
        var finalMaximumDimension: CGFloat = 768
    }
    let policy: Policy
    init(policy: Policy = Policy()) { self.policy = policy }

    static func validate(_ extent: CGRect) throws {
        guard !extent.isNull, !extent.isInfinite, !extent.isEmpty,
              [extent.minX, extent.minY, extent.width, extent.height].allSatisfy(\.isFinite)
        else { throw Failure.invalidExtent }
    }

    func makeMask(source: CIImage, faces: [AnalyzedFace], quality: BeautyProcessingQuality) throws -> SkinMaskResult? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try Self.validate(source.extent)
        let limit = quality == .preview ? policy.previewMaximumDimension : policy.finalMaximumDimension
        guard limit.isFinite, limit >= 32 else { throw Failure.invalidExtent }
        let extent = source.extent
        let scale = min(1, limit / max(extent.width, extent.height))
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                           tx: -extent.minX * scale, ty: -extent.minY * scale)
        let work = source.transformed(by: transform)
        let workExtent = work.extent
        let black = CIImage(color: .black).cropped(to: workExtent)
        var instances: [UUID: CIImage] = [:]
        var union = black
        let protection = try FeatureProtectionMaskGenerator().makeMask(faces: faces, in: workExtent) ?? black
        let regions = faces.compactMap { try? FaceRegion(boundingBox: $0.boundingBox.intersection(Self.unit)) }
        guard let frequency = SkinRetouchScale(regions: regions, in: workExtent) else { return nil }
        let detail = try DetailProtectionMaskGenerator().makeMask(source: work, scale: frequency)
        let protected = try maximum(protection, detail)
        let allowed = try CoreImageRendering.grayMask(protected, scale: -1, bias: 1)
        // Put encoded sRGB values into the linear working-space channels before
        // the LUT. Uniform encoded spacing preserves precision for dark complexions.
        // The cube emits scalar linear coverage, so no inverse tone curve follows.
        let encoded = try CoreImageRendering.filter("CILinearToSRGBToneCurve", parameters: [
            kCIInputImageKey: work
        ], in: workExtent)
        for face in faces {
            guard let roi = SkinFaceROI(face: face) else { continue }
            let samples = CoreImageRendering.skinSamples(work, centers: roi.sampleCenters, side: roi.sampleSide)
            guard let classifier = AdaptiveSkinColor(samples: samples) else { continue }
            var cube = [Float](repeating: 1, count: Self.cubeSamples.count * 4)
            for (index, sample) in Self.cubeSamples.enumerated() {
                let weight = Float(classifier.weight(sample))
                cube[index * 4] = weight
                cube[index * 4 + 1] = weight
                cube[index * 4 + 2] = weight
            }
            let data = cube.withUnsafeBytes { Data($0) }
            let classified = try CoreImageRendering.filter("CIColorCubeWithColorSpace", parameters: [
                kCIInputImageKey: encoded, "inputCubeDimension": Self.cubeDimension,
                "inputCubeData": data,
                "inputColorSpace": CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            ], in: workExtent)
            let box = CGRect(x: roi.bounds.minX * workExtent.width, y: roi.bounds.minY * workExtent.height,
                             width: roi.bounds.width * workExtent.width, height: roi.bounds.height * workExtent.height)
            // A search ROI can only remove classified pixels; it never enables skin.
            let support = classified.cropped(to: box).composited(over: black).cropped(to: workExtent)
            let feathered = try LocalSkinCorrection.blur(support, radius: max(0.7, CGFloat(frequency.smallRadius)))
            let inward = try LocalSkinCorrection.multiply(support, feathered)
            let effective = try LocalSkinCorrection.multiply(inward, allowed)
            let full = effective.transformed(by: transform.inverted()).cropped(to: extent)
            instances[face.trackingID] = full
            union = try maximum(union, effective)
        }
        guard !instances.isEmpty else { return nil }
        return SkinMaskResult(mask: union.transformed(by: transform.inverted()).cropped(to: extent), instances: instances)
    }

    private func maximum(_ a: CIImage, _ b: CIImage) throws -> CIImage {
        try CoreImageRendering.filter("CIMaximumCompositing", parameters: [
            kCIInputImageKey: a, kCIInputBackgroundImageKey: b
        ], in: a.extent)
    }

    private static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    private static let cubeDimension = 32
    // Red varies fastest, then green, then blue (Apple color cube layout).
    // Shared immutable color-space conversion table, not a per-frame pixel scan.
    private static let cubeSamples: [AdaptiveSkinColor.Sample] = (0..<cubeDimension * cubeDimension * cubeDimension).map { index in
        let n = cubeDimension, denominator = Double(n - 1)
        return AdaptiveSkinColor.Sample(sRGB: [Double(index % n) / denominator,
            Double((index / n) % n) / denominator, Double(index / (n * n)) / denominator])
    }
}
