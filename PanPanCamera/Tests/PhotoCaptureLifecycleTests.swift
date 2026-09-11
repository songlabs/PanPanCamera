import XCTest
@testable import PanPanCamera

final class PhotoCaptureLifecycleTests: XCTestCase {
    private enum CaptureError: Error { case processing, final }

    private func checkCompletion(processingError: Error?, finalError: Error?, expectsData: Bool,
                                 file: StaticString = #filePath, line: UInt = #line) {
        var registry = PhotoCaptureRegistry<PhotoCaptureProcessor>()
        let bytes = Data([1, 2, 3])
        var results: [Data?] = []
        var processor: PhotoCaptureProcessor? = PhotoCaptureProcessor { data in
            if registry.finish(id: 1) { results.append(data) }
        }
        weak var retained = processor
        registry.register(processor!, id: 1)
        processor = nil
        XCTAssertNotNil(retained, file: file, line: line)
        retained?.process(data: bytes, error: processingError)
        XCTAssertEqual(registry.count, 1, file: file, line: line)
        XCTAssertTrue(results.isEmpty, file: file, line: line)
        retained?.finish(error: finalError)
        XCTAssertEqual(results.count, 1, file: file, line: line)
        XCTAssertEqual(results.first ?? nil, expectsData ? bytes : nil, file: file, line: line)
        XCTAssertNil(registry.activeID, file: file, line: line)
        XCTAssertEqual(registry.count, 0, file: file, line: line)
        XCTAssertNil(retained, file: file, line: line)
    }

    func testSuccessfulCaptureReleasesProcessorAtFinalCallback() {
        checkCompletion(processingError: nil, finalError: nil, expectsData: true)
    }

    func testProcessingFailureWaitsForFinalCallbackThenReleasesProcessor() {
        checkCompletion(processingError: CaptureError.processing, finalError: nil, expectsData: false)
    }

    func testFinalCaptureFailureDiscardsDataAndReleasesProcessor() {
        checkCompletion(processingError: nil, finalError: CaptureError.final, expectsData: false)
    }

    func testFinalCallbackAdmitsAnotherCaptureWhileIndependentJobIsStillProcessing() {
        var registry = PhotoCaptureRegistry<PhotoCaptureProcessor>()
        let processingStarted = expectation(description: "Independent job started")
        let processingFinished = expectation(description: "Independent job finished")
        let release = DispatchSemaphore(value: 0)
        let worker = PhotoProcessingQueue(process: { _ in
            XCTAssertFalse(Thread.isMainThread)
            processingStarted.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return nil
        }, completion: { _ in processingFinished.fulfill() })
        var first: PhotoCaptureProcessor? = PhotoCaptureProcessor { data in
            guard registry.finish(id: 1), let data else { return }
            XCTAssertTrue(worker.enqueue(PhotoProcessingJob(source: .photoData(data),
                configuration: .disabled, diagnostics: .disabled)))
        }
        weak var retainedFirst = first
        registry.register(first!, id: 1)
        first = nil
        retainedFirst?.process(data: Data([1]), error: nil)
        XCTAssertEqual(registry.activeID, 1)
        retainedFirst?.finish(error: nil)
        wait(for: [processingStarted], timeout: 2)
        XCTAssertNil(retainedFirst)
        XCTAssertNil(registry.activeID)
        XCTAssertEqual(worker.pendingCount, 1)
        registry.register(PhotoCaptureProcessor { _ in }, id: 2)
        XCTAssertEqual(registry.activeID, 2)
        release.signal()
        wait(for: [processingFinished], timeout: 2)
        XCTAssertEqual(registry.activeID, 2, "Job completion cannot release a newer capture")
        XCTAssertTrue(registry.finish(id: 2))
    }

    func testResetLateCallbackReleasesOldProcessorWithoutCompletingNewCapture() {
        var registry = PhotoCaptureRegistry<PhotoCaptureProcessor>()
        var published: [Int64] = []
        var first: PhotoCaptureProcessor? = PhotoCaptureProcessor { _ in
            if registry.finish(id: 1) { published.append(1) }
        }
        weak var retainedFirst = first
        registry.register(first!, id: 1)
        first = nil
        XCTAssertTrue(registry.invalidateActive())
        XCTAssertFalse(registry.invalidateActive())
        XCTAssertNotNil(retainedFirst)

        var second: PhotoCaptureProcessor? = PhotoCaptureProcessor { _ in
            if registry.finish(id: 2) { published.append(2) }
        }
        weak var retainedSecond = second
        registry.register(second!, id: 2)
        second = nil
        retainedFirst?.process(data: Data([1]), error: nil)
        retainedFirst?.finish(error: nil)
        XCTAssertNil(retainedFirst)
        XCTAssertEqual(registry.activeID, 2)
        XCTAssertEqual(registry.count, 1)
        XCTAssertTrue(published.isEmpty)
        XCTAssertFalse(registry.finish(id: 1))
        XCTAssertEqual(registry.activeID, 2)

        retainedSecond?.process(data: Data([2]), error: nil)
        retainedSecond?.finish(error: nil)
        XCTAssertEqual(published, [2])
        XCTAssertNil(registry.activeID)
        XCTAssertEqual(registry.count, 0)
        XCTAssertNil(retainedSecond)
    }
}
