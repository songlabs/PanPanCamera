import CoreImage
import Foundation

/// Shared by the experimental step and DEBUG probes. First initialized on a worker;
/// filters/graphs remain job-local and the context keeps no intermediate image cache.
enum CoreImageRendering {
    enum Failure: Error { case filterUnavailable, renderFailed }

    // Apple's default working space is extended linear sRGB on the supported OS.
    // Preserve it: TonePolicy uses linear sRGB luminance, while render() retains
    // the input CGImage's output color space. Do not disable color management.
    private static let context = CIContext(options: [.cacheIntermediates: false])

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
