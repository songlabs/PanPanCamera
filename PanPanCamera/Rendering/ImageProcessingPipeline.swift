import Foundation

protocol ImageProcessingStep<Image>: Sendable {
    associatedtype Image: Sendable
    /// Preserve image dimensions/orientation so subsequent steps can reuse regions.
    /// Empty regions are explicitly delivered; regional steps must return the input.
    func process(_ image: Image, regions: [FaceRegion]) throws -> Image
}

struct ImageProcessingOutput<Image: Sendable>: Sendable {
    let image: Image
    let detection: FaceDetectionResult
}

enum ImageProcessingError: Error, Equatable { case busy }

/// One admitted image per instance, with no pending-image queue. The lock protects
/// admission only; loading, detection and all steps run on the serial worker queue.
/// Unchecked Sendable is limited to the locked busy flag; other properties are immutable.
final class ImageProcessingPipeline<Image: Sendable>: @unchecked Sendable {
    private let detector: any FaceDetecting<Image>
    private let steps: [any ImageProcessingStep<Image>]
    private let queue = DispatchQueue(label: "camera.panpan.image-processing", qos: .userInitiated)
    private let lock = NSLock()
    private var isBusy = false

    init(detector: any FaceDetecting<Image>, steps: [any ImageProcessingStep<Image>]) {
        self.detector = detector
        self.steps = steps
    }

    func process(_ image: Image) async throws -> ImageProcessingOutput<Image> {
        try await process(load: { image })
    }

    /// Defers decoding until AFTER admission and moves it off main as well.
    /// Errors from the loader, detector and steps are returned unchanged.
    /// Cancellation does not interrupt a synchronous image operation: the slot stays
    /// occupied until work finishes. Successful work then returns CancellationError;
    /// an operation failure retains its original error even if cancellation raced it.
    func process(load: @escaping @Sendable () throws -> Image) async throws -> ImageProcessingOutput<Image> {
        try Task.checkCancellation()
        guard begin() else { throw ImageProcessingError.busy }
        let output: ImageProcessingOutput<Image> = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                #if canImport(ObjectiveC)
                let result = autoreleasepool { Result { try run(load: load) } }
                #else
                let result = Result { try run(load: load) }
                #endif
                finish()
                continuation.resume(with: result)
            }
        }
        try Task.checkCancellation()
        return output
    }

    private func run(load: () throws -> Image) throws -> ImageProcessingOutput<Image> {
        dispatchPrecondition(condition: .onQueue(queue))
        dispatchPrecondition(condition: .notOnQueue(.main))
        var image = try load()
        let detection = try detector.detectFaces(in: image)
        for step in steps { image = try step.process(image, regions: detection.regions) }
        return ImageProcessingOutput(image: image, detection: detection)
    }

    private func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    private func finish() {
        lock.lock()
        defer { lock.unlock() }
        isBusy = false
    }
}
