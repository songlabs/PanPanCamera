import CoreImage
import XCTest
@testable import PanPanCamera

final class FaceAnalysisSchedulerTests: XCTestCase {
    func testBusyAnalysisDropsNewInputAndRetainsLatestBetweenCameraFrames() async throws {
        let started = expectation(description: "Inference entered worker")
        let completed = expectation(description: "Analysis completed")
        let release = DispatchSemaphore(value: 0)
        let count = PhotoProcessingTestValue(0)
        final class BlockingAnalyzer: FaceAnalyzer {
            let started: XCTestExpectation
            let release: DispatchSemaphore
            let count: PhotoProcessingTestValue<Int>
            init(_ started: XCTestExpectation, _ release: DispatchSemaphore, _ count: PhotoProcessingTestValue<Int>) {
                self.started = started; self.release = release; self.count = count
            }
            func faces(in image: CIImage) throws -> [AnalyzedFace] {
                XCTAssertFalse(Thread.isMainThread)
                count.update { $0 += 1 }
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return [AnalyzedFace(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), confidence: 1)]
            }
        }
        let scheduler = FaceAnalysisScheduler(engine: FaceAnalysisEngine(makeAnalyzer: { BlockingAnalyzer(started, release, count) }))
        let image = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        XCTAssertTrue(scheduler.submit(image, timestamp: 1, orientation: .up, mirrored: false) { _ in completed.fulfill() })
        await fulfillment(of: [started], timeout: 5)
        for index in 1...60 {
            XCTAssertFalse(scheduler.submit(image, timestamp: 1 + Double(index) / 60,
                orientation: .up, mirrored: false) { _ in XCTFail("A dropped frame ran inference") })
        }
        release.signal()
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(count.value, 1)
        let first = try XCTUnwrap(scheduler.snapshot(at: 1.01))
        for time in [1.05, 1.10, 1.20, 1.49] { XCTAssertEqual(scheduler.snapshot(at: time), first) }
        XCTAssertNil(scheduler.snapshot(at: 1.51))
        scheduler.invalidate()
        XCTAssertNil(scheduler.snapshot(at: 1.2))
        XCTAssertFalse(scheduler.submit(image, timestamp: 3, orientation: .up, mirrored: false) { _ in XCTFail() })
    }

    func testInvalidatedGenerationCannotPublishLateInference() async {
        let entered = expectation(description: "Entered")
        let completed = expectation(description: "Late result suppressed")
        completed.isInverted = true
        let release = DispatchSemaphore(value: 0)
        final class Analyzer: FaceAnalyzer {
            let entered: XCTestExpectation
            let release: DispatchSemaphore
            init(_ entered: XCTestExpectation, _ release: DispatchSemaphore) { self.entered = entered; self.release = release }
            func faces(in image: CIImage) throws -> [AnalyzedFace] {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return []
            }
        }
        let scheduler = FaceAnalysisScheduler(engine: FaceAnalysisEngine(makeAnalyzer: { Analyzer(entered, release) }))
        let image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        scheduler.submit(image, timestamp: 1, orientation: .up, mirrored: false) { _ in completed.fulfill() }
        await fulfillment(of: [entered], timeout: 5)
        scheduler.invalidate()
        release.signal()
        await fulfillment(of: [completed], timeout: 0.2)
        XCTAssertNil(scheduler.snapshot(at: 1.1))
    }
}
