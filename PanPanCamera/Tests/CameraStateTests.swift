import XCTest
@testable import PanPanCamera

final class CameraStateTests: XCTestCase {
    func testPhotoIsTheOnlyAvailableModeAndUnsupportedSelectionDoesNotChangeIt() {
        var state = CameraState()
        XCTAssertEqual(state.mode, .photo)
        XCTAssertEqual(CameraMode.allCases.filter(\.isAvailable), [.photo])
        state.selectMode(.video)
        XCTAssertEqual(state.mode, .photo)
        state.selectMode(.portrait)
        XCTAssertEqual(state.mode, .photo)
    }

    func testCaptureRequiresPermissionAndRunningSession() {
        var state = CameraState()
        XCTAssertFalse(state.canCapture)
        state.access = .authorized
        for status in [CameraStatus.idle, .configuring, .interrupted, .unavailable, .failed] {
            state.status = status
            XCTAssertFalse(state.canCapture)
        }
        state.status = .running
        XCTAssertTrue(state.canCapture)
        for access in [CameraAccess.unknown, .requesting, .denied, .restricted] {
            state.access = access
            XCTAssertFalse(state.canCapture)
        }
    }

    func testCaptureAndSwitchInFlightDisableShutter() {
        var state = CameraState()
        state.access = .authorized
        state.status = .running
        state.isCapturing = true
        XCTAssertFalse(state.canCapture)
        state.isCapturing = false
        state.isSwitching = true
        XCTAssertFalse(state.canCapture)
        state.isSwitching = false
        XCTAssertTrue(state.canCapture)
    }

    func testOppositePositionDoesNotMutateActualHardwareState() {
        let state = CameraState()
        XCTAssertEqual(state.position, .front)
        XCTAssertEqual(state.position.opposite, .back)
        XCTAssertEqual(state.position, .front)
        XCTAssertEqual(CameraPosition.back.opposite, .front)
        XCTAssertEqual(state.position.opposite.opposite, state.position)
    }

    func testFlashCyclesOnlyThroughSupportedModes() {
        XCTAssertEqual(FlashMode.off.next(supported: [.off, .auto, .on]), .auto)
        XCTAssertEqual(FlashMode.auto.next(supported: [.off, .auto, .on]), .on)
        XCTAssertEqual(FlashMode.on.next(supported: [.off, .auto, .on]), .off)
        XCTAssertEqual(FlashMode.off.next(supported: [.off, .on]), .on)
        XCTAssertEqual(FlashMode.on.next(supported: [.off]), .off)
        XCTAssertEqual(FlashMode.auto.next(supported: []), .off)
    }

    func testSwitchingToCameraWithoutFlashClearsPreviousFlashMode() {
        var state = CameraState()
        state.updateFlashCapabilities([.off, .auto, .on])
        state.flash = .on
        state.updateFlashCapabilities([.off])
        XCTAssertEqual(state.flash, .off)
        XCTAssertEqual(state.supportedFlashModes, [.off])
        state.updateFlashCapabilities([])
        XCTAssertEqual(state.supportedFlashModes, [.off])
    }
}
