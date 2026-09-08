#if DEBUG
import Foundation
import ImageIO

/// Explicit developer/test entry point, absent from Release. No automatic capture
/// hook, launch flag or product UI. Call with an existing CapturedPhoto or test data.
/// Returned pixels are a development preview (maximum 2048), not a replacement for
/// the original photo. No image/face data is logged, uploaded, saved or retained here.
enum DebugPhotoProcessing {
    enum Failure: Error { case invalidImageData, decodeFailed }

    private static let pipeline = ImageProcessingPipeline<ProcessingImage>(
        detector: MockFaceDetector(), steps: [DebugFaceBrightnessStep()]
    )

    static func process(_ photo: CapturedPhoto) async throws -> ImageProcessingOutput<ProcessingImage> {
        try await process(data: photo.data)
    }

    static func process(data: Data) async throws -> ImageProcessingOutput<ProcessingImage> {
        try await pipeline.process(load: {
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
            return ProcessingImage(cgImage: image)
        })
    }
}
#endif
