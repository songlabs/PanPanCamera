import CoreImage
import Foundation

/// A small, local visible movement in an already oriented image.
/// The Core Image step converts this forward movement to an inverse sampling offset.
struct FaceCorrectionWarp: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case slimLeft, slimRight
        case widthLeft, widthRight
        case chinLeft, chinCenter, chinRight
    }

    let kind: Kind
    let center: CGPoint
    let radius: CGFloat
    let visibleOffset: CGVector

    var isSlim: Bool { kind == .slimLeft || kind == .slimRight }
}

/// The exact image geometry used to build the production displacement map.
/// Zero-strength small-face zones remain available for diagnostics, while only
/// `warps` are admitted to Core Image rendering.
struct FaceCorrectionGeometryResult: Equatable, Sendable {
    let faceBox: CGRect?
    let contour: [CGPoint]
    let smallFaceWarps: [FaceCorrectionWarp]
    let warps: [FaceCorrectionWarp]

    static let empty = Self(faceBox: nil, contour: [], smallFaceWarps: [], warps: [])
}

/// Converts Vision semantic landmarks into conservative, feathered local
/// movements. It accepts any finite image extent; normalized face coordinates are
/// converted directly to that extent's bottom-left pixel coordinate space.
enum FaceCorrectionGeometry {
    static let maximumSlimDisplacementRatio: CGFloat = 0.120
    static let maximumWidthDisplacementRatio: CGFloat = 0.044
    static let maximumChinSideDisplacementRatio: CGFloat = 0.020
    static let maximumChinCenterDisplacementRatio: CGFloat = 0.036

    static func warps(faces: [AnalyzedFace], configuration: BeautyConfiguration,
                      extent: CGRect) -> [FaceCorrectionWarp] {
        result(faces: faces, configuration: configuration, extent: extent).warps
    }

    static func result(faces: [AnalyzedFace], configuration: BeautyConfiguration,
                       extent: CGRect) -> FaceCorrectionGeometryResult {
        let results = faces.filter { $0.landmarks.isAvailable }.map {
            singleResult(face: $0, configuration: configuration, extent: extent)
        }
        return FaceCorrectionGeometryResult(faceBox: results.first?.faceBox,
            contour: results.flatMap(\.contour), smallFaceWarps: results.flatMap(\.smallFaceWarps),
            warps: results.flatMap(\.warps))
    }

    private static func singleResult(face: AnalyzedFace, configuration: BeautyConfiguration,
                                     extent: CGRect) -> FaceCorrectionGeometryResult {
        guard isValid(extent), face.confidence >= 0.5 else { return .empty }
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
        let chin = closest(contour, to: CGPoint(x: 0.50, y: 0.04), in: face.boundingBox)

        var result: [FaceCorrectionWarp] = []
        let slim = CGFloat(configuration.effectiveFaceSlim)
        let appliedSlim = configuration.isFaceCorrectionBypassed ? 0 : slim
        let candidateSmallFaceWarps = slimControls(face: face,
                                                   strength: appliedSlim, extent: extent)
        let activeSmallFaceWarps = !configuration.isFaceCorrectionBypassed && slim > 0
            ? candidateSmallFaceWarps : []
        result.append(contentsOf: activeSmallFaceWarps)
        let smallFaceWarps = candidateSmallFaceWarps.map { warp in
            activeSmallFaceWarps.contains(warp) ? warp : FaceCorrectionWarp(
                kind: warp.kind, center: warp.center, radius: warp.radius, visibleOffset: .zero
            )
        }

        if !configuration.isFaceCorrectionBypassed {
            let width = CGFloat(configuration.effectiveFaceWidth)
            if width > 0 {
                let movement = box.width * maximumWidthDisplacementRatio * width
                appendSidePair(to: &result, left: leftWidth, right: rightWidth, extent: extent,
                               inset: box.width * 0.015, radius: box.width * 0.18,
                               movement: movement, leftKind: .widthLeft, rightKind: .widthRight)
            }

            let chinStrength = CGFloat(configuration.effectiveChin)
            if chinStrength > 0 {
                let sideMovement = box.width * maximumChinSideDisplacementRatio * chinStrength
                appendSidePair(to: &result, left: leftLower, right: rightLower, extent: extent,
                               inset: box.width * 0.025, radius: box.width * 0.17,
                               movement: sideMovement, leftKind: .chinLeft, rightKind: .chinRight)
                append(&result, kind: .chinCenter, point: chin, extent: extent,
                       centerOffset: .zero, radius: box.width * 0.20,
                       visibleOffset: CGVector(
                        dx: 0, dy: box.height * maximumChinCenterDisplacementRatio * chinStrength))
            }
        }
        return FaceCorrectionGeometryResult(faceBox: box, contour: pixelContour,
                                            smallFaceWarps: smallFaceWarps, warps: result)
    }

