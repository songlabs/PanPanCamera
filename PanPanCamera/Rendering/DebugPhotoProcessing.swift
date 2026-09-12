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
        case beautyMaskOverlay
        case processedTexture, toneAdjusted, toneDifference
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
        let components: NaturalSkinRetouchSteps.Components
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
            case .processed, .processedTexture, .toneAdjusted:
                let components = input.output == .processedTexture ? .textureOnly :
                    input.output == .toneAdjusted ? .toneOnly : input.components
                result = try retouch(input, regions: regions, components: components)
            case .faceMask:
                result = try DebugFaceMaskStep().process(input.image, regions: regions)
            case .skinMask, .featureProtectionMask, .detailProtectionMask, .combinedProtectionMask, .effectiveSkinMask,
                 .beautyMaskOverlay:
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
                case .beautyMaskOverlay:
                    guard let masks else { mask = black; break }
                    result = try overlay(source: source, masks: masks, regions: regions, matching: input.image)
                    return JobImage(image: result, output: input.output, configuration: input.configuration,
                        components: input.components, skinMaskProvider: input.skinMaskProvider)
                default: mask = masks?.effectiveSkinMask ?? black
                }
                result = try CoreImageRendering.render(mask, matching: input.image)
            case .difference, .toneDifference:
                let source = CIImage(cgImage: input.image.cgImage)
                let processed = try retouch(input, regions: regions,
                    components: input.output == .toneDifference ? .toneOnly : input.components)
                // Unamplified absolute difference for inspection only. Its alpha is
                // diagnostic; alpha-preservation acceptance uses .processed pixels.
                let difference = try CoreImageRendering.filter("CIDifferenceBlendMode", parameters: [
                    kCIInputImageKey: CIImage(cgImage: processed.cgImage), kCIInputBackgroundImageKey: source
                ], in: source.extent)
                result = try CoreImageRendering.render(difference, matching: input.image)
            }
            return JobImage(image: result, output: input.output, configuration: input.configuration,
                components: input.components, skinMaskProvider: input.skinMaskProvider)
        }

        private func overlay(source: CIImage, masks: EffectiveSkinMaskComposer.Masks,
                             regions: [FaceRegion], matching image: ProcessingImage) throws -> ProcessingImage {
            let extent = source.extent
            let inverseSkin = try CoreImageRendering.grayMask(masks.skinMask, scale: -1, bias: 1)
            let nonSkin = try CoreImageRendering.filter("CIMultiplyCompositing", parameters: [
                kCIInputImageKey: masks.faceMask, kCIInputBackgroundImageKey: inverseSkin
            ], in: extent)
            let excluded = try CoreImageRendering.filter("CIMaximumCompositing", parameters: [
                kCIInputImageKey: nonSkin, kCIInputBackgroundImageKey: masks.combinedProtectionMask
            ], in: extent)
            let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0, alpha: 0.42)).cropped(to: extent)
            let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 0.48)).cropped(to: extent)
            var output = try CoreImageRendering.blend(green, over: source, mask: masks.effectiveSkinMask)
            output = try CoreImageRendering.blend(red, over: output, mask: excluded)
            let cyan = CIImage(color: CIColor(red: 0, green: 0.9, blue: 1, alpha: 0.9))
            for region in regions {
                let r = region.imageRect(in: extent).integral
                let width = max(1, min(r.width, r.height) * 0.006)
                for edge in [CGRect(x: r.minX, y: r.minY, width: r.width, height: width),
                             CGRect(x: r.minX, y: r.maxY - width, width: r.width, height: width),
                             CGRect(x: r.minX, y: r.minY, width: width, height: r.height),
                             CGRect(x: r.maxX - width, y: r.minY, width: width, height: r.height)] {
                    output = cyan.cropped(to: edge.intersection(extent)).composited(over: output)
                }
            }
            return try CoreImageRendering.render(output.cropped(to: extent), matching: image)
        }

        private func retouch(_ input: JobImage, regions: [FaceRegion],
                             components: NaturalSkinRetouchSteps.Components) throws -> ProcessingImage {
            // Already on the existing pipeline worker. No nested pipeline/job.
            var image = input.image
            for step in NaturalSkinRetouchSteps.make(configuration: input.configuration, components: components,
                landmarkDetector: MockFaceLandmarkDetector<ProcessingImage>(), skinMaskProvider: input.skinMaskProvider) {
                image = try step.process(image, regions: regions)
            }
            return image
        }
    }

    private static let pipeline = ImageProcessingPipeline<JobImage>(
        detector: Detector(), steps: [OutputStep()]
    )

    static func process(_ photo: CapturedPhoto, output: Output = .processed,
                        configuration: SkinRetouchConfiguration = .naturalDefault,
                        components: NaturalSkinRetouchSteps.Components = .combined,
                        skinMaskProvider: MockSkinMaskProvider = MockSkinMaskProvider()) async throws -> ImageProcessingOutput<ProcessingImage> {
        try await process(data: photo.data, output: output, configuration: configuration,
            components: components, skinMaskProvider: skinMaskProvider)
    }

    static func process(data: Data, output: Output = .processed,
                        configuration: SkinRetouchConfiguration = .naturalDefault,
                        components: NaturalSkinRetouchSteps.Components = .combined,
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
            return JobImage(image: ProcessingImage(cgImage: image), output: output, configuration: configuration,
                components: components, skinMaskProvider: skinMaskProvider)
        })
        return ImageProcessingOutput(image: result.image.image, detection: result.detection)
    }
}
#endif
