import AVFoundation
import XCTest
@testable import PanPanCamera

@MainActor
final class CameraServiceTests: XCTestCase {
    private final class SessionCommands: CameraSessionControlling {
        var onEvent: ((CameraSessionEvent) -> Void)?
        var runningRequests: [Bool] = []
        var captures: [(flash: FlashMode, beauty: BeautyConfiguration)] = []
        var beautyConfigurations: [BeautyConfiguration] = []
        var session: AVCaptureSession { fatalError("These tests must not create a preview session") }
        let beautyPreviewFrames = BeautyPreviewFrameStore()
        func setRunning(_ shouldRun: Bool) { runningRequests.append(shouldRun) }
        func setBeautyConfiguration(_ configuration: BeautyConfiguration) {
            beautyConfigurations.append(configuration)
        }
        func switchCamera() {}
        func capture(flash: FlashMode, beauty: BeautyConfiguration) {
            captures.append((flash, beauty))
        }
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
        XCTAssertEqual(commands.captures.map { $0.flash }, [.off])
        await deliver(.captureFinished(nil), to: commands)
        XCTAssertEqual(camera.failure, .captureFailed)
        XCTAssertFalse(camera.state.isCapturing)
        XCTAssertTrue(camera.state.canCapture)
        camera.capture()
        XCTAssertNil(camera.failure)
    }

    func testCaptureSnapshotsBeautyConfigurationBeforeLaterSliderChanges() async {
        let commands = SessionCommands()
        let camera = service(permission: .init(current: { .authorized }, request: { .authorized }), commands: commands)
        await camera.setActive(true)
        await deliver(.status(.running), to: commands)
        camera.beautyParameters.setValue(86, for: SkinTool.auto)
        camera.beautyParameters.setValue(72, for: .smooth)
        camera.beautyParameters.setValue(64, for: FaceTool.auto)
        camera.beautyParameters.setValue(38, for: .slim)
        XCTAssertEqual(commands.beautyConfigurations.last?.faceOverallStrength, 0.64)
        XCTAssertEqual(commands.beautyConfigurations.last?.faceSlimStrength, 0.38)
        camera.capture()
        let captured = commands.captures.last?.beauty
        camera.beautyParameters.setValue(10, for: SkinTool.auto)
        XCTAssertEqual(captured?.overallStrength, 0.86)
        XCTAssertEqual(captured?.smoothingStrength, 0.72)
        XCTAssertEqual(captured?.effectiveFaceSlim ?? -1, 0.2432, accuracy: 0.000_001)
        XCTAssertEqual(commands.captures.last?.beauty, captured)
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

    private func faceDelivery(faces: [DetectedFace], outcome: FaceDetectionFrame.Outcome = .detected) -> FaceDetectionDelivery {
        let delivery = FaceDetectionDelivery()
        XCTAssertTrue(delivery.begin(at: 1))
        XCTAssertTrue(delivery.complete(FaceDetectionFrame(faces: faces, orientation: .right,
                                                           deviceID: "test-camera", pixelSize: .zero,
                                                           timestamp: 1, outcome: outcome), at: 1.01))
        return delivery
    }

    func testFaceResultsReplaceOldFacesWithZeroFacesAndFailureWithoutStoppingPreview() async {
        let commands = SessionCommands()
        let camera = service(permission: .init(current: { .authorized }, request: { .authorized }), commands: commands)
        await camera.setActive(true)
        await deliver(.status(.running), to: commands)
        let face = DetectedFace(boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                                confidence: 0.9, landmarks: [:])
        await deliver(.faceDetection(faceDelivery(faces: [face, face])), to: commands)
        XCTAssertEqual(camera.faceDetection?.faces.count, 2)
        await deliver(.faceDetection(faceDelivery(faces: [])), to: commands)
        XCTAssertEqual(camera.faceDetection?.faces, [])
        XCTAssertEqual(camera.faceDetection?.outcome, .detected)
        await deliver(.faceDetection(faceDelivery(faces: [face])), to: commands)
        await deliver(.faceDetection(faceDelivery(faces: [], outcome: .visionFailed)), to: commands)
        XCTAssertEqual(camera.faceDetection?.faces, [])
        XCTAssertEqual(camera.faceDetection?.outcome, .visionFailed)
        XCTAssertTrue(camera.state.canCapture)
        XCTAssertNil(camera.failure)
    }

    func testFacesClearOnInterruptionAndInactivityAndRejectLateResults() async {
        let commands = SessionCommands()
        let camera = service(permission: .init(current: { .authorized }, request: { .authorized }), commands: commands)
        await camera.setActive(true)
        await deliver(.status(.running), to: commands)
        await deliver(.faceDetection(faceDelivery(faces: [])), to: commands)
        XCTAssertNotNil(camera.faceDetection)
        await deliver(.status(.interrupted), to: commands)
        XCTAssertNil(camera.faceDetection)
        await deliver(.faceDetection(faceDelivery(faces: [])), to: commands)
        XCTAssertNil(camera.faceDetection)
        await deliver(.status(.running), to: commands)
        let obsolete = faceDelivery(faces: [])
        obsolete.invalidate()
        await deliver(.faceDetection(obsolete), to: commands)
        XCTAssertNil(camera.faceDetection)
        await deliver(.faceDetection(faceDelivery(faces: [])), to: commands)
        await camera.setActive(false)
        XCTAssertNil(camera.faceDetection)
        await deliver(.faceDetection(faceDelivery(faces: [])), to: commands)
        XCTAssertNil(camera.faceDetection)
    }

    func testUnavailableAnalysisOutputKeepsCameraRunningAndSwitchIgnoresOldFaces() async {
        let commands = SessionCommands()
        let camera = service(permission: .init(current: { .authorized }, request: { .authorized }), commands: commands)
        await camera.setActive(true)
        await deliver(.status(.running), to: commands)
        await deliver(.faceDetectionAvailability(true), to: commands)
        XCTAssertTrue(camera.isFaceDetectionAvailable)
        await deliver(.faceDetection(faceDelivery(faces: [])), to: commands)
        await deliver(.faceDetection(nil), to: commands)
        await deliver(.switching(true), to: commands)
        await deliver(.faceDetection(faceDelivery(faces: [])), to: commands)
        XCTAssertNil(camera.faceDetection)
        await deliver(.switching(false), to: commands)
        await deliver(.faceDetectionAvailability(false), to: commands)
        XCTAssertFalse(camera.isFaceDetectionAvailable)
        XCTAssertTrue(camera.state.canCapture)
    }
}
