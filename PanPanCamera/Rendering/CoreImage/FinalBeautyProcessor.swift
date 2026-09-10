import CoreImage
import Foundation
import ImageIO

/// High-quality capture worker. It never receives a preview screenshot and never
/// changes the native source dimensions; only orientation may swap width/height.
final class FinalBeautyProcessor: @unchecked Sendable {
    private let detector = VisionFaceDetector()
    private let processor = BeautyImageProcessor()
    private let silentEncoder = SilentFrameEncoder()

    func processPhotoData(_ data: Data, configuration: BeautyConfiguration) -> Data? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        // Face Correction is intentionally Preview-only in this task.
        guard !configuration.isPhotoBypassed else { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        let rawOrientation = (metadata[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
        do {
            let faces = try detector.detect(image, orientation: orientation)
            // No detected face means an exact original-data bypass, not a needless JPEG generation.
            guard !faces.isEmpty else { return data }
            var input = CIImage(cgImage: image).oriented(orientation)
            input = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX,
                                                            y: -input.extent.minY))
            let output = try processor.process(input, faces: faces, configuration: configuration,
                                               quality: .final)
            return encode(output, metadata: metadata,
                          type: CGImageSourceGetType(source) ?? ("public.jpeg" as CFString))
        } catch {
            return nil
        }
    }

    func processSilentFrame(_ frame: SilentFrame, configuration: BeautyConfiguration) -> Data? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        // Face Correction is intentionally Preview-only in this task.
        guard !configuration.isPhotoBypassed else { return silentEncoder.encode(frame) }
        do {
            let detected = try detector.detect(frame.pixelBuffer, orientation: frame.orientation)
            guard !detected.isEmpty else { return silentEncoder.encode(frame) }
            let faces = BeautyImageProcessor.reorientedFaces(detected, from: frame.orientation,
                to: frame.orientation, mirrored: frame.mirrored)
            let exif = SilentFrameOrientation.exif(captureOrientation: frame.orientation,
                                                   mirrored: frame.mirrored)
            var input = CIImage(cvPixelBuffer: frame.pixelBuffer).oriented(exif)
            input = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX,
                                                            y: -input.extent.minY))
            let output = try processor.process(input, faces: faces, configuration: configuration,
                                               quality: .final)
            return encode(output, metadata: frame.metadata, type: "public.jpeg" as CFString)
        } catch {
            return nil
        }
    }

    private func encode(_ image: CIImage, metadata originalMetadata: [String: Any],
                        type: CFString) -> Data? {
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cgImage = CoreImageRendering.createCGImage(image, colorSpace: colorSpace) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        var metadata = originalMetadata
        metadata[kCGImagePropertyOrientation as String] = CGImagePropertyOrientation.up.rawValue
        metadata[kCGImagePropertyPixelWidth as String] = cgImage.width
        metadata[kCGImagePropertyPixelHeight as String] = cgImage.height
        metadata[kCGImageDestinationLossyCompressionQuality as String] = 1.0
        if var exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = cgImage.width
            exif[kCGImagePropertyExifPixelYDimension as String] = cgImage.height
            metadata[kCGImagePropertyExifDictionary as String] = exif
        }
        CGImageDestinationAddImage(destination, cgImage, metadata as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
