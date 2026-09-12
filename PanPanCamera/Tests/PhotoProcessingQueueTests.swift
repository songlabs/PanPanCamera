import ImageIO
import CoreVideo
import Photos
import XCTest
@testable import PanPanCamera

final class PhotoProcessingQueueTests: XCTestCase {
    func testFIFOAndConfigurationSnapshotsWithBoundedAdmission() async throws {
        let data = try await Task.detached { try PhotoProcessingTestFixture.data() }.value
        let started = expectation(description: "First job is running")
        let done = expectation(description: "Two jobs saved")
        done.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        let seen = PhotoProcessingTestValue<[BeautyConfiguration]>([])
        let saved = PhotoProcessingTestValue<[Data]>([])
        let first = BeautyConfiguration(enabled: true, overallStrength: 0.7, smoothingStrength: 0.2)
        let second = BeautyConfiguration(enabled: true, filter: .init(preset: .warm, intensity: 0.9))
        let worker = PhotoProcessingQueue(maximumPendingCount: 2, process: { job in
            XCTAssertFalse(Thread.isMainThread)
            let index = seen.update { values -> Int in
                values.append(job.configuration)
                return values.count
            }
            if index == 1 {
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            return CapturedPhoto(data: data)
        }, save: { bytes, _, completion in
            XCTAssertFalse(Thread.isMainThread)
            saved.update { $0.append(bytes) }
            completion(true)
        }, completion: { outcome in
            XCTAssertNotNil(outcome.photo)
            done.fulfill()
        })
        XCTAssertTrue(worker.enqueue(job(data, configuration: first)))
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(worker.enqueue(job(data, configuration: second)))
        XCTAssertFalse(worker.canAcceptJob)
        XCTAssertFalse(worker.enqueue(job(data)))
        XCTAssertEqual(worker.pendingCount, 2)
        XCTAssertEqual(seen.value, [first])
        release.signal()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(seen.value, [first, second])
        XCTAssertEqual(saved.value, [data, data])
        XCTAssertEqual(worker.pendingCount, 0)
        XCTAssertTrue(worker.canAcceptJob)
    }

    func testFinalDecodeFailureAdvancesQueueAndBypassSavesOriginalBytes() async throws {
        let data = try await Task.detached { try PhotoProcessingTestFixture.data() }.value
        let done = expectation(description: "Failed processing followed by saved original")
        done.expectedFulfillmentCount = 2
        let results = PhotoProcessingTestValue<[Bool]>([])
        let saves = PhotoProcessingTestValue<[Data]>([])
        let worker = PhotoProcessingQueue(save: { bytes, _, completion in
            saves.update { $0.append(bytes) }
            completion(true)
        }, completion: { outcome in
            results.update { $0.append(outcome.photo != nil) }
            done.fulfill()
        })
        XCTAssertTrue(worker.enqueue(job(Data([0, 1]), configuration: .init(enabled: true,
            filter: .init(preset: .warm, intensity: 1)))))
        XCTAssertTrue(worker.enqueue(job(data)))
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(results.value, [false, true])
        XCTAssertEqual(saves.value, [data])
        XCTAssertEqual(worker.pendingCount, 0)
        XCTAssertTrue(worker.canAcceptJob)
    }

    func testImageEncoderFailureAdvancesQueueWithoutSavingFailedImage() async throws {
        let data = try await Task.detached { try PhotoProcessingTestFixture.data() }.value
        let encodeCalls = PhotoProcessingTestValue<Int>(0)
        let processor = FinalBeautyProcessor(encodeImage: { _, _, _ in
            encodeCalls.update { $0 += 1 }
            return nil
        })
        let done = expectation(description: "Encoding failure followed by bypass success")
        done.expectedFulfillmentCount = 2
        let results = PhotoProcessingTestValue<[Bool]>([])
        let saved = PhotoProcessingTestValue<[Data]>([])
        let worker = PhotoProcessingQueue(process: { job in
            guard case let .photoData(bytes) = job.source else { return nil }
            return processor.processPhotoData(bytes, configuration: job.configuration)
                .flatMap(CapturedPhoto.init(data:))
        }, save: { bytes, _, completion in
            saved.update { $0.append(bytes) }
            completion(true)
        }, completion: { outcome in
            results.update { $0.append(outcome.photo != nil) }
            done.fulfill()
        })
        XCTAssertTrue(worker.enqueue(job(data, configuration: .init(enabled: true,
            filter: .init(preset: .warm, intensity: 1)))))
        XCTAssertTrue(worker.enqueue(job(data)))
        await fulfillment(of: [done], timeout: 15)
        XCTAssertEqual(encodeCalls.value, 1)
        XCTAssertEqual(results.value, [false, true])
        XCTAssertEqual(saved.value, [data])
        XCTAssertEqual(worker.pendingCount, 0)
    }

    func testDelayedPhotoLibraryFailureKeepsFIFOAndReleasesCapacity() async throws {
        let data = try await Task.detached { try PhotoProcessingTestFixture.data() }.value
        let saving = expectation(description: "First PhotoKit request suspended")
        let done = expectation(description: "Both save results delivered")
        done.expectedFulfillmentCount = 2
        let resume = PhotoProcessingTestValue<((Bool) -> Void)?>(nil)
        let saves = PhotoProcessingTestValue<Int>(0)
        let results = PhotoProcessingTestValue<[Bool]>([])
        let worker = PhotoProcessingQueue(maximumPendingCount: 2, save: { _, _, completion in
            let count = saves.update { $0 += 1; return $0 }
            if count == 1 {
                resume.update { $0 = completion }
                saving.fulfill()
            } else { completion(true) }
        }, completion: { outcome in
            results.update { $0.append(outcome.photo != nil) }
            done.fulfill()
        })
        XCTAssertTrue(worker.enqueue(job(data)))
        await fulfillment(of: [saving], timeout: 2)
        XCTAssertTrue(worker.enqueue(job(data)))
        XCTAssertEqual(worker.pendingCount, 2)
        XCTAssertFalse(worker.canAcceptJob)
        XCTAssertEqual(saves.value, 1)
        XCTAssertTrue(results.value.isEmpty, "A result must not publish before save completes")
        resume.value?(false)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(results.value, [false, true])
        XCTAssertEqual(saves.value, 2)
        XCTAssertEqual(worker.pendingCount, 0)
        XCTAssertTrue(worker.canAcceptJob)
    }

    func testThreeSerialProcessesFinishWhileFirstSaveIsSuspendedAndAllCapacityRemainsOccupied() async throws {
        let data = try await Task.detached { try PhotoProcessingTestFixture.data() }.value
        let allProcessed = expectation(description: "All three reached bounded Save FIFO")
        let firstSaving = expectation(description: "S1 callback retained")
        let done = expectation(description: "FIFO results")
        done.expectedFulfillmentCount = 3
        let callbacks = PhotoProcessingTestValue<[(Bool) -> Void]>([])
        let configurations = PhotoProcessingTestValue<[BeautyConfiguration]>([])
        let active = PhotoProcessingTestValue(0)
        let peak = PhotoProcessingTestValue(0)
        let ids = PhotoProcessingTestValue<[UUID]>([])
        let jobs = [0.2, 0.8, 0.5].map {
            job(data, configuration: .init(enabled: true, overallStrength: $0, smoothingStrength: 1))
        }
        let worker = PhotoProcessingQueue(process: { job in
            let count = active.update { $0 += 1; return $0 }
            peak.update { $0 = max($0, count) }
            defer { active.update { $0 -= 1 } }
            configurations.update { $0.append(job.configuration) }
            return CapturedPhoto(data: data)
        }, save: { _, _, reply in
            let count = callbacks.update { $0.append(reply); return $0.count }
            if count > 1 { reply(true) } else { firstSaving.fulfill() }
        }, stateChanged: { state in
            XCTAssertLessThanOrEqual(state.processingActive, 1)
            XCTAssertLessThanOrEqual(state.saveActive, 1)
            XCTAssertLessThanOrEqual(state.pendingTotal, 3)
            if state.pendingSave == 3 && state.saveActive == 1 { allProcessed.fulfill() }
        }, completion: { outcome in
            XCTAssertNotNil(outcome.photo)
            ids.update { $0.append(outcome.captureID) }
            done.fulfill()
        })
        for job in jobs { XCTAssertTrue(worker.enqueue(job)) }
        await fulfillment(of: [allProcessed, firstSaving], timeout: 5)
        XCTAssertEqual(configurations.value, jobs.map(\.configuration))
        XCTAssertEqual(peak.value, 1)
        XCTAssertEqual(callbacks.value.count, 1, "S2 must not start before S1 completes")
        XCTAssertEqual(worker.snapshot.pendingSave, 3)
        XCTAssertEqual(worker.snapshot.pendingProcessing, 0)
        XCTAssertFalse(worker.enqueue(job(data)))
        XCTAssertTrue(ids.value.isEmpty)
        callbacks.value.first?(true)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(ids.value, jobs.map(\.captureID))
        XCTAssertEqual(worker.pendingCount, 0)
    }

    func testSaveCompletionReleasesCapacityEvenDuringAnotherBlockedProcess() async throws {
        let data = try await Task.detached { try PhotoProcessingTestFixture.data() }.value
        let saving = expectation(description: "S1 suspended")
        let processing = expectation(description: "P2 suspended")
        let firstDone = expectation(description: "S1 finishes without waiting for P2")
        let secondDone = expectation(description: "P2 eventually finishes")
        let release = DispatchSemaphore(value: 0)
        let reply = PhotoProcessingTestValue<((Bool) -> Void)?>(nil)
        let processCount = PhotoProcessingTestValue(0)
        let saveCount = PhotoProcessingTestValue(0)
        let resultCount = PhotoProcessingTestValue(0)
        let worker = PhotoProcessingQueue(process: { _ in
            if processCount.update({ $0 += 1; return $0 }) == 2 {
                processing.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
            }
            return CapturedPhoto(data: data)
        }, save: { _, _, completion in
            if saveCount.update({ $0 += 1; return $0 }) == 1 {
                reply.update { $0 = completion }
                saving.fulfill()
            } else { completion(true) }
        }, completion: { _ in
            if resultCount.update({ $0 += 1; return $0 }) == 1 { firstDone.fulfill() }
            else { secondDone.fulfill() }
        })
        XCTAssertTrue(worker.enqueue(job(data)))
        await fulfillment(of: [saving], timeout: 5)
        XCTAssertTrue(worker.enqueue(job(data)))
        await fulfillment(of: [processing], timeout: 5)
        reply.value?(true)
        await fulfillment(of: [firstDone], timeout: 5)
        XCTAssertEqual(worker.pendingCount, 1)
        XCTAssertEqual(worker.snapshot.processingActive, 1)
        XCTAssertEqual(worker.snapshot.saveActive, 0)
        release.signal()
        await fulfillment(of: [secondDone], timeout: 5)
        XCTAssertEqual(worker.pendingCount, 0)
    }

    func testDuplicateAndLateSaveCallbacksCannotCompleteAnotherJobOrDecrementTwice() async throws {
        let data = try await Task.detached { try PhotoProcessingTestFixture.data() }.value
        let firstSaving = expectation(description: "S1 started")
        let secondSaving = expectation(description: "S2 started after failed S1")
        let done = expectation(description: "Exactly two results")
        done.expectedFulfillmentCount = 2
        done.assertForOverFulfill = true
        let callbacks = PhotoProcessingTestValue<[(Bool) -> Void]>([])
        let results = PhotoProcessingTestValue<[PhotoProcessingResult]>([])
        let worker = PhotoProcessingQueue(save: { _, _, reply in
            let count = callbacks.update { $0.append(reply); return $0.count }
            if count == 1 { firstSaving.fulfill() } else { secondSaving.fulfill() }
        }, completion: { result in
            results.update { $0.append(result) }
            done.fulfill()
        })
        XCTAssertTrue(worker.enqueue(job(data)))
        XCTAssertTrue(worker.enqueue(job(data)))
        await fulfillment(of: [firstSaving], timeout: 5)
        callbacks.value[0](false)
        callbacks.value[0](false)
        await fulfillment(of: [secondSaving], timeout: 5)
        XCTAssertEqual(worker.pendingCount, 1)
        callbacks.value[0](true) // Old S1 must not finish S2.
        callbacks.value[1](true)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(results.value.count, 2)
        if case .failure(.saveFailed) = results.value[0].result {} else { XCTFail("Expected save failure") }
        XCTAssertNotNil(results.value[1].photo)
        XCTAssertEqual(worker.pendingCount, 0)
    }

    func testProcessingFailureDoesNotOvertakeOlderSaveAndNextSaveContinues() async throws {
        let data = try await Task.detached { try PhotoProcessingTestFixture.data() }.value
        let allQueued = expectation(description: "Success, failure, success ready for FIFO delivery")
        let firstSaving = expectation(description: "S1 callback retained")
        let done = expectation(description: "All terminal results")
        done.expectedFulfillmentCount = 3
        let reply = PhotoProcessingTestValue<((Bool) -> Void)?>(nil)
        let processCount = PhotoProcessingTestValue(0)
        let saveCount = PhotoProcessingTestValue(0)
        let results = PhotoProcessingTestValue<[PhotoProcessingResult]>([])
        let jobs = [job(data), job(data), job(data)]
        let worker = PhotoProcessingQueue(process: { _ in
            processCount.update({ $0 += 1; return $0 }) == 2 ? nil : CapturedPhoto(data: data)
        }, save: { _, _, completion in
            if saveCount.update({ $0 += 1; return $0 }) == 1 {
                reply.update { $0 = completion }
                firstSaving.fulfill()
            }
            else { completion(true) }
        }, stateChanged: { state in
            if state.pendingSave == 3 && state.saveActive == 1 { allQueued.fulfill() }
        }, completion: { result in
            results.update { $0.append(result) }
            done.fulfill()
        })
        for job in jobs { XCTAssertTrue(worker.enqueue(job)) }
        await fulfillment(of: [allQueued, firstSaving], timeout: 5)
        XCTAssertTrue(results.value.isEmpty)
        reply.value?(true)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(results.value.map(\.captureID), jobs.map(\.captureID))
        XCTAssertEqual(results.value.map { $0.photo != nil }, [true, false, true])
        if case .failure(.processingFailed) = results.value[1].result {} else { XCTFail("Expected processing failure") }
        XCTAssertEqual(saveCount.value, 2)
        XCTAssertEqual(worker.pendingCount, 0)
    }

    func testVisionAndRenderFailuresReleaseCapacityAndNextJobCanSave() async throws {
        enum InjectedFailure: Error { case vision }
        let data = try await Task.detached { try PhotoProcessingTestFixture.data() }.value
        let visionFailure = FinalBeautyProcessor(detectPhotoFaces: { _, _ in throw InjectedFailure.vision })
        let renderFailure = FinalBeautyProcessor(renderImage: { _, _, _ in nil })
        let count = PhotoProcessingTestValue(0)
        let saveCount = PhotoProcessingTestValue(0)
        let results = PhotoProcessingTestValue<[Bool]>([])
        let done = expectation(description: "Vision failure, render failure, success")
        done.expectedFulfillmentCount = 3
        let worker = PhotoProcessingQueue(process: { job in
            guard case let .photoData(bytes) = job.source else { return nil }
            switch count.update({ $0 += 1; return $0 }) {
            case 1:
                return visionFailure.processPhotoData(bytes, configuration: job.configuration).flatMap(CapturedPhoto.init(data:))
            case 2:
                return renderFailure.processPhotoData(bytes, configuration: job.configuration).flatMap(CapturedPhoto.init(data:))
            default: return CapturedPhoto(data: bytes)
            }
        }, save: { _, _, completion in
            saveCount.update { $0 += 1 }
            completion(true)
        }, completion: { outcome in
            results.update { $0.append(outcome.photo != nil) }
            done.fulfill()
        })
        XCTAssertTrue(worker.enqueue(job(data, configuration: .init(enabled: true, overallStrength: 1, smoothingStrength: 1))))
        XCTAssertTrue(worker.enqueue(job(data, configuration: .init(enabled: true, filter: .init(preset: .warm, intensity: 1)))))
        XCTAssertTrue(worker.enqueue(job(data)))
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(results.value, [false, false, true])
        XCTAssertEqual(saveCount.value, 1)
        XCTAssertTrue(worker.canAcceptJob)
        XCTAssertEqual(worker.pendingCount, 0)
    }

    func testThumbnailFailureReleasesCapacityWithoutSavingAndNextJobSucceeds() async throws {
        let data = try await Task.detached { try PhotoProcessingTestFixture.data() }.value
        let count = PhotoProcessingTestValue(0)
        let results = PhotoProcessingTestValue<[Bool]>([])
        let done = expectation(description: "Failed thumbnail followed by success")
        done.expectedFulfillmentCount = 2
        let worker = PhotoProcessingQueue(makeThumbnail: { bytes in
            count.update({ $0 += 1; return $0 }) == 1 ? nil : CapturedPhoto(data: bytes)
        }, save: { _, _, completion in completion(true) }, completion: { outcome in
            results.update { $0.append(outcome.photo != nil) }
            done.fulfill()
        })
        XCTAssertTrue(worker.enqueue(job(data)))
        XCTAssertTrue(worker.enqueue(job(data)))
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(results.value, [false, true])
        XCTAssertEqual(worker.pendingCount, 0)
    }

    func testSilentSourceIsReleasedWhileEncodedPhotoWaitsForSave() async throws {
        let data = try await Task.detached { try PhotoProcessingTestFixture.data() }.value
        let saving = expectation(description: "Encoded Silent Frame awaiting save")
        let nextProcessed = expectation(description: "Original processing block returned")
        let done = expectation(description: "Both jobs completed")
        done.expectedFulfillmentCount = 2
        let reply = PhotoProcessingTestValue<((Bool) -> Void)?>(nil)
        let count = PhotoProcessingTestValue(0)
        let worker = PhotoProcessingQueue(process: { _ in
            if count.update({ $0 += 1; return $0 }) == 2 { nextProcessed.fulfill() }
            return CapturedPhoto(data: data)
        }, save: { _, _, completion in
            if reply.value == nil { reply.update { $0 = completion }; saving.fulfill() }
            else { completion(true) }
        }, completion: { _ in done.fulfill() })
        weak var original: CVPixelBuffer?
        autoreleasepool {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 12, kCVPixelFormatType_32BGRA,
                                              nil, &buffer), kCVReturnSuccess)
            original = buffer
            if let buffer {
                let frame = SilentFrame(pixelBuffer: buffer, timestamp: .zero, orientation: .right,
                                        position: .front, mirrored: true, metadata: [:])
                XCTAssertTrue(worker.enqueue(.init(source: .silentFrame(frame), configuration: .disabled, diagnostics: .disabled)))
            }
        }
        await fulfillment(of: [saving], timeout: 5)
        XCTAssertTrue(worker.enqueue(job(data)))
        await fulfillment(of: [nextProcessed], timeout: 5)
        XCTAssertNil(original, "Save FIFO must not retain the native PixelBuffer")
        reply.value?(true)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(worker.pendingCount, 0)
    }

    func testPhotoKitAuthorizationFailureSkipsTransactionAndAuthorizedSaveFailureIsReturned() async {
        let writes = PhotoProcessingTestValue(0)
        for status in [PHAuthorizationStatus.denied, .restricted, .notDetermined] {
            let saved = await PhotoLibrarySaver.save(Data([1]), requestAuthorization: { status },
                saveAuthorizedPhoto: { _, _ in writes.update { $0 += 1 }; return true })
            XCTAssertFalse(saved)
        }
        XCTAssertEqual(writes.value, 0)
        for status in [PHAuthorizationStatus.authorized, .limited] {
            let saved = await PhotoLibrarySaver.save(Data([1]), requestAuthorization: { status },
                saveAuthorizedPhoto: { _, _ in writes.update { $0 += 1 }; return false })
            XCTAssertFalse(saved)
        }
        XCTAssertEqual(writes.value, 2)
    }

    private func job(_ data: Data, configuration: BeautyConfiguration = .disabled) -> PhotoProcessingJob {
        PhotoProcessingJob(source: .photoData(data), configuration: configuration, diagnostics: .disabled)
    }
}

/// Small real ImageIO input; no UIKit or camera is needed to construct test photos.
enum PhotoProcessingTestFixture {
    static func data() throws -> Data {
        let pixels = Data(repeating: 128, count: 16 * 12 * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 16, height: 12, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 16 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

final class PhotoProcessingTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { update { $0 } }
    @discardableResult
    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return body(&stored)
    }
}
