import CoreImage
import Foundation

/// Experimental local tone adjustment, currently invoked only by DEBUG tooling.
/// No spatial smoothing, whitening algorithm or geometry changes. Facial texture
/// is retained because CIColorControls does not mix neighboring source pixels.
struct NaturalSkinProcessingStep: ImageProcessingStep {
    private let maskGenerator: any FaceMaskGenerating

    init(maskGenerator: any FaceMaskGenerating = SoftFaceMaskGenerator()) {
        self.maskGenerator = maskGenerator
    }

    func process(_ image: ProcessingImage, regions: [FaceRegion]) throws -> ProcessingImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !regions.isEmpty else { return image }
        let source = CIImage(cgImage: image.cgImage)
        guard let mask = try maskGenerator.makeMask(regions: regions, in: source.extent) else { return image }
        guard let controls = CIFilter(name: "CIColorControls", parameters: [
            kCIInputImageKey: source,
            kCIInputBrightnessKey: 0.008,
            kCIInputSaturationKey: 1.005,
            kCIInputContrastKey: 1.0
        ]), let adjusted = controls.outputImage else { throw CoreImageRendering.Failure.filterUnavailable }
        // A single adjustment graph and blend for all faces; black mask preserves
        // the source. The original CGImage is immutable and is never overwritten.
        let composite = try CoreImageRendering.blend(adjusted, over: source, mask: mask)
        return try CoreImageRendering.render(composite, matching: image)
    }
}
