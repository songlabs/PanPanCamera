import ImageIO
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
        }, save: { bytes, completion in
            XCTAssertFalse(Thread.isMainThread)
            saved.update { $0.append(bytes) }
            completion(true)
        }, completion: { photo in
            XCTAssertNotNil(photo)
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
        let worker = PhotoProcessingQueue(save: { bytes, completion in
            saves.update { $0.append(bytes) }
            completion(true)
        }, completion: { photo in
            results.update { $0.append(photo != nil) }
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
        }, save: { bytes, completion in
            saved.update { $0.append(bytes) }
            completion(true)
        }, completion: { photo in
            results.update { $0.append(photo != nil) }
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
        let worker = PhotoProcessingQueue(maximumPendingCount: 2, save: { _, completion in
            let count = saves.update { $0 += 1; return $0 }
            if count == 1 {
                resume.update { $0 = completion }
                saving.fulfill()
            } else { completion(true) }
        }, completion: { photo in
            results.update { $0.append(photo != nil) }
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
