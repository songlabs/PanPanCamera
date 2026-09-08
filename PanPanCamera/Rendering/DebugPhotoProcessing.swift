#if DEBUG
import Foundation
import ImageIO

/// Explicit developer/test entry point, absent from Release. No automatic capture
/// hook, launch flag or product UI. Call with an existing CapturedPhoto or test data.
/// Returned pixels are a development preview (maximum 2048), not a replacement for
/// the original photo. No image/face data is logged, uploaded, saved or retained here.
enum DebugPhotoProcessing {
    enum Failure: Error { case invalidImageData, decodeFailed }
    enum Output: Sendable { case processedPhoto, softFaceMask }

    // Carry the requested output with the job, not mutable global mode state.
    // Both modes share the same worker/admission slot: no second pending work queue.
    private struct JobImage: Sendable {
        let image: ProcessingImage
        let output: Output
    }

    private struct Detector: FaceDetecting {
        func detectFaces(in input: JobImage) throws -> FaceDetectionResult {
            MockFaceDetector<ProcessingImage>().detectFaces(in: input.image)
        }
    }

    private struct OutputStep: ImageProcessingStep {
        func process(_ input: JobImage, regions: [FaceRegion]) throws -> JobImage {
            let result: ProcessingImage
            switch input.output {
            case .processedPhoto: result = try NaturalSkinProcessingStep().process(input.image, regions: regions)
            case .softFaceMask: result = try DebugFaceMaskStep().process(input.image, regions: regions)
            }
            return JobImage(image: result, output: input.output)
        }
    }

    private static let pipeline = ImageProcessingPipeline<JobImage>(
        detector: Detector(), steps: [OutputStep()]
    )

    static func process(_ photo: CapturedPhoto, output: Output = .processedPhoto) async throws -> ImageProcessingOutput<ProcessingImage> {
        try await process(data: photo.data, output: output)
    }

    static func process(data: Data, output: Output = .processedPhoto) async throws -> ImageProcessingOutput<ProcessingImage> {
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
            return JobImage(image: ProcessingImage(cgImage: image), output: output)
        })
        return ImageProcessingOutput(image: result.image.image, detection: result.detection)
    }
}
#endif
