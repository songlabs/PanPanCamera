import CoreImage
import Foundation

/// Uses the existing oriented image-relative Vision landmarks. Only geometry masks
/// are cached; source pixels and source-derived eyebrow detail never enter the cache.
/// Every layer blends into the preceding result, preserving skin processing beneath it.
final class MakeupProcessingStep: @unchecked Sendable {
    private enum Component: CaseIterable, Hashable { case lip, blush, eye, brow }
    private struct Shape {
        let path: CGPath
        let filled: Bool
        let expansion: CGFloat
    }
    private let lock = NSLock()
    private var cachedFaces: [DetectedFace] = []
    private var cachedExtent = CGRect.null
    private var cachedMasks: [Component: CIImage] = [:]
    private var cachedComponents: Set<Component> = []
    private var cachedBrows: [(mask: CIImage, side: CGFloat)] = []

    func makeOutput(source: CIImage, faces: [DetectedFace],
                    configuration: MakeupConfiguration) throws -> CIImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !configuration.isBypassed, !faces.isEmpty else { return nil }
        let extent = source.extent
        guard !extent.isEmpty, !extent.isInfinite, !extent.isNull,
              [extent.minX, extent.minY, extent.width, extent.height].allSatisfy(\.isFinite)
        else { throw CoreImageRendering.Failure.renderFailed }
        let strengths: [Component: Double] = [.lip: configuration.lip, .blush: configuration.blush,
                                             .eye: configuration.eye, .brow: configuration.brow]
        let active = Component.allCases.filter { LocalSkinCorrection.unit(strengths[$0] ?? 0) > 0 }
        let geometry = try geometryMasks(faces: faces, extent: extent, components: active)
        var output: CIImage?
        for component in active {
            guard var mask = geometry.masks[component] else { continue }
            let image = output ?? source
            if component == .brow {
                // Enhance existing dark hair relative to its neighborhood. A flat
                // skin patch inside a landmark stroke acquires no invented eyebrow.
                var weighted: CIImage?
                for brow in geometry.brows {
                    let reference = try LocalSkinCorrection.blur(source, radius: max(1, brow.side * 0.018))
                    guard let detail = Self.browDetail,
                          let weight = detail.apply(extent: extent, arguments: [source, reference])
                    else { throw CoreImageRendering.Failure.filterUnavailable }
                    weighted = try maximum(weighted, LocalSkinCorrection.multiply(brow.mask, weight), in: extent)
                }
                guard let weighted else { continue }
                mask = weighted
            }
            // Bounded multiplicative channel changes preserve the source's texture,
            // shading and alpha: no flat color fill or blurred final face. At 100%,
            // lip channel gains stay within 12%; blush within 7%; eye within 12%;
            // brow darkening within 22% and only on detected local hair contrast.
            // These are conservative engineering limits, pending real-face tuning.
            let gains: (CGFloat, CGFloat, CGFloat)
            switch component {
            case .lip: gains = (1.12, 0.88, 0.94)
            case .blush: gains = (1.07, 0.978, 0.995)
            case .eye: gains = (0.925, 0.895, 0.88)
            case .brow: gains = (0.78, 0.78, 0.78)
            }
            let adjusted = try CoreImageRendering.filter("CIColorMatrix", parameters: [
                kCIInputImageKey: image,
                "inputRVector": CIVector(x: gains.0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gains.1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gains.2, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ], in: extent)
            output = try CoreImageRendering.blend(adjusted, over: image,
                mask: CoreImageRendering.grayMask(mask,
                    scale: LocalSkinCorrection.unit(strengths[component] ?? 0)))
        }
        return output
    }

