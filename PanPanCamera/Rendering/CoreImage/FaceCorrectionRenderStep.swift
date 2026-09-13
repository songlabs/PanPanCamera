import CoreImage
import Foundation

final class FaceCorrectionPreviewStep: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedWarps: [FaceCorrectionWarp] = []
    private var cachedExtent = CGRect.null
    private var cachedMap: CIImage?
    private var cachedScale: CGFloat = 0
    func makeOutput(source: CIImage, warps: [FaceCorrectionWarp]) throws -> CIImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !warps.isEmpty else {
            clearCache()
            return nil
        }
        let (displacement, scale) = try displacementMap(for: warps, extent: source.extent)
        guard let kernel = Self.vectorDisplacement,
              let output = kernel.apply(extent: source.extent, roiCallback: { index, rect in
                  // RG is bounded to 0...1, so each source-coordinate component
                  // can move by at most scale / 2. Include interpolation support.
                  index == 0 ? rect.insetBy(dx: -scale / 2 - 1, dy: -scale / 2 - 1) : rect
              }, arguments: [source.clampedToExtent(), displacement, scale]) else {
            throw CoreImageRendering.Failure.filterUnavailable
        }
        return output.cropped(to: source.extent)
    }

    // Internal so Apple pixel tests can inspect the actual cached production map.
    func displacementMap(for warps: [FaceCorrectionWarp],
                         extent: CGRect) throws -> (image: CIImage, scale: CGFloat) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        lock.lock()
        defer { lock.unlock() }
        if warps == cachedWarps, extent == cachedExtent,
           let cachedMap, cachedScale > 0 { return (cachedMap, cachedScale) }

        let largest = warps.map { hypot($0.visibleOffset.dx, $0.visibleOffset.dy) }.max() ?? 0
        guard largest > 0 else { throw AdaptiveSkinMaskGenerator.Failure.invalidExtent }

        // Encode inverse sampling offsets: R = X, G = Y, 0.5 = zero.
        // The matching kernel decodes these values into CI pixels exactly once.
        // Overlapping effects contribute vectors, not opaque layers. Bound the
        // sum so RG stays in 0...1 without clipping or normalizing strength again.
        let slim = warps.filter(\.isSlim)
        let slimBound = stride(from: 0, to: slim.count, by: 12).reduce(CGFloat.zero) { total, offset in
            total + (slim[offset..<min(offset + 12, slim.count)].map { abs($0.visibleOffset.dx) }.max() ?? 0)
        }
        let scale = max(1, 2 * (slimBound + warps.filter { !$0.isSlim }.reduce(CGFloat.zero) {
            $0 + hypot($1.visibleOffset.dx, $1.visibleOffset.dy)
        }))
        // Create encoded values through CIColorMatrix arithmetic so 0.5 stays neutral
        // in the renderer's linear working space instead of passing through color conversion.
        var displacement = try CoreImageRendering.filter("CIColorMatrix", parameters: [
            kCIInputImageKey: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)),
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0.5, y: 0.5, z: 0, w: 1)
        ], in: extent)
        // All twelve slim regions are evaluated together in ONE map kernel. Their
        // overlap is normalized only within Slim; other controls retain their sum.
        for offset in stride(from: 0, to: slim.count, by: 12) {
            let group = Array(slim[offset..<min(offset + 12, slim.count)])
            guard let kernel = Self.slimDisplacement else {
                throw CoreImageRendering.Failure.filterUnavailable
            }
            var arguments: [Any] = [displacement]
            for index in 0..<12 {
                if index < group.count {
                    let warp = group[index]
                    arguments.append(CIVector(x: warp.center.x, y: warp.center.y,
                                              z: warp.radius, w: -warp.visibleOffset.dx / scale))
                } else {
                    arguments.append(CIVector(x: 0, y: 0, z: 0, w: 0))
                }
            }
            guard let combined = kernel.apply(extent: extent,
                roiCallback: { _, rect in rect }, arguments: arguments) else {
                throw CoreImageRendering.Failure.filterUnavailable
            }
            displacement = combined
        }
        for warp in warps where !warp.isSlim {
            let falloff = try CoreImageRendering.filter("CIRadialGradient", parameters: [
                "inputCenter": CIVector(cgPoint: warp.center),
                "inputRadius0": warp.radius * 0.30,
                "inputRadius1": warp.radius,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            ], in: extent)
            guard let kernel = Self.accumulateDisplacement,
                  let accumulated = kernel.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: [
                    displacement, falloff,
                    CIVector(x: -warp.visibleOffset.dx / scale, y: -warp.visibleOffset.dy / scale)
                  ]) else { throw CoreImageRendering.Failure.filterUnavailable }
            displacement = accumulated
        }
        cachedWarps = warps
        cachedExtent = extent
        cachedMap = displacement
        cachedScale = scale
        return (displacement, scale)
    }

    // Generated once: the legacy CI language has no array parameters. Unrolling a
    // fixed twelve-element field avoids twelve gradient/filter graphs per frame.
    // Cubic smoothstep has zero slope at both ends. sqrt(1 + sumW^2) preserves
    // the zero-valued edge and bounds overlap without max(1, sumW)'s derivative
    // corner, which made overlapping outer supports too steep at full strength.
    private static let slimDisplacement: CIKernel? = {
        let parameters = (0..<12).map { "vec4 c\($0)" }.joined(separator: ", ")
        let contributions = (0..<12).map { index in
            """
            float t\(index) = clamp(distance(p, c\(index).xy) / max(1.0, c\(index).z), 0.0, 1.0);
            float w\(index) = (1.0 - t\(index) * t\(index) * (3.0 - 2.0 * t\(index))) * step(0.5, c\(index).z);
            total += w\(index);
            delta += w\(index) * c\(index).w;
            """
        }.joined(separator: "\n")
        return CIKernel(source: """
            kernel vec4 continuousSlimField(sampler base, \(parameters)) {
                vec2 p = destCoord();
                float total = 0.0;
                float delta = 0.0;
                \(contributions)
                vec2 value = sample(base, samplerTransform(base, p)).rg;
                return vec4(value + vec2(delta / sqrt(1.0 + total * total), 0.0), 0.0, 1.0);
            }
            """)
    }()

    // Source-over previously erased earlier effects wherever a later radial
    // field had alpha 1 (in particular Chin over Slim). Add only the weighted
    // signed delta; retain the single neutral bias and opaque map alpha.
    private static let accumulateDisplacement = CIKernel(source: """
        kernel vec4 accumulateFaceDisplacement(sampler accumulated, sampler falloff, vec2 offset) {
            vec2 p = destCoord();
            vec2 value = sample(accumulated, samplerTransform(accumulated, p)).rg;
            float weight = sample(falloff, samplerTransform(falloff, p)).a;
            return vec4(value + weight * offset, 0.0, 1.0);
        }
        """)

    // CIDisplacementDistortion accepts a grayscale texture, not our RG vector
    // contract. Decode explicitly instead of assuming its inputScale implements
    // (RG - 0.5) * scale. samplerTransform converts CI pixels to sampler space;
    // there is no division by image width/height or second normalization.
    // Like the existing reconstruction kernel, this uses the legacy CI language
    // API; compilation and sampling are covered by Apple runtime tests.
    private static let vectorDisplacement = CIKernel(source: """
        kernel vec4 faceVectorDisplacement(sampler source, sampler displacement, float scale) {
            vec2 destination = destCoord();
            vec2 encoded = sample(displacement, samplerTransform(displacement, destination)).rg;
            vec2 sourcePosition = destination + (encoded - vec2(0.5)) * scale;
            return sample(source, samplerTransform(source, sourcePosition));
        }
        """)

    private func clearCache() {
        lock.lock()
        cachedWarps = []
        cachedExtent = .null
        cachedMap = nil
        cachedScale = 0
        lock.unlock()
    }
}
