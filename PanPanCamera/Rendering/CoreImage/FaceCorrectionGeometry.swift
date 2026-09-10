import CoreImage
import Foundation

/// A small, local visible movement in the already oriented Preview image.
/// The Core Image step converts this forward movement to an inverse sampling offset.
struct FaceCorrectionWarp: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case slimLeft, slimRight
        case widthLeft, widthRight
        case chinLeft, chinCenter, chinRight
        case foreheadLeft, foreheadRight
        case cheekbonesLeft, cheekbonesRight
    }

    let kind: Kind
    let center: CGPoint
    let radius: CGFloat
    let visibleOffset: CGVector
}

/// The exact fitted Preview geometry used to build the production displacement map.
/// Zero-strength small-face zones remain available for diagnostics, while only
/// `warps` are admitted to Core Image rendering.
struct FaceCorrectionGeometryResult: Equatable, Sendable {
    let faceBox: CGRect?
    let contour: [CGPoint]
    let smallFaceWarps: [FaceCorrectionWarp]
    let warps: [FaceCorrectionWarp]

    static let empty = Self(faceBox: nil, contour: [], smallFaceWarps: [], warps: [])
}

/// Converts the main face's Vision landmarks into conservative, feathered local
/// movements. It is pure geometry so zero/invalid/incomplete inputs are testable
/// without running Core Image. Coordinates are image pixels with a bottom-left origin.
enum FaceCorrectionGeometry {
    static func warps(faces: [DetectedFace], configuration: BeautyConfiguration,
                      extent: CGRect) -> [FaceCorrectionWarp] {
        result(faces: faces, configuration: configuration, extent: extent).warps
    }

    static func result(faces: [DetectedFace], configuration: BeautyConfiguration,
                       extent: CGRect) -> FaceCorrectionGeometryResult {
        guard isValid(extent), let face = primaryFace(in: faces) else { return .empty }
        let contour = validLandmarks(.faceContour, in: face)
        let box = pixelRect(face.boundingBox, in: extent)
        let pixelContour = contour.map { pixelPoint($0, in: extent) }
        guard contour.count >= 5, box.width >= 8, box.height >= 8 else {
            return FaceCorrectionGeometryResult(faceBox: box, contour: pixelContour,
                                                smallFaceWarps: [], warps: [])
        }

        let leftLower = closest(contour, to: CGPoint(x: 0.12, y: 0.30), in: face.boundingBox)
        let rightLower = closest(contour, to: CGPoint(x: 0.88, y: 0.30), in: face.boundingBox)
        let leftWidth = closest(contour, to: CGPoint(x: 0.08, y: 0.52), in: face.boundingBox)
        let rightWidth = closest(contour, to: CGPoint(x: 0.92, y: 0.52), in: face.boundingBox)
        let leftCheekbone = closest(contour, to: CGPoint(x: 0.10, y: 0.64), in: face.boundingBox)
        let rightCheekbone = closest(contour, to: CGPoint(x: 0.90, y: 0.64), in: face.boundingBox)
        let chin = closest(contour, to: CGPoint(x: 0.50, y: 0.04), in: face.boundingBox)

        var result: [FaceCorrectionWarp] = []
        let slim = CGFloat(configuration.effectiveFaceSlim)
        // Face Auto defaults to 0.5, so Slim = 100 previously moved each jaw
        // edge only 1.4% of face width. That is sub-visible after Preview scaling.
        // Keep the same local radius, but allow a clear 3% per-side movement at
        // the default Auto value (6% only when both controls are at maximum).
        let appliedSlim = configuration.isFaceCorrectionBypassed ? 0 : slim
        let candidateSmallFaceWarps = sidePair(left: leftLower, right: rightLower, extent: extent,
            inset: box.width * 0.018, radius: box.width * 0.22,
            movement: box.width * 0.060 * appliedSlim,
            leftKind: .slimLeft, rightKind: .slimRight, permitsZeroMovement: true)
        let activeSmallFaceWarps = candidateSmallFaceWarps.filter {
            !configuration.isFaceCorrectionBypassed && slim > 0 && visibleMagnitude($0) >= 0.05
        }
        result.append(contentsOf: activeSmallFaceWarps)
        let smallFaceWarps = candidateSmallFaceWarps.map { warp in
            activeSmallFaceWarps.contains(warp) ? warp : FaceCorrectionWarp(
                kind: warp.kind, center: warp.center, radius: warp.radius, visibleOffset: .zero
            )
        }

        if !configuration.isFaceCorrectionBypassed {
            let width = CGFloat(configuration.effectiveFaceWidth)
            if width > 0 {
                let movement = box.width * 0.022 * width
                appendSidePair(to: &result, left: leftWidth, right: rightWidth, extent: extent,
                               inset: box.width * 0.015, radius: box.width * 0.18,
                               movement: movement, leftKind: .widthLeft, rightKind: .widthRight)
            }

            let chinStrength = CGFloat(configuration.effectiveChin)
            if chinStrength > 0 {
                let sideMovement = box.width * 0.010 * chinStrength
                appendSidePair(to: &result, left: leftLower, right: rightLower, extent: extent,
                               inset: box.width * 0.025, radius: box.width * 0.17,
                               movement: sideMovement, leftKind: .chinLeft, rightKind: .chinRight)
                append(&result, kind: .chinCenter, point: chin, extent: extent,
                       centerOffset: .zero, radius: box.width * 0.20,
                       visibleOffset: CGVector(dx: 0, dy: box.height * 0.018 * chinStrength))
            }

            let forehead = CGFloat(configuration.effectiveForehead)
            if forehead > 0,
               let leftBrow = average(validLandmarks(.leftEyebrow, in: face)),
               let rightBrow = average(validLandmarks(.rightEyebrow, in: face)) {
                let browTop = max(leftBrow.y, rightBrow.y)
                let gap = face.boundingBox.maxY - browTop
                if gap >= face.boundingBox.height * 0.10,
                   gap <= face.boundingBox.height * 0.50 {
                    let y = browTop + gap * 0.62
                    let movement = box.height * 0.012 * forehead
                    let radius = box.width * 0.19
                    let horizontal = box.width * 0.15
                    let centerX = (leftBrow.x + rightBrow.x) / 2
                    append(&result, kind: .foreheadLeft,
                           point: CGPoint(x: centerX, y: y), extent: extent,
                           centerOffset: CGVector(dx: -horizontal, dy: 0), radius: radius,
                           visibleOffset: CGVector(dx: 0, dy: -movement))
                    append(&result, kind: .foreheadRight,
                           point: CGPoint(x: centerX, y: y), extent: extent,
                           centerOffset: CGVector(dx: horizontal, dy: 0), radius: radius,
                           visibleOffset: CGVector(dx: 0, dy: -movement))
                }
            }

            let cheekbones = CGFloat(configuration.effectiveCheekbones)
            if cheekbones > 0 {
                let movement = box.width * 0.015 * cheekbones
                appendSidePair(to: &result, left: leftCheekbone, right: rightCheekbone,
                               extent: extent, inset: box.width * 0.020,
                               radius: box.width * 0.16, movement: movement,
                               leftKind: .cheekbonesLeft, rightKind: .cheekbonesRight)
            }
        }
        return FaceCorrectionGeometryResult(faceBox: box, contour: pixelContour,
                                            smallFaceWarps: smallFaceWarps, warps: result)
    }

