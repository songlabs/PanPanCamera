#if DEBUG
import CoreImage
import Foundation

/// Black-background white-coverage preview, never a product or saved photo output.
struct DebugFaceMaskStep: ImageProcessingStep {
    func process(_ image: ProcessingImage, regions: [FaceRegion]) throws -> ProcessingImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let extent = CGRect(x: 0, y: 0, width: CGFloat(image.cgImage.width), height: CGFloat(image.cgImage.height))
        let mask = try SoftFaceMaskGenerator().makeMask(regions: regions, in: extent)
            ?? CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: extent)
        return try CoreImageRendering.render(mask, matching: image)
    }
}
#endif
