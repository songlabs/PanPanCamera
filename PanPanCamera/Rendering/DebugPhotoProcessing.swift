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
        case original, faceMask, skinMask, featureProtectionMask, detailProtectionMask
        case combinedProtectionMask, effectiveSkinMask, processed, difference
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
        let skinMaskProvider: MockSkinMaskProvider
    }

    private struct Detector: FaceDetecting {
        func detectFaces(in input: JobImage) throws -> FaceDetectionResult {
            try MockFaceDetector<ProcessingImage>().detectFaces(in: input.image)
        }
    }

    private struct OutputStep: ImageProcessingStep {
        func process(_ input: JobImage, regions: [FaceRegion]) throws -> JobImage {
            let step = TexturePreservingSkinSmoothingStep(configuration: input.configuration,
                landmarkDetector: MockFaceLandmarkDetector<ProcessingImage>(), skinMaskProvider: input.skinMaskProvider)
            let result: ProcessingImage
            switch input.output {
            case .original:
                result = input.image
            case .processed:
                result = try step.process(input.image, regions: regions)
            case .faceMask:
                result = try DebugFaceMaskStep().process(input.image, regions: regions)
            case .skinMask, .featureProtectionMask, .detailProtectionMask, .combinedProtectionMask, .effectiveSkinMask:
                let source = CIImage(cgImage: input.image.cgImage)
                let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: source.extent)
                let landmarks = try MockFaceLandmarkDetector<ProcessingImage>().detectLandmarks(in: input.image, regions: regions)
                let semantics = try step.skinMasks(in: input.image, regions: regions, landmarks: landmarks)
                let masks = try step.makeMasks(source: source, regions: regions, landmarks: landmarks, skinMasks: semantics)
                let mask: CIImage
                switch input.output {
                case .skinMask: mask = masks?.skinMask ?? black
                case .featureProtectionMask: mask = masks?.featureProtectionMask ?? black
                case .detailProtectionMask: mask = masks?.detailProtectionMask ?? black
                case .combinedProtectionMask: mask = masks?.combinedProtectionMask ?? black
                default: mask = masks?.effectiveSkinMask ?? black
                }
                result = try CoreImageRendering.render(mask, matching: input.image)
            case .difference:
                let source = CIImage(cgImage: input.image.cgImage)
                let landmarks = input.configuration.intensity.value == 0 ? [] :
                    try MockFaceLandmarkDetector<ProcessingImage>().detectLandmarks(in: input.image, regions: regions)
                let semantics = input.configuration.intensity.value == 0 ? [] :
                    try step.skinMasks(in: input.image, regions: regions, landmarks: landmarks)
                let processed = try step.makeOutput(source: source, regions: regions, landmarks: landmarks, skinMasks: semantics) ?? source
                // Unamplified absolute difference for inspection only. Its alpha is
                // diagnostic; alpha-preservation acceptance uses .processed pixels.
                let difference = try CoreImageRendering.filter("CIDifferenceBlendMode", parameters: [
                    kCIInputImageKey: processed, kCIInputBackgroundImageKey: source
                ], in: source.extent)
                result = try CoreImageRendering.render(difference, matching: input.image)
            }
            return JobImage(image: result, output: input.output, configuration: input.configuration, skinMaskProvider: input.skinMaskProvider)
        }
    }

    private static let pipeline = ImageProcessingPipeline<JobImage>(
        detector: Detector(), steps: [OutputStep()]
    )

    static func process(_ photo: CapturedPhoto, output: Output = .processed,
                        configuration: SkinRetouchConfiguration = .naturalDefault,
                        skinMaskProvider: MockSkinMaskProvider = MockSkinMaskProvider()) async throws -> ImageProcessingOutput<ProcessingImage> {
        try await process(data: photo.data, output: output, configuration: configuration, skinMaskProvider: skinMaskProvider)
    }

    static func process(data: Data, output: Output = .processed,
                        configuration: SkinRetouchConfiguration = .naturalDefault,
                        skinMaskProvider: MockSkinMaskProvider = MockSkinMaskProvider()) async throws -> ImageProcessingOutput<ProcessingImage> {
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
            return JobImage(image: ProcessingImage(cgImage: image), output: output, configuration: configuration, skinMaskProvider: skinMaskProvider)
        })
        return ImageProcessingOutput(image: result.image.image, detection: result.detection)
    }
}
#endif
