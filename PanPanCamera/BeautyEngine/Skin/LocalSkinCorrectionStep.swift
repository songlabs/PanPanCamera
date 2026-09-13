import CoreImage
import Foundation

/// Local, non-generative corrections. All graphs use the existing renderer context.
/// Detection/reference images are bounded; the original full-resolution texture is
/// retained by adding a bounded low/mid-frequency delta, never a blurred final face.
enum LocalSkinCorrection {
    static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    static func blur(_ image: CIImage, radius: CGFloat) throws -> CIImage {
        try CoreImageRendering.filter("CIGaussianBlur", parameters: [
            kCIInputImageKey: image.clampedToExtent(), kCIInputRadiusKey: radius
        ], in: image.extent)
    }

    static func analysisScale(_ extent: CGRect, quality: BeautyProcessingQuality) -> CGFloat {
        min(1, (quality == .preview ? 640 : 1280) / max(extent.width, extent.height))
    }

    static func multiply(_ a: CIImage, _ b: CIImage) throws -> CIImage {
        try CoreImageRendering.filter("CIMultiplyCompositing", parameters: [
            kCIInputImageKey: a, kCIInputBackgroundImageKey: b
        ], in: a.extent)
    }

}

struct BlemishAttenuationStep: Sendable {
    func makeOutput(source: CIImage, regions: [FaceRegion], landmarks: [FaceLandmarks],
                    effectiveSkinMask: CIImage, strength: Double,
                    quality: BeautyProcessingQuality) throws -> CIImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let strength = LocalSkinCorrection.unit(strength)
        guard strength > 0 else { return nil }
        guard let side = regions.map({ min($0.imageRect(in: source.extent).width,
                                           $0.imageRect(in: source.extent).height) }).min() else { return nil }
        let scale = LocalSkinCorrection.analysisScale(source.extent, quality: quality)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let analysis = source.transformed(by: transform)
        let radius = max(1.5, min(18, side * scale * 0.018))
        let small = try LocalSkinCorrection.blur(analysis, radius: max(0.5, radius * 0.18))
        let reference = try LocalSkinCorrection.blur(analysis, radius: radius)
        let allowed = effectiveSkinMask
        guard let detector = Self.detector,
              let candidates = detector.apply(extent: analysis.extent,
                arguments: [small, reference, allowed.transformed(by: transform)])
        else { throw CoreImageRendering.Failure.filterUnavailable }
        let feathered = try LocalSkinCorrection.blur(candidates, radius: max(0.5, radius * 0.20))
            .transformed(by: transform.inverted()).cropped(to: source.extent)
        // Reapply exclusion AFTER feather/upsampling so it cannot leak into features.
        let mask = try LocalSkinCorrection.multiply(feathered, allowed)
        guard let repair = Self.repair,
              let adjusted = repair.apply(extent: source.extent, arguments: [
                source, small.transformed(by: transform.inverted()),
                reference.transformed(by: transform.inverted())
              ]) else { throw CoreImageRendering.Failure.filterUnavailable }
        return try CoreImageRendering.blend(adjusted, over: source,
            mask: CoreImageRendering.grayMask(mask, scale: strength * 0.75))
    }

    // Relative redness, NOT an absolute skin-color threshold: neutral/brown moles,
    // freckles, dark hair and broad illumination changes are deliberately rejected.
    // This conservative heuristic cannot classify temporary vs permanent marks.
    private static let detector = CIColorKernel(source: """
        kernel vec4 blemishCandidates(__sample small, __sample reference, __sample allowed) {
            vec3 s = unpremultiply(small).rgb;
            vec3 r = unpremultiply(reference).rgb;
            vec3 luma = vec3(0.2126, 0.7152, 0.0722);
            vec3 delta = s - r;
            float redExcess = delta.r - 0.5 * (delta.g + delta.b);
            float darkness = max(0.0, dot(r - s, luma)) / max(0.04, dot(r, luma));
            float red = smoothstep(0.012, 0.045, redExcess);
            float contrast = smoothstep(0.012, 0.04, length(delta));
            float preserveDarkMarks = 1.0 - smoothstep(0.28, 0.55, darkness);
            // Allow half-float blur accumulation error; output preserves source alpha.
            float opaque = step(0.99, small.a) * step(0.99, reference.a);
            float m = red * contrast * preserveDarkMarks * allowed.r * opaque;
            return vec4(m, m, m, 1.0);
        }
        """)

    private static let repair = CIColorKernel(source: """
        kernel vec4 attenuateBlemish(__sample original, __sample small, __sample reference) {
            vec3 o = unpremultiply(original).rgb;
            vec3 delta = unpremultiply(reference).rgb - unpremultiply(small).rgb;
            delta = clamp(delta, vec3(-0.10), vec3(0.10));
            return premultiply(vec4(o + delta * step(0.999, original.a), original.a));
        }
        """)
}

/// Eye-local frame in already oriented/mirrored CI pixels. Its entire elliptical
/// support lies beyond the lowest eye-polygon projection, with a 2%-eye-width gap.
struct UnderEyeRegion: Equatable, Sendable {
    let center: CGPoint
    let along: CGVector
    let down: CGVector
    let width: CGFloat

    var radiusX: CGFloat { width * 0.52 }
    var radiusY: CGFloat { width * 0.22 }
    var referenceOffset: CGVector { CGVector(dx: down.dx * width * 0.55, dy: down.dy * width * 0.55) }

