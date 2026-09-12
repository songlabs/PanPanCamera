import CoreImage
import Foundation

enum BeautyProcessingQuality: Equatable, Sendable { case preview, final }

/// Renderer-space diagnostics produced after the production orientation, mirror and
/// aspect-fill transforms. Coordinates use the Metal drawable's bottom-left pixel space.
struct FaceGeometryDebugSnapshot: Equatable, Sendable {
    let extent: CGRect
    let faceDetected: Bool
    let faceBox: CGRect?
    let beautyROIs: [CGRect]
    let contour: [CGPoint]
    let smallFaceWarps: [FaceCorrectionWarp]
    let warps: [FaceCorrectionWarp]
    let smallFaceUI: Double
    let normalizedSmallFace: Double
    let auto: Double
    let effectiveSmallFace: Double
    let captureOrientation: FaceImageOrientation
    let displayOrientation: FaceImageOrientation
    let displayRotationAngle: CGFloat
    let mirrored: Bool
}

struct BeautyPreviewProcessingResult {
    let image: CIImage?
    let geometryDebug: FaceGeometryDebugSnapshot?
}

/// Product amplitudes at a normalized UI strength of 1. Each concrete parameter
/// from `BeautyConfiguration` is applied once.
enum BeautyEffectAmplitude {
    static let brightening = 0.06
    static let previewSmoothingDetailRetention = 0.88
    static let finalSmoothingDetailRetention = 0.80
    static let previewToneConsistency = 0.40
    static let finalToneConsistency = 0.50
}

/// Shared skin, makeup, face geometry and global color effects.
/// Makeup is composited in landmark space before warping the combined pixels;
/// the global filter always consumes the final result of the preceding steps.
struct BeautyImageProcessor: Sendable {
    enum Failure: Error { case invalidExtent }
    private let faceCorrection = FaceCorrectionPreviewStep()
    private let makeup = MakeupProcessingStep()
    private let filter = FilterProcessingStep()
    private let reuseFinalGeometry: Bool

    init(reuseFinalGeometry: Bool = true) {
        self.reuseFinalGeometry = reuseFinalGeometry
    }

    func previewImage(for frame: BeautyPreviewFrame, displayRotationAngle: CGFloat,
                      targetSize: CGSize) throws -> CIImage? {
        try previewResult(for: frame, displayRotationAngle: displayRotationAngle,
                          targetSize: targetSize).image
    }

