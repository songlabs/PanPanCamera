#if DEBUG
import CoreImage
import Foundation
import ImageIO

/// Explicit developer/test entry point, absent from Release. No automatic capture
/// hook, launch flag or product UI. Call with an existing CapturedPhoto or test data.
/// Returned pixels are a development preview (maximum 2048), not a replacement for
/// the original photo. No image/face data is logged, uploaded, saved or retained here.
enum DebugPhotoProcessing {
    enum Failure: Error { case invalidImageData, decodeFailed }
    enum Output: Sendable {
        case original, faceMask, detailProtectionMask, processed, difference
        // Preserve existing developer call sites while using descriptive new modes.
        static let processedPhoto = Self.processed
        static let softFaceMask = Self.faceMask
    }

    // Carry the requested output with the job, not mutable global mode state.
    // All modes/configurations share one worker/admission slot, with no pending queue.
    private struct JobImage: Sendable {
        let image: ProcessingImage
        let output: Output
        let configuration: SkinRetouchConfiguration
    }

    private struct Detector: FaceDetecting {
        func detectFaces(in input: JobImage) throws -> FaceDetectionResult {
            try MockFaceDetector<ProcessingImage>().detectFaces(in: input.image)
        }
    }

    private struct OutputStep: ImageProcessingStep {
        func process(_ input: JobImage, regions: [FaceRegion]) throws -> JobImage {
            let result: ProcessingImage
            switch input.output {
            case .original:
                result = input.image
            case .processed:
                result = try TexturePreservingSkinSmoothingStep(configuration: input.configuration)
                    .process(input.image, regions: regions)
            case .faceMask:
                result = try DebugFaceMaskStep().process(input.image, regions: regions)
            case .detailProtectionMask:
                let source = CIImage(cgImage: input.image.cgImage)
                let mask: CIImage
                if let scale = SkinRetouchScale(regions: regions, in: source.extent) {
                    mask = try DetailProtectionMaskGenerator().makeMask(source: source, scale: scale)
                } else {
                    mask = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: source.extent)
                }
                result = try CoreImageRendering.render(mask, matching: input.image)
            case .difference:
                let source = CIImage(cgImage: input.image.cgImage)
                let processed = try TexturePreservingSkinSmoothingStep(configuration: input.configuration)
                    .makeOutput(source: source, regions: regions) ?? source
                // Unamplified absolute difference for inspection only. Its alpha is
                // diagnostic; alpha-preservation acceptance uses .processed pixels.
                let difference = try CoreImageRendering.filter("CIDifferenceBlendMode", parameters: [
                    kCIInputImageKey: processed, kCIInputBackgroundImageKey: source
                ], in: source.extent)
                result = try CoreImageRendering.render(difference, matching: input.image)
            }
            return JobImage(image: result, output: input.output, configuration: input.configuration)
        }
    }

    private static let pipeline = ImageProcessingPipeline<JobImage>(
        detector: Detector(), steps: [OutputStep()]
    )

    static func process(_ photo: CapturedPhoto, output: Output = .processed,
                        configuration: SkinRetouchConfiguration = .naturalDefault) async throws -> ImageProcessingOutput<ProcessingImage> {
        try await process(data: photo.data, output: output, configuration: configuration)
    }

    static func process(data: Data, output: Output = .processed,
                        configuration: SkinRetouchConfiguration = .naturalDefault) async throws -> ImageProcessingOutput<ProcessingImage> {
        let result = try await pipeline.process(load: {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw Failure.invalidImageData
            }
            // Same ImageIO orientation/downsample policy as CapturedPhoto, on the
            // pipeline queue. EXIF rotations AND mirrors are applied exactly once.
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { throw Failure.decodeFailed }
            return JobImage(image: ProcessingImage(cgImage: image), output: output, configuration: configuration)
        })
        return ImageProcessingOutput(image: result.image.image, detection: result.detection)
    }
}
#endif