    static func make(landmarks: FaceLandmarks, eye: FacialLandmarkRegion,
                     in extent: CGRect) -> Self? {
        let points = landmarks.imagePoints(for: eye, in: extent)
        guard points.count >= 3 else { return nil }
        var a = points[0], b = points[1], longest: CGFloat = 0
        for i in points.indices {
            for j in points.indices where j > i {
                let distance = hypot(points[j].x - points[i].x, points[j].y - points[i].y)
                if distance > longest { a = points[i]; b = points[j]; longest = distance }
            }
        }
        guard longest >= 4 else { return nil }
        if a.x > b.x { swap(&a, &b) }
        let along = CGVector(dx: (b.x - a.x) / longest, dy: (b.y - a.y) / longest)
        var down = CGVector(dx: along.dy, dy: -along.dx)
        let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let brow = landmarks.imagePoints(for: eye == .leftEye ? .leftEyebrow : .rightEyebrow, in: extent)
        if !brow.isEmpty {
            let browCenter = CGPoint(x: brow.map(\.x).reduce(0, +) / CGFloat(brow.count),
                                     y: brow.map(\.y).reduce(0, +) / CGFloat(brow.count))
            if (middle.x - browCenter.x) * down.dx + (middle.y - browCenter.y) * down.dy < 0 {
                down = CGVector(dx: -down.dx, dy: -down.dy)
            }
        }
        let lower = points.map { ($0.x - middle.x) * down.dx + ($0.y - middle.y) * down.dy }.max() ?? 0
        return Self(center: CGPoint(x: middle.x + down.dx * (lower + longest * 0.24),
                                    y: middle.y + down.dy * (lower + longest * 0.24)),
                    along: along, down: down, width: longest)
    }

    func makeMask(in extent: CGRect) throws -> CIImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let radial = try CoreImageRendering.filter("CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": 0.25, "inputRadius1": 1.0,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0)
        ], in: CGRect(x: -2, y: -2, width: 4, height: 4))
        let ellipse = radial.transformed(by: CGAffineTransform(
            a: along.dx * radiusX, b: along.dy * radiusX,
            c: down.dx * radiusY, d: down.dy * radiusY, tx: center.x, ty: center.y))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        return ellipse.composited(over: black).cropped(to: extent)
    }
}

struct DarkCircleCorrectionStep: Sendable {
    func makeOutput(source: CIImage, regions: [FaceRegion], landmarks: [FaceLandmarks],
                    effectiveSkinMask: CIImage, strength: Double,
                    quality: BeautyProcessingQuality) throws -> CIImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let strength = LocalSkinCorrection.unit(strength)
        guard strength > 0 else { return nil }
        var output: CIImage?
        var used: [UnderEyeRegion] = []
        let scale = LocalSkinCorrection.analysisScale(source.extent, quality: quality)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let analysis = source.transformed(by: transform)
        for face in landmarks {
            for eye in [FacialLandmarkRegion.leftEye, .rightEye] {
                guard let area = UnderEyeRegion.make(landmarks: face, eye: eye, in: source.extent),
                      !used.contains(area)
                else { continue }
                used.append(area)
                let allowed = effectiveSkinMask
                let referenceTransform = CGAffineTransform(
                    translationX: -area.referenceOffset.dx, y: -area.referenceOffset.dy)
                let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: source.extent)
                let referenceCoverage = allowed.transformed(by: referenceTransform)
                    .composited(over: black).cropped(to: source.extent)
                let mask = try LocalSkinCorrection.multiply(
                    LocalSkinCorrection.multiply(area.makeMask(in: source.extent), allowed), referenceCoverage)
                let low = try LocalSkinCorrection.blur(analysis, radius: max(0.7, area.width * scale * 0.12))
                    .transformed(by: transform.inverted()).cropped(to: source.extent)
                // Translation samples lower cheek skin in the same rotated eye frame.
                let reference = low.clampedToExtent().transformed(by: referenceTransform)
                    .cropped(to: source.extent)
                guard let correction = Self.correction,
                      let adjusted = correction.apply(extent: source.extent, arguments: [source, low, reference])
                else { throw CoreImageRendering.Failure.filterUnavailable }
                // Reference and delta always use the immutable stage input. Overlapping
                // detections cannot repeatedly brighten the same pixel.
                output = try CoreImageRendering.blend(adjusted, over: output ?? source,
                    mask: CoreImageRendering.grayMask(mask, scale: strength))
            }
        }
        return output?.cropped(to: source.extent)
    }

    private static let correction = CIColorKernel(source: """
        kernel vec4 correctDarkCircle(__sample original, __sample low, __sample reference) {
            vec3 o = unpremultiply(original).rgb;
            vec3 s = unpremultiply(low).rgb;
            vec3 r = unpremultiply(reference).rgb;
            vec3 luma = vec3(0.2126, 0.7152, 0.0722);
            float y = dot(s, luma);
            float referenceY = dot(r, luma);
            float deficit = max(0.0, referenceY - y);
            // At most half the measured shadow deficit, and 0.055 linear luminance.
            // No fixed target color and no geometry: real under-eye structure remains.
            float lift = min(0.055, deficit * 0.50);
            float gate = smoothstep(0.006, 0.035, deficit);
            vec3 chroma = (r - vec3(referenceY)) - (s - vec3(y));
            chroma = clamp(chroma * 0.20, vec3(-0.012), vec3(0.012));
            chroma -= vec3(dot(chroma, luma));
            vec3 delta = (vec3(lift) + chroma) * gate;
            float opaque = step(0.999, original.a) * step(0.99, low.a) * step(0.99, reference.a);
            return premultiply(vec4(o + delta * opaque, original.a));
        }
        """)
}
