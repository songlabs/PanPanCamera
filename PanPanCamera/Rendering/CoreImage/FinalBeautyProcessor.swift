import CoreImage
import Foundation
import ImageIO

/// High-quality capture worker. It never receives a preview screenshot and never
/// changes the native source dimensions; only orientation may swap width/height.
final class FinalBeautyProcessor: @unchecked Sendable {
    private let detectPhotoFaces: (CGImage, CGImagePropertyOrientation) throws -> [DetectedFace]
    private let detectFrameFaces: (CVPixelBuffer, FaceImageOrientation) throws -> [DetectedFace]
    private let processor = BeautyImageProcessor()
    private let silentEncoder = SilentFrameEncoder()
    private let encodeImage: (CGImage, [String: Any], CFString) -> Data?
    private let renderImage: (CIImage, CGColorSpace?, PhotoCaptureDiagnostics) -> CGImage?

    init(encodeImage: @escaping (CGImage, [String: Any], CFString) -> Data? = FinalBeautyProcessor.encodeImage,
         detectPhotoFaces: ((CGImage, CGImagePropertyOrientation) throws -> [DetectedFace])? = nil,
         detectFrameFaces: ((CVPixelBuffer, FaceImageOrientation) throws -> [DetectedFace])? = nil,
         renderImage: @escaping (CIImage, CGColorSpace?, PhotoCaptureDiagnostics) -> CGImage?
            = CoreImageRendering.createFinalCGImage) {
        self.encodeImage = encodeImage
        let detector = VisionFaceDetector()
        self.detectPhotoFaces = detectPhotoFaces ?? { try detector.detect($0, orientation: $1) }
        self.detectFrameFaces = detectFrameFaces ?? { try detector.detect($0, orientation: $1) }
        self.renderImage = renderImage
    }

    func processPhotoData(_ data: Data, configuration: BeautyConfiguration,
                          diagnostics: PhotoCaptureDiagnostics = .disabled) -> Data? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !configuration.isPhotoBypassed else {
            diagnostics.mark("bypass_original_data")
            diagnostics.mark("encoding_bypassed")
            return data
        }
        let decoded = diagnostics.measure("decode") { () -> (CGImageSource, CGImage)? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return (source, image)
        }
        guard let (source, image) = decoded else { diagnostics.mark("decode_failed"); return nil }
        diagnostics.value("decoded_width", image.width)
        diagnostics.value("decoded_height", image.height)
        let metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        let rawOrientation = (metadata[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
        do {
            let faces: [DetectedFace]
            if configuration.requiresFaceDetection {
                faces = try diagnostics.measure("vision") {
                    do { return try detectPhotoFaces(image, orientation) }
                    catch { diagnostics.mark("vision_failed"); throw error }
                }
            } else {
                diagnostics.mark("vision_skipped")
                faces = []
            }
            // Global filters work on scenes without faces. Face-only jobs retain
            // the exact original bytes when Vision finds no face.
            guard !faces.isEmpty || !configuration.filter.isBypassed else {
                diagnostics.mark("bypass_no_face")
                diagnostics.mark("encoding_bypassed")
                return data
            }
            var input = CIImage(cgImage: image).oriented(orientation)
            input = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX,
                                                            y: -input.extent.minY))
            let output = try processor.process(input, faces: faces, configuration: configuration,
                                               quality: .final, diagnostics: diagnostics)
            return encode(output, metadata: metadata,
                          type: CGImageSourceGetType(source) ?? ("public.jpeg" as CFString), diagnostics: diagnostics)
        } catch {
            diagnostics.mark("final_beauty_failed")
            return nil
        }
    }

    func processSilentFrame(_ frame: SilentFrame, configuration: BeautyConfiguration,
                            diagnostics: PhotoCaptureDiagnostics = .disabled) -> Data? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !configuration.isPhotoBypassed else {
            diagnostics.mark("bypass_silent_beauty")
            return encodeSilentFrame(frame, diagnostics: diagnostics)
        }
        do {
            let detected: [DetectedFace]
            if configuration.requiresFaceDetection {
                detected = try diagnostics.measure("vision") {
                    do { return try detectFrameFaces(frame.pixelBuffer, frame.orientation) }
                    catch { diagnostics.mark("vision_failed"); throw error }
                }
            } else {
                diagnostics.mark("vision_skipped")
                detected = []
            }
            guard !detected.isEmpty || !configuration.filter.isBypassed else {
                diagnostics.mark("bypass_no_face")
                return encodeSilentFrame(frame, diagnostics: diagnostics)
            }
            let faces = BeautyImageProcessor.reorientedFaces(detected, from: frame.orientation,
                to: frame.orientation, mirrored: frame.mirrored)
            let exif = SilentFrameOrientation.exif(captureOrientation: frame.orientation,
                                                   mirrored: frame.mirrored)
            var input = CIImage(cvPixelBuffer: frame.pixelBuffer).oriented(exif)
            input = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX,
                                                            y: -input.extent.minY))
            let output = try processor.process(input, faces: faces, configuration: configuration,
                                               quality: .final, diagnostics: diagnostics)
            return encode(output, metadata: frame.metadata, type: "public.jpeg" as CFString, diagnostics: diagnostics)
        } catch {
            diagnostics.mark("final_beauty_failed")
            return nil
        }
    }

    private func encode(_ image: CIImage, metadata originalMetadata: [String: Any],
                        type: CFString, diagnostics: PhotoCaptureDiagnostics) -> Data? {
        diagnostics.mark("encoding_start")
        defer { diagnostics.mark("encoding_end") }
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cgImage = diagnostics.measure("render", {
            renderImage(image, colorSpace, diagnostics)
        }) else { diagnostics.mark("render_failed"); return nil }
        let data = diagnostics.measure("encode") { encodeImage(cgImage, originalMetadata, type) }
        if data == nil { diagnostics.mark("encode_failed") }
        return data
    }

    private func encodeSilentFrame(_ frame: SilentFrame, diagnostics: PhotoCaptureDiagnostics) -> Data? {
        diagnostics.mark("encoding_start")
        defer { diagnostics.mark("encoding_end") }
        return silentEncoder.encode(frame, diagnostics: diagnostics)
    }

    static func encodeImage(_ cgImage: CGImage, metadata originalMetadata: [String: Any], type: CFString) -> Data? {
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