    private func geometryMasks(faces: [DetectedFace], extent: CGRect,
                               components: [Component]) throws ->
        (masks: [Component: CIImage], brows: [(mask: CIImage, side: CGFloat)]) {
        lock.lock(); defer { lock.unlock() }
        if faces != cachedFaces || extent != cachedExtent {
            cachedFaces = faces
            cachedExtent = extent
            cachedMasks = [:]
            cachedComponents = []
            cachedBrows = []
        }
        let missing = components.filter { !cachedComponents.contains($0) }
        // Same arithmetic and validity rules as faceMask; convert each landmark
        // once for all active components. Shapes/feathers stay component-specific.
        var converted: [[FacialLandmarkRegion: [CGPoint]]] = missing.isEmpty ? [] : faces.map { _ in [:] }
        for component in missing {
            var combined: CIImage?
            var brows: [(mask: CIImage, side: CGFloat)] = []
            for (index, face) in faces.enumerated() {
                guard let mask = try faceMask(face, component: component, extent: extent,
                                              convertedPoints: &converted[index]) else { continue }
                combined = try maximum(combined, mask, in: extent)
                if component == .brow {
                    brows.append((mask, min(face.boundingBox.width * extent.width,
                                            face.boundingBox.height * extent.height)))
                }
            }
            if component == .brow { cachedBrows = brows }
            cachedMasks[component] = combined
            cachedComponents.insert(component)
        }
        return (cachedMasks, cachedBrows)
    }

    private func faceMask(_ face: DetectedFace, component: Component, extent: CGRect,
                          convertedPoints: inout [FacialLandmarkRegion: [CGPoint]]) throws -> CIImage? {
        let side = min(face.boundingBox.width * extent.width, face.boundingBox.height * extent.height)
        guard side.isFinite, side >= 12, face.confidence.isFinite, face.confidence >= 0.5 else { return nil }
        func points(_ feature: FacialLandmarkRegion, minimum: Int = 3) -> [CGPoint]? {
            guard let values = face.landmarks[feature], values.count >= minimum,
                  values.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
                      (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return nil }
            if let converted = convertedPoints[feature] { return converted }
            let converted = values.map { CGPoint(x: extent.minX + $0.x * extent.width,
                                                y: extent.minY + $0.y * extent.height) }
            convertedPoints[feature] = converted
            return converted
        }
        func shape(_ values: [CGPoint], filled: Bool = true, expansion: CGFloat = 0) -> Shape {
            let path = CGMutablePath()
            path.addLines(between: values)
            if filled { path.closeSubpath() }
            return Shape(path: path, filled: filled, expansion: expansion)
        }
        switch component {
        case .lip:
            // Inner-lip geometry is required even for closed lips. Missing data
            // bypasses this layer instead of guessing where the oral cavity ends.
            guard let outer = points(.outerLips), let inner = points(.innerLips, minimum: 2),
                  polygonArea(outer) > side * side * 0.0001,
                  let lip = try rasterMask([shape(outer)], feather: side * 0.006,
                      inset: side * 0.012, extent: extent),
                  let mouth = try protection([shape(inner, filled: inner.count >= 3,
                      expansion: side * 0.006)], feather: side * 0.004, extent: extent)
            else { return nil }
            // Feather from an inset support, so clipping at the outer contour
            // removes only the near-zero tail instead of a 50%-coverage edge.
            guard let outerSupport = try rasterMask([shape(outer)], feather: 0, extent: extent) else { return nil }
            return try LocalSkinCorrection.multiply(
                LocalSkinCorrection.multiply(lip, outerSupport), inverse(mouth))
        case .eye:
            var combined: CIImage?
            for feature in [FacialLandmarkRegion.leftEye, .rightEye] {
                guard let eye = points(feature), polygonArea(eye) > 0,
                      let surround = try rasterMask([shape(eye, expansion: side * 0.030)],
                          feather: side * 0.012, extent: extent),
                      let eyeball = try protection([shape(eye, expansion: side * 0.008)],
                          feather: side * 0.005, extent: extent) else { continue }
                let ring = try LocalSkinCorrection.multiply(surround, inverse(eyeball))
                combined = try maximum(combined, ring, in: extent)
            }
            return combined
        case .brow:
            var combined: CIImage?
            for feature in [FacialLandmarkRegion.leftEyebrow, .rightEyebrow] {
                guard let brow = points(feature, minimum: 2),
                      let mask = try rasterMask([shape(brow, filled: false, expansion: side * 0.012)],
                          feather: side * 0.006, extent: extent) else { continue }
                combined = try maximum(combined, mask, in: extent)
            }
            // Explicitly remove eyes even if a partial-profile brow overlaps them.
            let eyes = [FacialLandmarkRegion.leftEye, .rightEye].compactMap { points($0) }
            guard let combined, eyes.count == 2,
                  let protected = try protection(eyes.map { shape($0, expansion: side * 0.008) },
                      feather: side * 0.005, extent: extent) else { return nil }
            return try LocalSkinCorrection.multiply(combined, inverse(protected))
        case .blush:
            guard let left = points(.leftEye), let right = points(.rightEye),
                  let nose = points(.nose, minimum: 2), let lips = points(.outerLips) else { return nil }
            let leftCenter = center(left), rightCenter = center(right), mouth = center(lips)
            let eyeCenter = CGPoint(x: (leftCenter.x + rightCenter.x) / 2,
                                    y: (leftCenter.y + rightCenter.y) / 2)
            let distance = hypot(rightCenter.x - leftCenter.x, rightCenter.y - leftCenter.y)
            guard distance >= side * 0.15 else { return nil }
            let along = CGVector(dx: (rightCenter.x - leftCenter.x) / distance,
                                 dy: (rightCenter.y - leftCenter.y) / distance)
            var down = CGVector(dx: along.dy, dy: -along.dx)
            if (mouth.x - eyeCenter.x) * down.dx + (mouth.y - eyeCenter.y) * down.dy < 0 {
                down = CGVector(dx: -down.dx, dy: -down.dy)
            }
            let cheekDrop = ((mouth.x - eyeCenter.x) * down.dx +
                             (mouth.y - eyeCenter.y) * down.dy) * 0.53
            guard cheekDrop > 0 else { return nil }
            var cheeks: CIImage?
            for eye in [leftCenter, rightCenter] {
                let cheek = CGPoint(x: eye.x + down.dx * cheekDrop,
                                    y: eye.y + down.dy * cheekDrop)
                let mask = try ellipse(center: cheek, along: along, down: down,
                    radiusX: min(side * 0.20, distance * 0.43), radiusY: side * 0.13, extent: extent)
                cheeks = try maximum(cheeks, mask, in: extent)
            }
            let exclusions = [shape(left, expansion: side * 0.018),
                              shape(right, expansion: side * 0.018),
                              shape(nose, expansion: side * 0.035),
                              shape(lips, expansion: side * 0.020)]
            guard let cheeks,
                  let protected = try protection(exclusions, feather: side * 0.009, extent: extent)
            else { return nil }
            return try LocalSkinCorrection.multiply(cheeks, inverse(protected))
        }
    }