    static func primaryFace(in faces: [DetectedFace]) -> DetectedFace? {
        faces.filter {
            let box = $0.boundingBox
            return isValid(box) && box.minX >= 0 && box.minY >= 0 && box.maxX <= 1 && box.maxY <= 1
        }
            .max { lhs, rhs in
                let leftArea = lhs.boundingBox.width * lhs.boundingBox.height
                let rightArea = rhs.boundingBox.width * rhs.boundingBox.height
                if abs(leftArea - rightArea) > 0.000_001 { return leftArea < rightArea }
                return distanceFromCenter(lhs.boundingBox) > distanceFromCenter(rhs.boundingBox)
            }
    }

    private static func appendSidePair(to result: inout [FaceCorrectionWarp],
                                       left: CGPoint, right: CGPoint, extent: CGRect,
                                       inset: CGFloat, radius: CGFloat, movement: CGFloat,
                                       leftKind: FaceCorrectionWarp.Kind,
                                       rightKind: FaceCorrectionWarp.Kind) {
        result.append(contentsOf: sidePair(left: left, right: right, extent: extent,
            inset: inset, radius: radius, movement: movement,
            leftKind: leftKind, rightKind: rightKind, permitsZeroMovement: false))
    }

    private static func sidePair(left: CGPoint, right: CGPoint, extent: CGRect,
                                 inset: CGFloat, radius: CGFloat, movement: CGFloat,
                                 leftKind: FaceCorrectionWarp.Kind,
                                 rightKind: FaceCorrectionWarp.Kind,
                                 permitsZeroMovement: Bool) -> [FaceCorrectionWarp] {
        [
            makeWarp(kind: leftKind, point: left, extent: extent,
                     centerOffset: CGVector(dx: inset, dy: 0), radius: radius,
                     visibleOffset: CGVector(dx: movement, dy: 0),
                     permitsZeroMovement: permitsZeroMovement),
            makeWarp(kind: rightKind, point: right, extent: extent,
                     centerOffset: CGVector(dx: -inset, dy: 0), radius: radius,
                     visibleOffset: CGVector(dx: -movement, dy: 0),
                     permitsZeroMovement: permitsZeroMovement)
        ].compactMap { $0 }
    }

    private static func append(_ result: inout [FaceCorrectionWarp],
                               kind: FaceCorrectionWarp.Kind, point: CGPoint, extent: CGRect,
                               centerOffset: CGVector, radius: CGFloat,
                               visibleOffset: CGVector) {
        guard let warp = makeWarp(kind: kind, point: point, extent: extent,
                                  centerOffset: centerOffset, radius: radius,
                                  visibleOffset: visibleOffset,
                                  permitsZeroMovement: false) else { return }
        result.append(warp)
    }

