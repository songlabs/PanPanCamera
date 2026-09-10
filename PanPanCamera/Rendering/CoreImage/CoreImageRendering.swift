import CoreImage
import Foundation
import AVFoundation
import ImageIO
import Metal

final class SilentFrameEncoder: @unchecked Sendable {
    func encode(_ frame: SilentFrame) -> Data? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let orientation = SilentFrameOrientation.exif(captureOrientation: frame.orientation,
                                                      mirrored: frame.mirrored)
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer).oriented(orientation)
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cgImage = CoreImageRendering.createCGImage(image, colorSpace: colorSpace) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        var metadata = frame.metadata
        metadata[kCGImagePropertyOrientation as String] = CGImagePropertyOrientation.up.rawValue
        metadata[kCGImageDestinationLossyCompressionQuality as String] = 1.0
        CGImageDestinationAddImage(destination, cgImage, metadata as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Shared by the experimental step and DEBUG probes. First initialized on a worker;
/// filters/graphs remain job-local and the context keeps no intermediate image cache.
enum CoreImageRendering {
    enum Failure: Error { case filterUnavailable, renderFailed }

    // Apple's default working space is extended linear sRGB on the supported OS.
    // Preserve it: TonePolicy uses linear sRGB luminance, while render() retains
    // the input CGImage's output color space. Do not disable color management.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func createCGImage(_ image: CIImage, colorSpace: CGColorSpace?) -> CGImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return context.createCGImage(image, from: image.extent, format: .RGBA8,
                                     colorSpace: colorSpace, deferred: false)
    }

    /// Metal destinations require a Metal-backed context on the destination device.
    /// Keep one per Preview renderer, initialized on its worker and reused across frames.
    /// The shared bitmap/photo context above retains its existing backend and behavior.
    final class MetalRenderer {
        private let context: CIContext

        init(device: MTLDevice) {
            dispatchPrecondition(condition: .notOnQueue(.main))
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }

        func render(_ image: CIImage, to texture: MTLTexture, commandBuffer: MTLCommandBuffer,
                    bounds: CGRect, colorSpace: CGColorSpace) {
            dispatchPrecondition(condition: .notOnQueue(.main))
            context.render(image, to: texture, commandBuffer: commandBuffer,
                           bounds: bounds, colorSpace: colorSpace)
        }
    }

    static func filter(_ name: String, parameters: [String: Any], in extent: CGRect) throws -> CIImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let filter = CIFilter(name: name, parameters: parameters),
              let output = filter.outputImage else { throw Failure.filterUnavailable }
        return output.cropped(to: extent)
    }

    /// Red-channel scalar arithmetic for opaque grayscale masks, explicitly bounded.
    static func grayMask(_ image: CIImage, scale: Double, bias: Double = 0) throws -> CIImage {
        let vector = CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0)
        let adjusted = try filter("CIColorMatrix", parameters: [
            kCIInputImageKey: image,
            "inputRVector": vector, "inputGVector": vector, "inputBVector": vector,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: CGFloat(bias), y: CGFloat(bias), z: CGFloat(bias), w: 1)
        ], in: image.extent)
        return try filter("CIColorClamp", parameters: [
            kCIInputImageKey: adjusted,
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ], in: image.extent)
    }

    static func blend(_ adjusted: CIImage, over source: CIImage, mask: CIImage) throws -> CIImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let filter = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: adjusted,
            kCIInputBackgroundImageKey: source,
            kCIInputMaskImageKey: mask
        ]), let output = filter.outputImage else { throw Failure.filterUnavailable }
        return output.cropped(to: source.extent)
    }

    static func render(_ image: CIImage, matching original: ProcessingImage) throws -> ProcessingImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let extent = CGRect(x: 0, y: 0, width: CGFloat(original.cgImage.width), height: CGFloat(original.cgImage.height))
        guard let rendered = context.createCGImage(image.cropped(to: extent), from: extent, format: .RGBA8,
                                                   colorSpace: original.cgImage.colorSpace,
                                                   deferred: false) else { throw Failure.renderFailed }
        return ProcessingImage(cgImage: rendered)
    }
}