    private func protection(_ shapes: [Shape], feather: CGFloat, extent: CGRect) throws -> CIImage? {
        guard let hard = try rasterMask(shapes, feather: 0, extent: extent),
              let soft = try rasterMask(shapes, feather: feather, extent: extent) else { return nil }
        // Max preserves a full exclusion plateau; Gaussian blur alone can leak
        // color back into tiny eye/mouth polygons and at feature boundaries.
        return try maximum(hard, soft, in: extent)
    }

    private func rasterMask(_ shapes: [Shape], feather: CGFloat, inset: CGFloat = 0,
                            extent: CGRect) throws -> CIImage? {
        let bounds = shapes.reduce(CGRect.null) { partial, shape in
            partial.union(shape.path.boundingBoxOfPath.insetBy(dx: -shape.expansion, dy: -shape.expansion))
        }.insetBy(dx: -4 * feather - 2, dy: -4 * feather - 2).integral
        guard !bounds.isEmpty, !bounds.isNull, !bounds.isInfinite,
              [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite) else { return nil }
        // A feature-local scalar tile, bounded independently of camera resolution.
        // CI scales/feathers it on the existing worker; never rasterize a full photo.
        let scale = min(1, 256 / max(bounds.width, bounds.height))
        let width = max(1, Int(ceil(bounds.width * scale)))
        let height = max(1, Int(ceil(bounds.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.setFillColor(gray: 1, alpha: 1)
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for shape in shapes {
            context.addPath(shape.path)
            context.setLineWidth(2 * shape.expansion)
            context.drawPath(using: shape.filled ? (shape.expansion > 0 ? .fillStroke : .fill) : .stroke)
        }
        guard let bitmap = context.makeImage() else { return nil }
        var raster = CIImage(cgImage: bitmap, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(a: 1 / scale, b: 0, c: 0, d: 1 / scale,
                                              tx: bounds.minX, ty: bounds.minY))
            .composited(over: black(extent)).cropped(to: extent)
        if inset > 0 {
            raster = try CoreImageRendering.filter("CIMorphologyMinimum", parameters: [
                kCIInputImageKey: raster, kCIInputRadiusKey: inset
            ], in: extent)
        }
        guard feather > 0 else { return raster }
        return try CoreImageRendering.filter("CIGaussianBlur", parameters: [
            kCIInputImageKey: raster, kCIInputRadiusKey: feather
        ], in: extent)
    }

    private func ellipse(center: CGPoint, along: CGVector, down: CGVector,
                         radiusX: CGFloat, radiusY: CGFloat, extent: CGRect) throws -> CIImage {
        // CIRadialGradient supplies finite elliptical support with a broad ramp;
        // smoothstep below removes the linear ramp's slope discontinuities.
        let circle = try CoreImageRendering.filter("CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": 0.0, "inputRadius1": 1.0,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0)
        ], in: CGRect(x: -2, y: -2, width: 4, height: 4))
        let smooth = try CoreImageRendering.filter("CIColorPolynomial", parameters: [
            kCIInputImageKey: circle,
            "inputRedCoefficients": CIVector(x: 0, y: 0, z: 3, w: -2),
            "inputGreenCoefficients": CIVector(x: 0, y: 0, z: 3, w: -2),
            "inputBlueCoefficients": CIVector(x: 0, y: 0, z: 3, w: -2)
        ], in: circle.extent)
        return smooth.transformed(by: CGAffineTransform(
            a: along.dx * radiusX, b: along.dy * radiusX,
            c: down.dx * radiusY, d: down.dy * radiusY, tx: center.x, ty: center.y))
            .composited(over: black(extent)).cropped(to: extent)
    }

    private func maximum(_ a: CIImage?, _ b: CIImage, in extent: CGRect) throws -> CIImage {
        guard let a else { return b }
        return try CoreImageRendering.filter("CIMaximumCompositing", parameters: [
            kCIInputImageKey: a, kCIInputBackgroundImageKey: b
        ], in: extent)
    }

    private func inverse(_ mask: CIImage) throws -> CIImage {
        try CoreImageRendering.grayMask(mask, scale: -1, bias: 1)
    }

    private func black(_ extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
    }

    private func center(_ points: [CGPoint]) -> CGPoint {
        CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
    }

    private func polygonArea(_ points: [CGPoint]) -> CGFloat {
        abs(points.indices.reduce(CGFloat.zero) { sum, i in
            let a = points[i], b = points[(i + 1) % points.count]
            return sum + a.x * b.y - b.x * a.y
        }) * 0.5
    }

    private static let browDetail = CIColorKernel(source: """
        kernel vec4 makeupBrowDetail(__sample source, __sample reference) {
            vec3 luma = vec3(0.2126, 0.7152, 0.0722);
            float s = dot(unpremultiply(source).rgb, luma);
            float r = dot(unpremultiply(reference).rgb, luma);
            float darkness = max(0.0, r - s) / max(0.02, r);
            float weight = smoothstep(0.025, 0.30, darkness);
            return vec4(weight, weight, weight, 1.0);
        }
        """)
}