    private static func makeWarp(kind: FaceCorrectionWarp.Kind, point: CGPoint, extent: CGRect,
                                 centerOffset: CGVector, radius: CGFloat,
                                 visibleOffset: CGVector,
                                 permitsZeroMovement: Bool) -> FaceCorrectionWarp? {
        let center = pixelPoint(point, in: extent)
        let adjusted = CGPoint(x: center.x + centerOffset.dx, y: center.y + centerOffset.dy)
        guard isFinite(adjusted.x), isFinite(adjusted.y), isFinite(radius), radius >= 1,
              isFinite(visibleOffset.dx), isFinite(visibleOffset.dy),
              permitsZeroMovement || hypot(visibleOffset.dx, visibleOffset.dy) >= 0.05 else { return nil }
        return FaceCorrectionWarp(kind: kind, center: adjusted, radius: radius,
                                  visibleOffset: visibleOffset)
    }

    private static func validLandmarks(_ name: FacialLandmarkRegion,
                                       in face: DetectedFace) -> [CGPoint] {
        guard let points = face.landmarks[name] else { return [] }
        let marginX = face.boundingBox.width * 0.12
        let marginY = face.boundingBox.height * 0.12
        let accepted = face.boundingBox.insetBy(dx: -marginX, dy: -marginY)
        return points.filter { isFinite($0.x) && isFinite($0.y) && accepted.contains($0) }
    }

    private static func closest(_ points: [CGPoint], to target: CGPoint, in box: CGRect) -> CGPoint {
        points.min {
            squaredDistance(relative($0, in: box), target) <
                squaredDistance(relative($1, in: box), target)
        } ?? box.center
    }

    private static func average(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private static func relative(_ point: CGPoint, in box: CGRect) -> CGPoint {
        CGPoint(x: (point.x - box.minX) / box.width, y: (point.y - box.minY) / box.height)
    }

    private static func pixelPoint(_ point: CGPoint, in extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + point.x * extent.width,
                y: extent.minY + point.y * extent.height)
    }

    private static func pixelRect(_ rect: CGRect, in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + rect.minX * extent.width,
               y: extent.minY + rect.minY * extent.height,
               width: rect.width * extent.width, height: rect.height * extent.height)
    }

    private static func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x, dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func distanceFromCenter(_ rect: CGRect) -> CGFloat {
        squaredDistance(rect.center, CGPoint(x: 0.5, y: 0.5))
    }

    private static func isValid(_ rect: CGRect) -> Bool {
        isFinite(rect.minX) && isFinite(rect.minY) && isFinite(rect.width) && isFinite(rect.height) &&
            !rect.isNull && !rect.isInfinite && !rect.isEmpty
    }

    private static func isFinite(_ value: CGFloat) -> Bool { value.isFinite }

    private static func visibleMagnitude(_ warp: FaceCorrectionWarp) -> CGFloat {
        hypot(warp.visibleOffset.dx, warp.visibleOffset.dy)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// Builds one bounded RG vector map and samples the source with explicit pixel offsets.
/// No CIContext, pixel buffer, or history is created here.
final class FaceCorrectionPreviewStep: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedWarps: [FaceCorrectionWarp] = []
    private var cachedExtent = CGRect.null
    private var cachedMap: CIImage?
    private var cachedScale: CGFloat = 0

    func makeOutput(source: CIImage, faces: [DetectedFace],
                    configuration: BeautyConfiguration) throws -> CIImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let warps = FaceCorrectionGeometry.warps(faces: faces, configuration: configuration,
                                                  extent: source.extent)
        return try makeOutput(source: source, warps: warps)
    }

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
        guard largest >= 0.05 else { throw BeautyImageProcessor.Failure.invalidExtent }

        // Encode inverse sampling offsets: R = X, G = Y, 0.5 = zero.
        // The matching kernel decodes these values into CI pixels exactly once.
        let scale = max(1, largest * 2)
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
        for warp in warps {
            let red = min(1, max(0, 0.5 - warp.visibleOffset.dx / scale))
            let green = min(1, max(0, 0.5 - warp.visibleOffset.dy / scale))
            let falloff = try CoreImageRendering.filter("CIRadialGradient", parameters: [
                "inputCenter": CIVector(cgPoint: warp.center),
                "inputRadius0": warp.radius * 0.30,
                "inputRadius1": warp.radius,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            ], in: extent)
            let gradient = try CoreImageRendering.filter("CIColorMatrix", parameters: [
                kCIInputImageKey: falloff,
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: red, y: green, z: 0, w: 0)
            ], in: extent)
            displacement = try CoreImageRendering.filter("CISourceOverCompositing", parameters: [
                kCIInputImageKey: gradient,
                kCIInputBackgroundImageKey: displacement
            ], in: extent)
        }
        cachedWarps = warps
        cachedExtent = extent
        cachedMap = displacement
        cachedScale = scale
        return (displacement, scale)
    }

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
