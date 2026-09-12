import CoreImage
import Foundation

/// A small, local visible movement in an already oriented image.
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

/// Converts the main face's Vision landmarks into conservative, feathered local
/// movements. It accepts any finite image extent; normalized face coordinates are
/// converted directly to that extent's bottom-left pixel coordinate space.
enum FaceCorrectionGeometry {
    static let maximumSlimDisplacementRatio: CGFloat = 0.120
    static let maximumWidthDisplacementRatio: CGFloat = 0.044
    static let maximumChinSideDisplacementRatio: CGFloat = 0.020
    static let maximumChinCenterDisplacementRatio: CGFloat = 0.036
    static let maximumForeheadDisplacementRatio: CGFloat = 0.024
    static let maximumCheekbonesDisplacementRatio: CGFloat = 0.030

    static func warps(faces: [DetectedFace], configuration: BeautyConfiguration,
                      extent: CGRect) -> [FaceCorrectionWarp] {
        result(faces: faces, configuration: configuration, extent: extent).warps
    }

    static func result(faces: [DetectedFace], configuration: BeautyConfiguration,
                       extent: CGRect, slimFaces: [DetectedFace]? = nil) -> FaceCorrectionGeometryResult {
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
        let appliedSlim = configuration.isFaceCorrectionBypassed ? 0 : slim
        let candidateSmallFaceWarps = slimControls(face: primaryFace(in: slimFaces ?? [face]),
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

            let forehead = CGFloat(configuration.effectiveForehead)
            if forehead > 0,
               let leftBrow = average(validLandmarks(.leftEyebrow, in: face)),
               let rightBrow = average(validLandmarks(.rightEyebrow, in: face)) {
                let browTop = max(leftBrow.y, rightBrow.y)
                let gap = face.boundingBox.maxY - browTop
                if gap >= face.boundingBox.height * 0.10,
                   gap <= face.boundingBox.height * 0.50 {
                    let y = browTop + gap * 0.62
                    let movement = box.height * maximumForeheadDisplacementRatio * forehead
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
                let movement = box.width * maximumCheekbonesDisplacementRatio * cheekbones
                appendSidePair(to: &result, left: leftCheekbone, right: rightCheekbone,
                               extent: extent, inset: box.width * 0.020,
                               radius: box.width * 0.16, movement: movement,
                               leftKind: .cheekbonesLeft, rightKind: .cheekbonesRight)
            }
        }
        return FaceCorrectionGeometryResult(faceBox: box, contour: pixelContour,
                                            smallFaceWarps: smallFaceWarps, warps: result)
    }

    // Fixed anatomical targets, with soft contour sampling rather than nearest-point
    // selection. Every valid contour point contributes continuously as the face moves.
    // The first zone is mid-cheek (peak); the others connect upper cheek to jaw/chin.
    private static let slimZones: [(x: CGFloat, y: CGFloat, gain: CGFloat, radius: CGFloat)] = [
        (0.12, 0.36, 1.00, 0.32), (0.09, 0.56, 0.65, 0.32),
        (0.10, 0.46, 0.90, 0.32), (0.19, 0.25, 0.80, 0.30),
        (0.28, 0.15, 0.55, 0.24), (0.39, 0.07, 0.20, 0.16)
    ]

    private static func slimControls(face: DetectedFace?, strength: CGFloat,
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
    #if DEBUG
    private var diagnosticConfiguration: BeautyConfiguration?
    private var diagnosticTime: TimeInterval = -.infinity
    private var diagnosticHadWarps = false

    /// Opt-in, configuration-change-only readback, limited to once per second.
    /// Samples the actual production map; does not log images or landmark positions.
    func logStrengthDiagnostics(configuration: BeautyConfiguration,
                                geometry: FaceCorrectionGeometryResult, extent: CGRect) throws {
        guard ProcessInfo.processInfo.arguments.contains("-PanPanBeautyStrengthDiagnostics") else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let hasWarps = !geometry.warps.isEmpty
        let shouldLog = (configuration != diagnosticConfiguration || hasWarps != diagnosticHadWarps) &&
            now - diagnosticTime >= 1
        if shouldLog {
            diagnosticConfiguration = configuration
            diagnosticTime = now
            diagnosticHadWarps = hasWarps
        }
        lock.unlock()
        guard shouldLog else { return }

        let strengths: [(String, Double, Double)] = [
            ("Slim", configuration.faceSlimStrength, configuration.effectiveFaceSlim),
            ("Width", configuration.faceWidthStrength, configuration.effectiveFaceWidth),
            ("Chin", configuration.chinStrength, configuration.effectiveChin),
            ("Forehead", configuration.foreheadStrength, configuration.effectiveForehead),
            ("Cheekbones", configuration.cheekbonesStrength, configuration.effectiveCheekbones)
        ]
        print("BeautyStrength frame snapshot: faceAuto=\(configuration.faceOverallStrength) " +
              "faceWidth=\(geometry.faceBox?.width ?? 0) faceHeight=\(geometry.faceBox?.height ?? 0) " +
              "activeWarps=\(geometry.warps.count)")
        for (name, ui, effective) in strengths {
            print("BeautyStrength \(name): uiValue=\(ui * 100) uiStrength=\(ui) " +
                  "effectiveStrength=\(effective) previewStrength=\(effective) processorStrength=\(effective)")
        }
        print("BeautyStrength skin: auto=\(configuration.overallStrength) " +
              "smooth=\(configuration.smoothingStrength)->\(configuration.effectiveSmoothing) " +
              "brighten=\(configuration.brighteningStrength)->\(configuration.effectiveBrightening) " +
              "tone=\(configuration.toneStrength)->\(configuration.effectiveTone)")
        guard !geometry.warps.isEmpty else { return }
        let map = try displacementMap(for: geometry.warps, extent: extent)
        for warp in geometry.warps where extent.contains(warp.center) {
            let rgba = CoreImageRendering.diagnosticRGBA(map.image, at: warp.center)
            let visible = CGVector(dx: (0.5 - CGFloat(rgba[0])) * map.scale,
                                   dy: (0.5 - CGFloat(rgba[1])) * map.scale)
            print("BeautyStrength \(warp.kind): radius=\(warp.radius) " +
                  "requestedVisibleOffset=\(warp.visibleOffset) mapScale=\(map.scale) " +
                  "sampledCombinedVisibleOffset=\(visible)")
        }
    }
    #endif

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
        guard largest > 0 else { throw BeautyImageProcessor.Failure.invalidExtent }

        // Encode inverse sampling offsets: R = X, G = Y, 0.5 = zero.
        // The matching kernel decodes these values into CI pixels exactly once.
        // Overlapping effects contribute vectors, not opaque layers. Bound the
        // sum so RG stays in 0...1 without clipping or normalizing strength again.
        let slim = warps.filter(\.isSlim)
        let slimBound = slim.map { abs($0.visibleOffset.dx) }.max() ?? 0
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
        if !slim.isEmpty {
            guard slim.count <= 12, let kernel = Self.slimDisplacement else {
                throw CoreImageRendering.Failure.filterUnavailable
            }
            var arguments: [Any] = [displacement]
            for index in 0..<12 {
                if index < slim.count {
                    let warp = slim[index]
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
