import XCTest
@testable import PanPanCamera

final class CameraSessionControlTests: XCTestCase {
    func testSilentStrategyPrefersSuppressedPhotoOutput() {
        XCTAssertEqual(SilentCaptureStrategy.select(suppressionSupported: true), .suppressedPhotoOutput)
    }

    func testSilentStrategyFallsBackToVideoFrame() {
        XCTAssertEqual(SilentCaptureStrategy.select(suppressionSupported: false), .silentVideoFrame)
    }

    func testSilentFrameStoreFailsSafelyWithoutAFrameAndConsumesOnce() {
        let store = SilentFrameStore()
        XCTAssertNil(store.take())
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        store.replace(SilentFrame(pixelBuffer: buffer!, timestamp: .zero, orientation: .right,
                                  position: .front, mirrored: true, metadata: [:]))
        let captured = store.take()
        XCTAssertEqual(captured?.position, .front)
        XCTAssertEqual(captured?.mirrored, true)
        XCTAssertNil(store.take())
    }

    func testSilentFrameOrientationIncludesFrontMirror() {
        XCTAssertEqual(SilentFrameOrientation.exif(captureOrientation: .up, mirrored: false), .up)
        XCTAssertEqual(SilentFrameOrientation.exif(captureOrientation: .right, mirrored: false), .right)
        XCTAssertEqual(SilentFrameOrientation.exif(captureOrientation: .down, mirrored: false), .down)
        XCTAssertEqual(SilentFrameOrientation.exif(captureOrientation: .left, mirrored: false), .left)
        XCTAssertEqual(SilentFrameOrientation.exif(captureOrientation: .right, mirrored: true), .leftMirrored)
        XCTAssertEqual(SilentFrameOrientation.exif(captureOrientation: .left, mirrored: true), .rightMirrored)
    }
    private func replace(allowed: Set<CameraPosition>) -> (CameraInputReplacement<CameraPosition>, [String]) {
        var operations: [String] = []
        let result = CameraInputReplacement<CameraPosition>.perform(
            current: .back, replacement: .front,
            begin: { operations.append("begin") },
            remove: { operations.append("remove.\($0.rawValue)") },
            canAdd: { operations.append("canAdd.\($0.rawValue)"); return allowed.contains($0) },
            add: { operations.append("add.\($0.rawValue)") },
            commit: { operations.append("commit") }
        )
        return (result, operations)
    }

    func testInputReplacementCommitsFrontInput() {
        let (result, operations) = replace(allowed: [.front, .back])
        XCTAssertEqual(result.input, .front)
        XCTAssertTrue(result.switched)
        XCTAssertTrue(result.isConfigured)
        XCTAssertEqual(operations, ["begin", "remove.back", "canAdd.front", "add.front", "commit"])
    }

    func testRejectedFrontInputRestoresRearWithinSameTransaction() {
        let (result, operations) = replace(allowed: [.back])
        XCTAssertEqual(result.input, .back)
        XCTAssertFalse(result.switched)
        XCTAssertTrue(result.isConfigured)
        XCTAssertEqual(operations, ["begin", "remove.back", "canAdd.front", "canAdd.back", "add.back", "commit"])
    }

    func testFailedRollbackCommitsUnconfiguredResult() {
        let (result, operations) = replace(allowed: [])
        XCTAssertNil(result.input)
        XCTAssertFalse(result.switched)
        XCTAssertFalse(result.isConfigured)
        XCTAssertEqual(operations, ["begin", "remove.back", "canAdd.front", "canAdd.back", "commit"])
    }

    func testMediaResetRestartsOnlyWhileRunningIsWanted() {
        var lifecycle = CameraSessionLifecycle()
        var commands: [String] = []
        lifecycle.wantsRunning = true
        lifecycle.recover(wasReset: true, restart: { commands.append("restart") },
                          reportFailure: { commands.append("failed") })
        XCTAssertEqual(commands, ["restart"])
        lifecycle.wantsRunning = false
        lifecycle.recover(wasReset: true, restart: { commands.append("restart") },
                          reportFailure: { commands.append("failed") })
        XCTAssertEqual(commands, ["restart"])
    }

    func testOtherRuntimeErrorReportsFailureOnlyWhileActive() {
        var lifecycle = CameraSessionLifecycle()
        var commands: [String] = []
        lifecycle.wantsRunning = true
        lifecycle.recover(wasReset: false, restart: { commands.append("restart") },
                          reportFailure: { commands.append("failed") })
        XCTAssertEqual(commands, ["failed"])
        lifecycle.wantsRunning = false
        lifecycle.recover(wasReset: false, restart: { commands.append("restart") },
                          reportFailure: { commands.append("failed") })
        XCTAssertEqual(commands, ["failed"])
    }
}
