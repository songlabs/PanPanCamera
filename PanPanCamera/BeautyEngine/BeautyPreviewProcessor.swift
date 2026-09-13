import CoreImage
import Foundation

/// One transform is applied to all semantic landmark regions. Final capture
/// already has normalized pixels and therefore never uses preview aspect-fill.
struct BeautyPreviewProcessor {
    private let processor = BeautyProcessor()

    func previewImage(for frame: BeautyPreviewFrame, displayRotationAngle: CGFloat,
                      targetSize: CGSize) throws -> CIImage? {
        try previewResult(for: frame, displayRotationAngle: displayRotationAngle, targetSize: targetSize).image
    }

    func previewResult(for frame: BeautyPreviewFrame, displayRotationAngle: CGFloat,
                       targetSize: CGSize, includeDebug: Bool = FaceAnalysisDebugMode.isEnabled) throws -> BeautyPreviewProcessingResult {
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
        let usableFaces = mapped?.outcome == .analyzed ? faces : []
        var debug: FaceAnalysisDebugSnapshot?
        if includeDebug {
            debug = FaceAnalysisDebugSnapshot(extent: target,
                boxes: usableFaces.map(\.boundingBox), rois: usableFaces.compactMap { SkinFaceROI(face: $0)?.bounds },
                points: usableFaces.flatMap { $0.landmarks.points },
                contours: usableFaces.compactMap { $0.landmarks[.faceContour] },
                configuration: frame.configuration, captureOrientation: frame.orientation,
                displayOrientation: display, displayRotationAngle: displayRotationAngle, mirrored: frame.mirrored)
            if frame.configuration.isBypassed {
                debug?.geometry = FaceCorrectionGeometry.result(faces: usableFaces,
                    configuration: frame.configuration, extent: target)
            }
        }
        let observe: ((CIImage?, FaceCorrectionGeometryResult, [FaceCorrectionGeometry.EyeAdjustment]) -> Void)? =
            debug == nil ? nil : { mask, geometry, eyes in
                debug?.geometry = geometry
                debug?.eyes = eyes
                if FaceAnalysisDebugMode.skin, let mask {
                    debug?.skinImage = try? Self.skinDebugImage(mask)
                }
            }
        let output = try processor.process(image, analysis: mapped, configuration: frame.configuration,
            quality: .preview, previewDebug: observe)
        return BeautyPreviewProcessingResult(image: output === image ? nil : output, analysisDebug: debug)
    }

    /// Read back only a tiny version of the EXISTING scalar mask, never camera pixels.
    /// Green alpha belongs to a CALayer above Preview, not the Beauty output image.
    private static func skinDebugImage(_ mask: CIImage) throws -> CGImage? {
        let scale = min(1, 160 / max(mask.extent.width, mask.extent.height))
        let small = mask.transformed(by: CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: -mask.extent.minX * scale, ty: -mask.extent.minY * scale))
        let colored = try CoreImageRendering.filter("CIColorMatrix", parameters: [
            kCIInputImageKey: small,
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0.35, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 1, z: 0, w: 0)
        ], in: small.extent)
        return CoreImageRendering.createCGImage(colored, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
