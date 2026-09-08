#if DEBUG
import CoreImage
import Foundation

/// DEVELOPMENT / TEST ONLY: a +0.01 brightness probe, not a beauty feature.
/// Removing this step restores the unmodified input; the source is never overwritten.
struct DebugFaceBrightnessStep: ImageProcessingStep {
    typealias Failure = CoreImageRendering.Failure

    func process(_ image: ProcessingImage, regions: [FaceRegion]) throws -> ProcessingImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !regions.isEmpty else { return image }
        let source = CIImage(cgImage: image.cgImage)
        let extent = source.extent
        // Round INWARD: only whole pixels inside a face rectangle may be changed.
        let rects = regions.compactMap { region -> CGRect? in
            let rect = region.imageRect(in: extent)
            guard !rect.isNull else { return nil }
            let x = ceil(rect.minX), y = ceil(rect.minY)
            let width = floor(rect.maxX) - x, height = floor(rect.maxY) - y
            guard width > 0, height > 0 else { return nil }
            return CGRect(x: x, y: y, width: width, height: height).intersection(extent)
        }
        guard !rects.isEmpty else { return image }
        guard let adjustment = CIFilter(name: "CIColorControls") else { throw Failure.filterUnavailable }
        adjustment.setValue(source, forKey: kCIInputImageKey)
        adjustment.setValue(0.01, forKey: kCIInputBrightnessKey)
        guard let adjusted = adjustment.outputImage else { throw Failure.filterUnavailable }

        var mask = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
        // Union mask: overlapping faces receive the adjustment once, preserving alpha.
        for rect in rects { mask = white.cropped(to: rect).composited(over: mask) }
        let composite = try CoreImageRendering.blend(adjusted, over: source, mask: mask)
        return try CoreImageRendering.render(composite, matching: image)
    }
}
#endif
