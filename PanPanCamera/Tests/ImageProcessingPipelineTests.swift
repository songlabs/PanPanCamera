import Foundation
import XCTest
@testable import PanPanCamera

/// These same tests can run in the standalone host harness. Data is a small image
/// payload fixture here; Core Image pixels are covered separately on Apple platforms.
final class ImageProcessingPipelineTests: XCTestCase {
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func record(_ value: String) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(value)
        }
        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    private struct Detector: FaceDetecting {
        let body: @Sendable (Data) throws -> FaceDetectionResult
        func detectFaces(in image: Data) throws -> FaceDetectionResult { try body(image) }
    }

    private struct Step: ImageProcessingStep {
        let body: @Sendable (Data, [FaceRegion]) throws -> Data
        func process(_ image: Data, regions: [FaceRegion]) throws -> Data { try body(image, regions) }
    }

    private final class Sentinel: Error, @unchecked Sendable {}

    private func region(_ box: CGRect = CGRect(x: 0.25, y: 0.125, width: 0.5, height: 0.5)) throws -> FaceRegion {
        try FaceRegion(boundingBox: box)
    }

    #if DEBUG
    func testMockDefaultsToOneSyntheticCentralFace() throws {
        let detector: any FaceDetecting<Data> = MockFaceDetector<Data>()
        let result = try detector.detectFaces(in: Data([7]))
        XCTAssertEqual(result.regions.count, 1)
        XCTAssertEqual(result.regions.first?.boundingBox, CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
        XCTAssertEqual(try detector.detectFaces(in: Data()), result, "Mock never inspects real image data")
    }

    func testMockCanReturnNoFaces() throws {
        let detector = MockFaceDetector<Data>(regions: [])
        XCTAssertEqual(try detector.detectFaces(in: Data()).regions, [])
    }

    func testMockPreservesMultipleCustomNormalizedBoxesInOrder() throws {
        let regions = try [region(), region(CGRect(x: 0.75, y: 0.5, width: 0.25, height: 0.5))]
        let detector = MockFaceDetector<Data>(regions: regions)
        XCTAssertEqual(try detector.detectFaces(in: Data()).regions, regions)
    }

    func testMockFeedsRegionsThroughPipelineToStepAndOutput() async throws {
        let regions = try [region()]
        let pipeline = ImageProcessingPipeline<Data>(detector: MockFaceDetector(regions: regions), steps: [Step {
            image, received in
            XCTAssertEqual(received, regions)
            return image + Data([2])
        }])
        let output = try await pipeline.process(Data([1]))
        XCTAssertEqual(output.image, Data([1, 2]))
        XCTAssertEqual(output.detection.regions, regions)
    }
    #endif

    @MainActor
    func testLoaderDetectorAndSequentialStepsRunOffMainWithIndependentDetector() async throws {
        let trace = Trace()
        let regions = try [region()]
        // A second conformer proves coordination is independent of Mock and Vision.
        let detector: any FaceDetecting<Data> = Detector { image in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(image, Data([1]))
            trace.record("detect")
            return FaceDetectionResult(regions: regions)
        }
        let pipeline = ImageProcessingPipeline<Data>(detector: detector, steps: [
            Step { image, received in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(received, regions)
                trace.record("first")
                return image + Data([2])
            },
            Step { image, received in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(image, Data([1, 2]))
                XCTAssertEqual(received, regions)
                trace.record("second")
                return image + Data([3])
            }
        ])
        let output = try await pipeline.process(load: {
            XCTAssertFalse(Thread.isMainThread)
            trace.record("load")
            return Data([1])
        })
        XCTAssertEqual(trace.values, ["load", "detect", "first", "second"])
        XCTAssertEqual(output.image, Data([1, 2, 3]))
        XCTAssertEqual(output.detection.regions, regions)
    }

    func testNoFacesAreDeliveredToStepsWithExplicitPassThrough() async throws {
        let trace = Trace()
        let pipeline = ImageProcessingPipeline<Data>(detector: Detector { _ in .init(regions: []) }, steps: [Step {
            image, regions in
            trace.record("step")
            XCTAssertTrue(regions.isEmpty)
            return image
        }])
        let output = try await pipeline.process(Data([10, 20]))
        XCTAssertEqual(output.image, Data([10, 20]))
        XCTAssertEqual(output.detection.regions, [])
        XCTAssertEqual(trace.values, ["step"])
    }

    func testEmptyStepListStillDetectsAndReturnsOriginal() async throws {
        let regions = try [region()]
        let pipeline = ImageProcessingPipeline<Data>(detector: Detector { _ in .init(regions: regions) }, steps: [])
        let output = try await pipeline.process(Data([1]))
        XCTAssertEqual(output.image, Data([1]))
        XCTAssertEqual(output.detection.regions, regions)
    }

    func testStepFailurePreservesErrorIdentityAndStopsLaterSteps() async throws {
        let failure = Sentinel()
        let trace = Trace()
        let pipeline = ImageProcessingPipeline<Data>(detector: Detector { _ in .init(regions: []) }, steps: [
            Step { _, _ in throw failure },
            Step { image, _ in trace.record("unexpected"); return image }
        ])
        // Retrying must reach the same error, proving that failure releases admission.
        for _ in 0..<2 {
            do {
                _ = try await pipeline.process(Data())
                XCTFail("Expected the original step error")
            } catch { XCTAssertTrue((error as? Sentinel) === failure) }
        }
        XCTAssertTrue(trace.values.isEmpty)
    }

    func testDetectorFailurePreservesErrorAndSkipsSteps() async throws {
        let failure = Sentinel()
        let trace = Trace()
        let pipeline = ImageProcessingPipeline<Data>(detector: Detector { _ in throw failure }, steps: [Step {
            image, _ in trace.record("unexpected"); return image
        }])
        do {
            _ = try await pipeline.process(Data())
            XCTFail("Expected detector error")
        } catch { XCTAssertTrue((error as? Sentinel) === failure) }
        XCTAssertTrue(trace.values.isEmpty)
    }

    func testLoaderFailurePreservesErrorAndReleasesSlot() async throws {
        let failure = Sentinel()
        let trace = Trace()
        let pipeline = ImageProcessingPipeline<Data>(detector: Detector { _ in
            trace.record("detect")
            return .init(regions: [])
        }, steps: [])
        do {
            _ = try await pipeline.process(load: { throw failure })
            XCTFail("Expected loader error")
        } catch { XCTAssertTrue((error as? Sentinel) === failure) }
        XCTAssertTrue(trace.values.isEmpty)
        _ = try await pipeline.process(Data())
        XCTAssertEqual(trace.values, ["detect"])
    }

    func testBusyRejectsBeforeDecodeWithoutBuildingPendingWork() async throws {
        let started = expectation(description: "Worker holds the only slot")
        let release = DispatchSemaphore(value: 0)
        let trace = Trace()
        let pipeline = ImageProcessingPipeline<Data>(detector: Detector { image in
            if image == Data([1]) {
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            return .init(regions: [])
        }, steps: [])
        let first = Task { try await pipeline.process(Data([1])) }
        defer { release.signal() }
        await fulfillment(of: [started], timeout: 2)
        for _ in 0..<20 {
            do {
                _ = try await pipeline.process(load: { trace.record("unexpected decode"); return Data() })
                XCTFail("Expected busy rejection")
            } catch { XCTAssertEqual(error as? ImageProcessingError, .busy) }
        }
        XCTAssertTrue(trace.values.isEmpty)
        release.signal()
        let firstOutput = try await first.value
        XCTAssertEqual(firstOutput.image, Data([1]))
        let next = try await pipeline.process(Data([2]))
        XCTAssertEqual(next.image, Data([2]))
    }

    func testCancellationKeepsSlotUntilSynchronousWorkFinishesThenRecovers() async throws {
        let started = expectation(description: "Work began")
        let release = DispatchSemaphore(value: 0)
        let pipeline = ImageProcessingPipeline<Data>(detector: Detector { image in
            if image == Data([1]) {
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            return .init(regions: [])
        }, steps: [])
        let task = Task { try await pipeline.process(Data([1])) }
        defer { release.signal() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await pipeline.process(Data([2]))
            XCTFail("Cancelled work must still own its slot until it exits")
        } catch { XCTAssertEqual(error as? ImageProcessingError, .busy) }
        release.signal()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await pipeline.process(Data([2]))
    }

    func testAlreadyCancelledTaskDoesNotLoadOrDetect() async throws {
        let trace = Trace()
        let pipeline = ImageProcessingPipeline<Data>(detector: Detector { _ in
            trace.record("detect")
            return .init(regions: [])
        }, steps: [])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pipeline.process(load: { trace.record("load"); return Data() })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation before admission") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(trace.values.isEmpty)
        _ = try await pipeline.process(Data())
        XCTAssertEqual(trace.values, ["detect"])
    }

    func testRegionConvertsUsingImageExtentOriginAndSize() throws {
        let face = try region()
        XCTAssertEqual(face.imageRect(in: CGRect(x: 10, y: 20, width: 400, height: 800)),
                       CGRect(x: 110, y: 120, width: 200, height: 400))
        XCTAssertTrue(face.imageRect(in: .zero).isNull)
        XCTAssertTrue(face.imageRect(in: .infinite).isNull)
    }

    func testImageEdgesStayInsideBoundsIncludingFullImage() throws {
        let extent = CGRect(x: 0, y: 0, width: 403, height: 301)
        let boxes = [CGRect(x: 0, y: 0, width: 1, height: 1),
                     CGRect(x: 0.75, y: 0.5, width: 0.25, height: 0.5),
                     CGRect(x: 0, y: 0, width: 0.1, height: 0.1)]
        for box in boxes {
            let rect = try region(box).imageRect(in: extent)
            XCTAssertGreaterThanOrEqual(rect.minX, extent.minX)
            XCTAssertGreaterThanOrEqual(rect.minY, extent.minY)
            XCTAssertLessThanOrEqual(rect.maxX, extent.maxX)
            XCTAssertLessThanOrEqual(rect.maxY, extent.maxY)
        }
        XCTAssertEqual(try region(boxes[0]).imageRect(in: extent), extent)
    }

    func testInvalidNormalizedBoxesAreRejectedBeforeProcessing() {
        let boxes = [CGRect.zero, CGRect(x: -0.1, y: 0, width: 0.5, height: 0.5),
                     CGRect(x: 0.9, y: 0, width: 0.2, height: 0.5),
                     CGRect(x: 0, y: 0.9, width: 0.5, height: 0.2),
                     CGRect(x: 0.5, y: 0.5, width: -0.2, height: 0.2),
                     CGRect(x: CGFloat.nan, y: 0, width: 0.5, height: 0.5),
                     CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 0.5)]
        for box in boxes {
            XCTAssertThrowsError(try region(box)) { error in
                XCTAssertTrue(error is FaceRegion.ValidationError)
            }
        }
    }
}
