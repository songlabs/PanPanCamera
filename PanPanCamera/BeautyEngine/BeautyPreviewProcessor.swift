import CoreImage
import Foundation

/// One transform is applied to dense points and semantic rasters. Final capture
/// already has normalized pixels and therefore never uses preview aspect-fill.
struct BeautyPreviewProcessor {
    private let processor = BeautyProcessor()

    func previewImage(for frame: BeautyPreviewFrame, displayRotationAngle: CGFloat,
                      targetSize: CGSize) throws -> CIImage? {
        try previewResult(for: frame, displayRotationAngle: displayRotationAngle, targetSize: targetSize).image
    }

    func previewResult(for frame: BeautyPreviewFrame, displayRotationAngle: CGFloat,
                       targetSize: CGSize) throws -> BeautyPreviewProcessingResult {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard targetSize.width >= 1, targetSize.height >= 1,
              targetSize.width.isFinite, targetSize.height.isFinite,
              let display = FaceImageOrientation(captureAngle: displayRotationAngle)
        else { return BeautyPreviewProcessingResult(image: nil, analysisDebug: nil) }
        let exif = SilentFrameOrientation.exif(captureOrientation: display, mirrored: false)
        var image = FaceImageNormalization.normalize(CIImage(cvPixelBuffer: frame.pixelBuffer), exif: exif)
        let analysis = frame.analysis
        var map = FaceAnalysisCoordinates.reorientation(from: analysis?.orientation ?? frame.orientation,
            sourceMirrored: analysis?.mirrored ?? false, to: display, mirrored: false)

        func appendPixelTransform(_ transform: CGAffineTransform, from source: CGRect, to output: CGRect) {
            map = map.then(.unitToRect(source))
                .then(FaceAnalysisTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d,
                                           tx: transform.tx, ty: transform.ty))
                .then(FaceAnalysisTransform(a: 1 / output.width, d: 1 / output.height,
                                           tx: -output.minX / output.width, ty: -output.minY / output.height))
        }

        let normalizedAngle = (displayRotationAngle.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        var residual = normalizedAngle - CGFloat(display.rawValue)
        if residual > 180 { residual -= 360 }
        if residual < -180 { residual += 360 }
        if abs(residual) > 0.01 {
            let extent = image.extent
            let rotation = CGAffineTransform(translationX: extent.midX, y: extent.midY)
                .rotated(by: -residual * .pi / 180).translatedBy(x: -extent.midX, y: -extent.midY)
            let rotated = image.transformed(by: rotation)
            appendPixelTransform(rotation, from: extent, to: rotated.extent)
            image = rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
        }
        if frame.mirrored {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: image.extent.width, ty: 0))
            map = map.then(FaceAnalysisTransform(a: -1, tx: 1))
        }
        let target = CGRect(origin: .zero, size: targetSize)
        let extent = image.extent
        let scale = max(target.width / extent.width, target.height / extent.height)
        let fit = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: (target.width - extent.width * scale) / 2, ty: (target.height - extent.height * scale) / 2)
        appendPixelTransform(fit, from: extent, to: target)
        image = image.transformed(by: fit).cropped(to: target)
        let faces = FaceAnalysisCoordinates.map(analysis?.faces ?? [], by: map)
        let mapped = analysis.map { FaceAnalysisResult(timestamp: $0.timestamp, imageSize: targetSize,
            orientation: display, mirrored: frame.mirrored, faces: faces, outcome: $0.outcome) }
        let debug = FaceAnalysisDebugMode.isEnabled ? FaceAnalysisDebugSnapshot(extent: target,
            boxes: faces.map(\.boundingBox), points: faces.flatMap { $0.landmarks.points }) : nil
        var output = try processor.process(image, analysis: mapped, configuration: frame.configuration, quality: .preview)
        #if DEBUG
        output = try debugMasks(output, faces: faces)
        #endif
        return BeautyPreviewProcessingResult(image: output === image ? nil : output, analysisDebug: debug)
    }

    #if DEBUG
    private func debugMasks(_ source: CIImage, faces: [AnalyzedFace]) throws -> CIImage {
        var image = source
        let selected: [(FaceSemanticClass, CIColor)] = FaceAnalysisDebugMode.parsing
            ? [(.skin, .green), (.hair, .blue), (.leftEye, .red), (.rightEye, .red),
               (.leftEyebrow, .yellow), (.rightEyebrow, .yellow), (.lips, .magenta), (.glasses, .cyan)]
            : (FaceAnalysisDebugMode.skin ? [(.skin, CIColor.green)] : []) +
              (FaceAnalysisDebugMode.hair ? [(.hair, CIColor.blue)] : [])
        for face in faces {
            for (name, color) in selected {
                guard let plane = face.semanticMasks?.planes[name] else { continue }
                let mask = try CoreImageRendering.grayMask(FaceSemanticRaster.image(plane, in: source.extent), scale: 0.6)
                image = try CoreImageRendering.blend(CIImage(color: color).cropped(to: source.extent), over: image, mask: mask)
            }
        }
        return image
    }
    #endif
}
