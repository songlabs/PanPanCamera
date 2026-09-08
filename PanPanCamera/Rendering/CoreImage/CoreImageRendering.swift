import CoreImage
import Foundation

/// Shared by the experimental step and DEBUG probes. First initialized on a worker;
/// filters/graphs remain job-local and the context keeps no intermediate image cache.
enum CoreImageRendering {
    enum Failure: Error { case filterUnavailable, renderFailed }

    private static let context = CIContext(options: [.cacheIntermediates: false])

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
