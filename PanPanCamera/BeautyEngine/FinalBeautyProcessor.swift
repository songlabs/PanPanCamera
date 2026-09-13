import CoreImage
import Foundation
import ImageIO

/// One final analysis/Beauty path shared by both native acquisition sources.
/// No preview mask, resize of final pixels, or additional mirror transform.
final class FinalBeautyProcessor: @unchecked Sendable {
    private let engine: FaceAnalysisEngine
    private let processor = BeautyProcessor()
    private let silentEncoder = SilentFrameEncoder()
    private let encodeImage: (CGImage, [String: Any], CFString) -> Data?
    private let renderImage: (CIImage, CGColorSpace?, PhotoCaptureDiagnostics) -> CGImage?

    init(engine: FaceAnalysisEngine = FaceAnalysisEngine(),
         encodeImage: @escaping (CGImage, [String: Any], CFString) -> Data? = FinalBeautyProcessor.encodeImage,
         renderImage: @escaping (CIImage, CGColorSpace?, PhotoCaptureDiagnostics) -> CGImage?
            = CoreImageRendering.createFinalCGImage) {
        self.engine = engine; self.encodeImage = encodeImage; self.renderImage = renderImage
    }

    func processPhotoData(_ data: Data, configuration: BeautyConfiguration,
                          diagnostics: PhotoCaptureDiagnostics = .disabled) -> Data? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !configuration.isPhotoBypassed else { return data }
        let decoded = diagnostics.measure("decode") { () -> (CGImageSource, CGImage)? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return (source, image)
        }
        guard let (source, image) = decoded else { diagnostics.mark("decode_failed"); return nil }
        let metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        let raw = (metadata[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let exif = CGImagePropertyOrientation(rawValue: raw) ?? .up
        do {
            let processed = try processSource(CIImage(cgImage: image), exif: exif,
                configuration: configuration, diagnostics: diagnostics)
            guard let output = processed else { return data }
            return encode(output, metadata: metadata,
                type: CGImageSourceGetType(source) ?? ("public.jpeg" as CFString), diagnostics: diagnostics)
        } catch { diagnostics.mark("final_beauty_failed"); return nil }
    }

    func processSilentFrame(_ frame: SilentFrame, configuration: BeautyConfiguration,
                            diagnostics: PhotoCaptureDiagnostics = .disabled) -> Data? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !configuration.isPhotoBypassed else { return encodeSilentFrame(frame, diagnostics: diagnostics) }
        do {
            let processed = try processSource(CIImage(cvPixelBuffer: frame.pixelBuffer),
                exif: SilentFrameOrientation.exif(captureOrientation: frame.orientation, mirrored: frame.mirrored),
                configuration: configuration, diagnostics: diagnostics)
            guard let output = processed else { return encodeSilentFrame(frame, diagnostics: diagnostics) }
            return encode(output, metadata: frame.metadata, type: "public.jpeg" as CFString, diagnostics: diagnostics)
        } catch { diagnostics.mark("final_beauty_failed"); return nil }
    }

    /// nil means unchanged normalized pixels; the caller preserves its original
    /// data/encoder path. Analysis failure is independent of global filter execution.
    func processSource(_ source: CIImage, exif: CGImagePropertyOrientation,
                       configuration: BeautyConfiguration, diagnostics: PhotoCaptureDiagnostics = .disabled) throws -> CIImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let input = FaceImageNormalization.normalize(source, exif: exif)
        let metadata = FaceImageNormalization.metadata(exif)
        let analysis = configuration.requiresFaceDetection ? diagnostics.measure("face_analysis") {
            engine.analyze(input, timestamp: ProcessInfo.processInfo.systemUptime,
                           orientation: metadata.0, mirrored: metadata.1)
        } : nil
        let output = try processor.process(input, analysis: analysis, configuration: configuration,
                                           quality: .final, diagnostics: diagnostics)
        return output === input ? nil : output
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