    struct EyeAdjustment: Equatable, Sendable {
        let center: CGPoint
        let radius: CGFloat
        let scale: CGFloat
    }

    static func eyes(faces: [AnalyzedFace], configuration: BeautyConfiguration, extent: CGRect) -> [EyeAdjustment] {
        guard configuration.enabled, configuration.effectiveEyes > 0, isValid(extent) else { return [] }
        return faces.filter { $0.confidence >= 0.5 }.flatMap { face -> [EyeAdjustment] in
            [FacialLandmarkRegion.leftEye, .rightEye].compactMap { name -> EyeAdjustment? in
                let points = validLandmarks(name, in: face).map { pixelPoint($0, in: extent) }
                guard points.count >= 4, let center = average(points) else { return nil }
                let bounds = FaceAnalysisCoordinates.bounds(points)
                let radius = max(bounds.width, bounds.height) * 0.9
                guard radius >= 2, radius < pixelRect(face.boundingBox, in: extent).width * 0.30 else { return nil }
                return EyeAdjustment(center: center, radius: radius, scale: CGFloat(configuration.effectiveEyes) * 0.06)
            }
        }
    }

    // Fixed anatomical targets, with soft contour sampling rather than nearest-point
    // selection. Every valid contour point contributes continuously as the face moves.
    // The first zone is mid-cheek (peak); the others connect upper cheek to jaw/chin.
    private static let slimZones: [(x: CGFloat, y: CGFloat, gain: CGFloat, radius: CGFloat)] = [
        (0.12, 0.36, 1.00, 0.32), (0.09, 0.56, 0.65, 0.32),
        (0.10, 0.46, 0.90, 0.32), (0.19, 0.25, 0.80, 0.30),
        (0.28, 0.15, 0.55, 0.24), (0.39, 0.07, 0.20, 0.16)
    ]

    private static func slimControls(face: AnalyzedFace?, strength: CGFloat,
                                     extent: CGRect) -> [FaceCorrectionWarp] {
        guard let face else { return [] }
        let contour = validLandmarks(.faceContour, in: face)
        let box = pixelRect(face.boundingBox, in: extent)
        guard contour.count >= 5, box.width >= 8, box.height >= 8 else { return [] }
        var controls: [FaceCorrectionWarp] = []
        controls.reserveCapacity(12)
        for zone in slimZones {
            let left = contourAnchor(contour, target: CGPoint(x: zone.x, y: zone.y),
                                     box: face.boundingBox)
            let right = contourAnchor(contour, target: CGPoint(x: 1 - zone.x, y: zone.y),
                                      box: face.boundingBox)
            controls.append(contentsOf: sidePair(left: left, right: right, extent: extent,
                inset: box.width * 0.018, radius: box.width * zone.radius,
                movement: box.width * maximumSlimDisplacementRatio * strength * zone.gain,
                leftKind: .slimLeft, rightKind: .slimRight, permitsZeroMovement: true))
        }
        return controls
    }

    private static func contourAnchor(_ points: [CGPoint], target: CGPoint, box: CGRect) -> CGPoint {
        var sum = CGPoint.zero
        var total: CGFloat = 0
        for point in points {
            let distance = squaredDistance(relative(point, in: box), target)
            let weight = exp(-distance / (2 * 0.10 * 0.10))
            sum.x += point.x * weight
            sum.y += point.y * weight
            total += weight
        }
        return CGPoint(x: sum.x / total, y: sum.y / total)
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
                                       in face: AnalyzedFace) -> [CGPoint] {
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
        } ?? CGPoint(x: box.midX, y: box.midY)
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

    private static func isValid(_ rect: CGRect) -> Bool {
        isFinite(rect.minX) && isFinite(rect.minY) && isFinite(rect.width) && isFinite(rect.height) &&
            !rect.isNull && !rect.isInfinite && !rect.isEmpty
    }

    private static func isFinite(_ value: CGFloat) -> Bool { value.isFinite }

}
