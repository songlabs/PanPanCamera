import CoreImage
import Foundation

enum BeautyProcessingQuality: Equatable, Sendable { case preview, final }

/// Shared skin-effect definition plus Preview-only face geometry. Preview supplies
/// a smaller aspect-filled image while final capture supplies native photo pixels;
/// Face Correction deliberately stops at the Preview boundary.
struct BeautyImageProcessor: Sendable {
    enum Failure: Error { case invalidExtent }
    private let faceCorrection = FaceCorrectionPreviewStep()

    func previewImage(for frame: BeautyPreviewFrame, displayRotationAngle: CGFloat,
                      targetSize: CGSize) throws -> CIImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !frame.configuration.isBypassed, !frame.faces.isEmpty,
              targetSize.width >= 1, targetSize.height >= 1 else { return nil }

        guard let displayOrientation = FaceImageOrientation(captureAngle: displayRotationAngle) else {
            return nil
        }
        let exif = SilentFrameOrientation.exif(captureOrientation: displayOrientation, mirrored: false)
        var image = CIImage(cvPixelBuffer: frame.pixelBuffer).oriented(exif)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                        y: -image.extent.minY))
        var orientedFaces = Self.reorientedFaces(frame.faces, from: frame.orientation,
                                                 to: displayOrientation, mirrored: false)
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
            image = rotated.transformed(by: translation)
        }
        if frame.mirrored {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                                                            tx: image.extent.width, ty: 0))
            orientedFaces = Self.reorientedFaces(orientedFaces, from: displayOrientation,
                                                 to: displayOrientation, mirrored: true)
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
        guard !fittedFaces.isEmpty else { return nil }
        let skinResult = try process(image, faces: fittedFaces, configuration: frame.configuration,
                                     quality: .preview)
        if let faceResult = try faceCorrection.makeOutput(
            source: skinResult, faces: fittedFaces, configuration: frame.configuration
        ) {
            return faceResult
        }
        // If only Face Correction is active but usable landmarks are unavailable,
        // keep the original AVCaptureVideoPreviewLayer visible instead of rendering raw pixels again.
        return frame.configuration.isPhotoBypassed ? nil : skinResult
    }

    func process(_ source: CIImage, faces: [DetectedFace], configuration: BeautyConfiguration,
                 quality: BeautyProcessingQuality) throws -> CIImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !configuration.isPhotoBypassed, !faces.isEmpty else { return source }
        guard !source.extent.isEmpty, !source.extent.isInfinite, !source.extent.isNull else {
            throw Failure.invalidExtent
        }
        let geometry = Self.geometry(from: faces)
        guard !geometry.regions.isEmpty else { return source }
        var image = source

        if configuration.effectiveSmoothing > 0 {
            let config = try skinConfiguration(intensity: configuration.effectiveSmoothing,
                detailRetention: quality == .preview ? 0.94 : 0.9,
                noiseReduction: quality == .preview ? 0.006 : 0.015,
                toneStrength: 0, luminanceCorrection: 0)
            let step = TexturePreservingSkinSmoothingStep(configuration: config)
            if let output = try step.makeOutput(source: image, regions: geometry.regions,
                                                landmarks: geometry.landmarks) {
                image = output
            }
        }

        if configuration.effectiveBrightening > 0 {
            let config = try skinConfiguration(intensity: configuration.effectiveBrightening,
                detailRetention: 0.94, noiseReduction: 0, toneStrength: 0, luminanceCorrection: 0)
            let masks = TexturePreservingSkinSmoothingStep(configuration: config)
            if let effective = try masks.makeMasks(source: image, regions: geometry.regions,
                                                   landmarks: geometry.landmarks)?.effectiveSkinMask {
                let adjusted = try CoreImageRendering.filter("CIColorControls", parameters: [
                    kCIInputImageKey: image,
                    kCIInputBrightnessKey: 0.03,
                    kCIInputSaturationKey: 1.0,
                    kCIInputContrastKey: 1.0
                ], in: image.extent)
                image = try CoreImageRendering.blend(adjusted, over: image, mask: effective)
            }
        }

        if configuration.effectiveTone > 0 {
            let config = try skinConfiguration(intensity: configuration.effectiveTone,
                detailRetention: 0.94, noiseReduction: 0,
                toneStrength: quality == .preview ? 0.2 : 0.25,
                luminanceCorrection: quality == .preview ? 0.004 : 0.006)
            let masks = TexturePreservingSkinSmoothingStep(configuration: config)
            if let effective = try masks.makeMasks(source: image, regions: geometry.regions,
                                                   landmarks: geometry.landmarks)?.effectiveSkinMask,
               let output = try NaturalSkinToneAdjustmentStep(configuration: config).makeOutput(
                    source: image, regions: geometry.regions, effectiveSkinMask: effective) {
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
            guard let region = try? FaceRegion(boundingBox: clamped(face.boundingBox)) else { continue }
            regions.append(region)
            var local: [FacialLandmarkRegion: [CGPoint]] = [:]
            for (name, points) in face.landmarks {
                local[name] = points.map {
                    CGPoint(x: ($0.x - face.boundingBox.minX) / face.boundingBox.width,
                            y: ($0.y - face.boundingBox.minY) / face.boundingBox.height)
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
