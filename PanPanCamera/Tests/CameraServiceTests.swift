import AVFoundation
import XCTest
@testable import PanPanCamera

@MainActor
final class CameraServiceTests: XCTestCase {
    private final class SessionCommands: CameraSessionControlling {
        var onEvent: ((CameraSessionEvent) -> Void)?
        var runningRequests: [Bool] = []
        var captures: [FlashMode] = []
        var session: AVCaptureSession { fatalError("These tests must not create a preview session") }
        func setRunning(_ shouldRun: Bool) { runningRequests.append(shouldRun) }
        func switchCamera() {}
        func capture(flash: FlashMode) { captures.append(flash) }
    }

    private func service(permission: CameraPermissionProvider, commands: SessionCommands) -> CameraService {
        CameraService(permission: permission, makeSession: { onEvent in
            commands.onEvent = onEvent
            return commands
        })
    }

    /// Events use the production FIFO delivery to main, never a direct handle() call.
    private func deliver(_ event: CameraSessionEvent, to commands: SessionCommands) async {
        commands.onEvent?(event)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testPermissionGrantedWhileInactiveWaitsForNextActivation() async {
        let requested = expectation(description: "System permission request started")
        var current = CameraAccess.unknown
        var continuation: CheckedContinuation<CameraAccess, Never>?
        var requests = 0
        let permission = CameraPermissionProvider(current: { current }, request: {
            requests += 1
            return await withCheckedContinuation {
                continuation = $0
                requested.fulfill()
            }
        })
        let commands = SessionCommands()
        let camera = service(permission: permission, commands: commands)
        let activation = Task { await camera.setActive(true) }
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertEqual(camera.state.access, .requesting)
        await camera.setActive(true)
        XCTAssertEqual(requests, 1)
        await camera.setActive(false)
        current = .authorized
        continuation?.resume(returning: .authorized)
        await activation.value
        XCTAssertEqual(camera.state.access, .authorized)
        XCTAssertEqual(camera.state.status, .idle)
        XCTAssertFalse(commands.runningRequests.contains(true))

        await camera.setActive(true)
        XCTAssertEqual(commands.runningRequests.filter { $0 }.count, 1)
        XCTAssertEqual(requests, 1)
        await deliver(.status(.running), to: commands)
        XCTAssertTrue(camera.state.canCapture)
    }

    func testSettingsReturnRereadsDeniedPermissionAndStartsWhenAuthorized() async {
        var current = CameraAccess.denied
        let commands = SessionCommands()
        let camera = service(permission: .init(current: { current }, request: {
            XCTFail("Determined permission must not prompt again")
            return current
        }), commands: commands)
        await camera.setActive(true)
        XCTAssertEqual(camera.state.access, .denied)
        XCTAssertEqual(commands.runningRequests, [false])
        await camera.setActive(false)
        current = .authorized
        await camera.setActive(true)
        await deliver(.status(.running), to: commands)
        XCTAssertEqual(commands.runningRequests, [false, false, true])
        XCTAssertTrue(camera.state.canCapture)
    }

    func testInactiveIgnoresLateRunningEvent() async {
        let commands = SessionCommands()
        let camera = service(permission: .init(current: { .authorized }, request: { .authorized }), commands: commands)
        await camera.setActive(true)
        // This event is queued before inactivity but delivered after it.
        commands.onEvent?(.status(.running))
        await camera.setActive(false)
        await deliver(.status(.running), to: commands)
        XCTAssertEqual(camera.state.status, .idle)
        XCTAssertFalse(camera.state.canCapture)
        XCTAssertEqual(commands.runningRequests, [true, false])
    }

    func testCaptureFailurePublishesSemanticFailureAndClearsBusyState() async {
        let commands = SessionCommands()
        let camera = service(permission: .init(current: { .authorized }, request: { .authorized }), commands: commands)
        await camera.setActive(true)
        await deliver(.status(.running), to: commands)
        camera.capture()
        XCTAssertTrue(camera.state.isCapturing)
        XCTAssertEqual(commands.captures, [.off])
        await deliver(.captureFinished(nil), to: commands)
        XCTAssertEqual(camera.failure, .captureFailed)
        XCTAssertFalse(camera.state.isCapturing)
        XCTAssertTrue(camera.state.canCapture)
        camera.capture()
        XCTAssertNil(camera.failure)
    }

    func testSwitchFailurePublishesSemanticFailureAndClearsBusyState() async {
        let commands = SessionCommands()
        let camera = service(permission: .init(current: { .authorized }, request: { .authorized }), commands: commands)
        await camera.setActive(true)
        await deliver(.switching(true), to: commands)
        XCTAssertTrue(camera.state.isSwitching)
        await deliver(.switchFailed, to: commands)
        XCTAssertEqual(camera.failure, .switchFailed)
        XCTAssertFalse(camera.state.isSwitching)
    }

    func testServiceConstructionDoesNotCreateSessionOrRequestPermission() {
        var creations = 0
        let camera = CameraService(permission: .init(current: {
            XCTFail("Construction must not read permission")
            return .unknown
        }, request: {
            XCTFail("Construction must not request permission")
            return .denied
        }), makeSession: { _ in
            creations += 1
            return SessionCommands()
        })
        XCTAssertEqual(camera.state, CameraState())
        XCTAssertEqual(creations, 0)
    }

    func testSemanticFailuresMapToExistingPresentationKeys() {
        XCTAssertEqual(CameraFailure.captureFailed.localizedKey, .captureFailed)
        XCTAssertEqual(CameraFailure.switchFailed.localizedKey, .switchFailed)
    }
}