    func previewResult(for frame: BeautyPreviewFrame, displayRotationAngle: CGFloat,
                       targetSize: CGSize) throws -> BeautyPreviewProcessingResult {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard targetSize.width >= 1, targetSize.height >= 1 else {
            return BeautyPreviewProcessingResult(image: nil, geometryDebug: nil)
        }

        guard let displayOrientation = FaceImageOrientation(captureAngle: displayRotationAngle) else {
            return BeautyPreviewProcessingResult(image: nil, geometryDebug: nil)
        }
        let exif = SilentFrameOrientation.exif(captureOrientation: displayOrientation, mirrored: false)
        var image = CIImage(cvPixelBuffer: frame.pixelBuffer).oriented(exif)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                        y: -image.extent.minY))
        var orientedFaces = Self.reorientedFaces(frame.faces, from: frame.orientation,
                                                 to: displayOrientation, mirrored: false)
        var slimFaces = frame.slimFaces.map {
            Self.reorientedFaces($0, from: frame.orientation, to: displayOrientation, mirrored: false)
        }
        var makeupFaces = frame.makeupFaces.map {
            Self.reorientedFaces($0, from: frame.orientation, to: displayOrientation, mirrored: false)
        }
        let normalizedAngle = (displayRotationAngle.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        var residual = normalizedAngle - CGFloat(displayOrientation.rawValue)
        if residual > 180 { residual -= 360 }
        if residual < -180 { residual += 360 }
        if abs(residual) > 0.01 {
            let originalExtent = image.extent
            let radians = -residual * .pi / 180
            let center = CGPoint(x: originalExtent.midX, y: originalExtent.midY)
            let rotation = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: radians).translatedBy(x: -center.x, y: -center.y)
            let rotated = image.transformed(by: rotation)
            let translation = CGAffineTransform(translationX: -rotated.extent.minX,
                                                y: -rotated.extent.minY)
            orientedFaces = Self.transformedFaces(orientedFaces, sourceExtent: originalExtent,
                transform: rotation, outputExtent: rotated.extent)
            slimFaces = slimFaces.map {
                Self.transformedFaces($0, sourceExtent: originalExtent,
                                      transform: rotation, outputExtent: rotated.extent)
            }
            makeupFaces = makeupFaces.map {
                Self.transformedFaces($0, sourceExtent: originalExtent,
                                      transform: rotation, outputExtent: rotated.extent)
            }
            image = rotated.transformed(by: translation)
        }
        if frame.mirrored {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                                                            tx: image.extent.width, ty: 0))
            orientedFaces = Self.reorientedFaces(orientedFaces, from: displayOrientation,
                                                 to: displayOrientation, mirrored: true)
            slimFaces = slimFaces.map {
                Self.reorientedFaces($0, from: displayOrientation, to: displayOrientation, mirrored: true)
            }
            makeupFaces = makeupFaces.map {
                Self.reorientedFaces($0, from: displayOrientation, to: displayOrientation, mirrored: true)
            }
        }
        let sourceExtent = image.extent
        let target = CGRect(origin: .zero, size: targetSize)
        let scale = max(target.width / image.extent.width, target.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                          tx: (target.width - scaled.extent.width) / 2,
                                          ty: (target.height - scaled.extent.height) / 2)
        image = image.transformed(by: transform).cropped(to: target)
        let fittedFaces = Self.fittedFaces(orientedFaces, sourceExtent: sourceExtent,
                                           targetExtent: target, transform: transform)
        let fittedSlimFaces = slimFaces.map {
            Self.fittedFaces($0, sourceExtent: sourceExtent, targetExtent: target, transform: transform)
        }
        let fittedMakeupFaces = makeupFaces.map {
            Self.fittedFaces($0, sourceExtent: sourceExtent, targetExtent: target, transform: transform)
        }
        let geometry = FaceCorrectionGeometry.result(faces: fittedFaces,
            configuration: frame.configuration, extent: target, slimFaces: fittedSlimFaces)
        #if DEBUG
        // Diagnostic failure must not turn an otherwise valid Preview into a bypass.
        try? faceCorrection.logStrengthDiagnostics(configuration: frame.configuration,
                                                   geometry: geometry, extent: target)
        #endif
        let debug = FaceGeometryDebugSnapshot(
            extent: target,
            faceDetected: !fittedFaces.isEmpty,
            faceBox: geometry.faceBox,
            beautyROIs: Self.geometry(from: fittedFaces).regions.map { $0.imageRect(in: target) },
            contour: geometry.contour,
            smallFaceWarps: geometry.smallFaceWarps,
            warps: geometry.warps,
            smallFaceUI: frame.configuration.faceSlimStrength * 100,
            normalizedSmallFace: frame.configuration.faceSlimStrength,
            auto: frame.configuration.faceOverallStrength,
            effectiveSmallFace: frame.configuration.effectiveFaceSlim,
            captureOrientation: frame.orientation,
            displayOrientation: displayOrientation,
            displayRotationAngle: displayRotationAngle,
            mirrored: frame.mirrored
        )
        guard !frame.configuration.isBypassed else {
            return BeautyPreviewProcessingResult(image: nil, geometryDebug: debug)
        }
        var result = try processFaceEffects(image, faces: fittedFaces,
            makeupFaces: fittedMakeupFaces, configuration: frame.configuration, quality: .preview)
        if let shaped = try faceCorrection.makeOutput(source: result, warps: geometry.warps) {
            result = shaped
        }
        if let colored = try filter.makeOutput(source: result, configuration: frame.configuration.filter) {
            result = colored
        }
        // No face/usable feature and no filter: use the native preview fallback.
        return BeautyPreviewProcessingResult(image: result === image ? nil : result, geometryDebug: debug)
    }

    func process(_ source: CIImage, faces: [DetectedFace], configuration: BeautyConfiguration,
                 quality: BeautyProcessingQuality,
                 diagnostics: PhotoCaptureDiagnostics = .disabled) throws -> CIImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !configuration.isPhotoBypassed else { return source }
        let result = try processFaceEffects(source, faces: faces, configuration: configuration,
                                            quality: quality, diagnostics: diagnostics)
        let corrected = try processFaceCorrection(result, faces: faces,
            configuration: configuration, quality: quality, diagnostics: diagnostics)
        return try diagnostics.measure("filter_graph") {
            try filter.makeOutput(source: corrected, configuration: configuration.filter) ?? corrected
        }
    }

    private func processFaceCorrection(_ source: CIImage, faces: [DetectedFace],
                                       configuration: BeautyConfiguration,
                                       quality: BeautyProcessingQuality,
                                       diagnostics: PhotoCaptureDiagnostics) throws -> CIImage {
        guard !configuration.isFaceCorrectionBypassed, !faces.isEmpty else { return source }
        return try diagnostics.measure("face_graph") {
            let geometry = FaceCorrectionGeometry.result(faces: faces,
                configuration: configuration, extent: source.extent)
            guard !geometry.warps.isEmpty else { return source }
            // Final capture builds a full-resolution map for this job and does not
            // retain it in the Preview cache.
            let step = quality == .final ? FaceCorrectionPreviewStep() : faceCorrection
            return try step.makeOutput(source: source, warps: geometry.warps) ?? source
        }
    }

    func processFaceEffects(_ source: CIImage, faces: [DetectedFace],
                            makeupFaces: [DetectedFace]? = nil,
                            configuration: BeautyConfiguration,
                            quality: BeautyProcessingQuality,
                            diagnostics: PhotoCaptureDiagnostics = .disabled) throws -> CIImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard configuration.enabled else { return source }
        // CIImage is lazy: these durations measure graph/mask construction. All
        // deferred pixel work is included in the single final render measurement.
        let result = try diagnostics.measure("skin_graph") {
            try processSkin(source, faces: faces, configuration: configuration, quality: quality)
        }
        return try diagnostics.measure("makeup_graph") {
            // Preview keeps its existing exact-geometry cache. Final jobs release
            // all Makeup masks/landmarks at the end of this invocation.
            let step = quality == .final ? MakeupProcessingStep() : makeup
            return try step.makeOutput(source: result, faces: makeupFaces ?? faces,
                                       configuration: configuration.makeup) ?? result
        }
    }

    private func processSkin(_ source: CIImage, faces: [DetectedFace], configuration: BeautyConfiguration,
                             quality: BeautyProcessingQuality) throws -> CIImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !configuration.isSkinBypassed, !faces.isEmpty else { return source }
        guard !source.extent.isEmpty, !source.extent.isInfinite, !source.extent.isNull else {
            throw Failure.invalidExtent
        }
        let geometry = Self.geometry(from: faces)
        guard !geometry.regions.isEmpty else { return source }
        let cache = quality == .final && reuseFinalGeometry
            ? SkinGeometryCache(source: source, regions: geometry.regions, landmarks: geometry.landmarks) : nil
        var image = source

        if configuration.effectiveSmoothing > 0 {
            let config = try skinConfiguration(intensity: configuration.effectiveSmoothing,
                detailRetention: quality == .preview
                    ? BeautyEffectAmplitude.previewSmoothingDetailRetention
                    : BeautyEffectAmplitude.finalSmoothingDetailRetention,
                noiseReduction: quality == .preview ? 0.006 : 0.015,
                toneStrength: 0, luminanceCorrection: 0)
            let step = TexturePreservingSkinSmoothingStep(configuration: config)
            if let output = try step.makeOutput(source: image, regions: geometry.regions,
                                                landmarks: geometry.landmarks, geometryCache: cache) {
                image = output
            }
        }

        if configuration.effectiveBrightening > 0 {
            let config = try skinConfiguration(intensity: configuration.effectiveBrightening,
                detailRetention: 0.94, noiseReduction: 0, toneStrength: 0, luminanceCorrection: 0)
            let masks = TexturePreservingSkinSmoothingStep(configuration: config)
            if let effective = try masks.makeMasks(source: image, regions: geometry.regions,
                                                   landmarks: geometry.landmarks, geometryCache: cache)?.effectiveSkinMask {
                let adjusted = try CoreImageRendering.filter("CIColorControls", parameters: [
                    kCIInputImageKey: image,
                    kCIInputBrightnessKey: BeautyEffectAmplitude.brightening,
                    kCIInputSaturationKey: 1.0,
                    kCIInputContrastKey: 1.0
                ], in: image.extent)
                image = try CoreImageRendering.blend(adjusted, over: image, mask: effective)
            }
        }

        if configuration.effectiveTone > 0 {
            let config = try skinConfiguration(intensity: configuration.effectiveTone,
                detailRetention: 0.94, noiseReduction: 0,
                toneStrength: quality == .preview
                    ? BeautyEffectAmplitude.previewToneConsistency
                    : BeautyEffectAmplitude.finalToneConsistency,
                luminanceCorrection: quality == .preview ? 0.004 : 0.006)
            let masks = TexturePreservingSkinSmoothingStep(configuration: config)
            if let effective = try masks.makeMasks(source: image, regions: geometry.regions,
                                                   landmarks: geometry.landmarks, geometryCache: cache)?.effectiveSkinMask,
               let output = try NaturalSkinToneAdjustmentStep(configuration: config).makeOutput(
                    source: image, regions: geometry.regions, effectiveSkinMask: effective) {
                image = output
            }
        }
        // Detect protection from the original pixels so base smoothing cannot erase
        // edges that these local corrections must preserve. Share it between both.
        if configuration.effectiveBlemish > 0 || configuration.effectiveDarkCircles > 0,
           let mask = try LocalSkinCorrection.effectiveMask(source: source,
                regions: geometry.regions, landmarks: geometry.landmarks, geometryCache: cache) {
            if let output = try BlemishAttenuationStep().makeOutput(source: image,
                regions: geometry.regions, landmarks: geometry.landmarks, effectiveSkinMask: mask,
                strength: configuration.effectiveBlemish, quality: quality) {
                image = output
            }
            if let output = try DarkCircleCorrectionStep().makeOutput(source: image,
                regions: geometry.regions, landmarks: geometry.landmarks, effectiveSkinMask: mask,
                strength: configuration.effectiveDarkCircles, quality: quality) {
                image = output
            }
        }
        return image.cropped(to: source.extent)
    }

    private func skinConfiguration(intensity: Double, detailRetention: Double,
                                   noiseReduction: Double, toneStrength: Double,
                                   luminanceCorrection: Double) throws -> SkinRetouchConfiguration {
        try SkinRetouchConfiguration(intensity: SkinRetouchIntensity(intensity),
            detailRetention: detailRetention, noiseReductionStrength: noiseReduction,
            edgeProtectionStrength: 1, toneConsistencyStrength: toneStrength,
            maxLuminanceCorrection: luminanceCorrection)
    }

    private static func geometry(from faces: [DetectedFace]) ->
        (regions: [FaceRegion], landmarks: [FacialLandmarks]) {
        var regions: [FaceRegion] = []
        var landmarks: [FacialLandmarks] = []
        for face in faces {
            // Beauty deliberately owns geometry separate from face correction. Vision's
            // face box often ends below the upper forehead, so extend it upward by 15%
            // and sideways by 5%, then clamp it to the oriented image.
            let box = face.boundingBox
            let beautyBox = clamped(CGRect(x: box.minX - box.width * 0.05,
                                           y: box.minY,
                                           width: box.width * 1.10,
                                           height: box.height * 1.15))
            guard let region = try? FaceRegion(boundingBox: beautyBox) else { continue }
            regions.append(region)
            var local: [FacialLandmarkRegion: [CGPoint]] = [:]
            for (name, points) in face.landmarks {
                local[name] = points.map {
                    CGPoint(x: ($0.x - beautyBox.minX) / beautyBox.width,
                            y: ($0.y - beautyBox.minY) / beautyBox.height)
                }
            }
            landmarks.append(FacialLandmarks(region: region, features: local))
        }
        return (regions, landmarks)
    }

    static func reorientedFaces(_ faces: [DetectedFace], from source: FaceImageOrientation,
                                to destination: FaceImageOrientation,
                                mirrored: Bool) -> [DetectedFace] {
        faces.compactMap { face in
            let corners = corners(of: face.boundingBox).map {
                FaceCoordinates.reorient($0, from: source, to: destination, mirrored: mirrored)
            }
            guard let box = boundingRect(corners) else { return nil }
            var landmarks: [FacialLandmarkRegion: [CGPoint]] = [:]
            for (name, points) in face.landmarks {
                landmarks[name] = points.map {
                    FaceCoordinates.reorient($0, from: source, to: destination, mirrored: mirrored)
                }
            }
            return DetectedFace(boundingBox: clamped(box), confidence: face.confidence,
                                landmarks: landmarks)
        }
    }

    private static func transformedFaces(_ faces: [DetectedFace], sourceExtent: CGRect,
                                         transform: CGAffineTransform,
                                         outputExtent: CGRect) -> [DetectedFace] {
        func transformed(_ point: CGPoint) -> CGPoint {
            let absolute = CGPoint(x: sourceExtent.minX + point.x * sourceExtent.width,
                                   y: sourceExtent.minY + point.y * sourceExtent.height)
                .applying(transform)
            return CGPoint(x: (absolute.x - outputExtent.minX) / outputExtent.width,
                           y: (absolute.y - outputExtent.minY) / outputExtent.height)
        }
        return faces.compactMap { face in
            let corners = corners(of: face.boundingBox).map(transformed)
            guard let box = boundingRect(corners) else { return nil }
            var landmarks: [FacialLandmarkRegion: [CGPoint]] = [:]
            for (name, points) in face.landmarks { landmarks[name] = points.map(transformed) }
            return DetectedFace(boundingBox: clamped(box), confidence: face.confidence,
                                landmarks: landmarks)
        }
    }

    private static func fittedFaces(_ faces: [DetectedFace], sourceExtent: CGRect,
                                    targetExtent: CGRect, transform: CGAffineTransform) -> [DetectedFace] {
        faces.compactMap { face in
            let sourceBox = CGRect(x: face.boundingBox.minX * sourceExtent.width,
                                   y: face.boundingBox.minY * sourceExtent.height,
                                   width: face.boundingBox.width * sourceExtent.width,
                                   height: face.boundingBox.height * sourceExtent.height)
            let fitted = sourceBox.applying(transform).intersection(targetExtent)
            guard !fitted.isNull, fitted.width >= 1, fitted.height >= 1 else { return nil }
            let normalized = CGRect(x: fitted.minX / targetExtent.width,
                                    y: fitted.minY / targetExtent.height,
                                    width: fitted.width / targetExtent.width,
                                    height: fitted.height / targetExtent.height)
            var landmarks: [FacialLandmarkRegion: [CGPoint]] = [:]
            for (name, points) in face.landmarks {
                landmarks[name] = points.compactMap { point in
                    let fittedPoint = CGPoint(x: point.x * sourceExtent.width,
                                              y: point.y * sourceExtent.height).applying(transform)
                    guard targetExtent.insetBy(dx: -0.5, dy: -0.5).contains(fittedPoint) else { return nil }
                    return CGPoint(x: min(1, max(0, fittedPoint.x / targetExtent.width)),
                                   y: min(1, max(0, fittedPoint.y / targetExtent.height)))
                }
            }
            return DetectedFace(boundingBox: clamped(normalized), confidence: face.confidence,
                                landmarks: landmarks)
        }
    }

    private static func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    private static func boundingRect(_ points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min() ?? first.x, y: ys.min() ?? first.y,
                      width: (xs.max() ?? first.x) - (xs.min() ?? first.x),
                      height: (ys.max() ?? first.y) - (ys.min() ?? first.y))
    }

    private static func clamped(_ rect: CGRect) -> CGRect {
        let minX = min(1, max(0, rect.minX)), minY = min(1, max(0, rect.minY))
        let maxX = min(1, max(0, rect.maxX)), maxY = min(1, max(0, rect.maxY))
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}
