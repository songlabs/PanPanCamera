import AVFoundation
import Combine

/// Main-actor UI boundary. Camera controls and the shared Beauty parameter state
/// live here; pixel processing remains off-main in CameraSession/Rendering.
@MainActor
final class CameraService: ObservableObject {
    @Published private(set) var state = CameraState()
    @Published private(set) var previewDevice: AVCaptureDevice?
    @Published private(set) var faceDetection: FaceDetectionFrame?
    @Published private(set) var isFaceDetectionAvailable = false
    @Published var capturedPhoto: CapturedPhoto?
    @Published var failure: CameraFailure?
    @Published var beautyParameters = BeautyParameters() {
        didSet { captureSession.setBeautyConfiguration(beautyParameters.processingConfiguration) }
    }

    private var isActive = false
    private var permissionRequestInFlight = false
    private let permission: CameraPermissionProvider
    private let makeSession: (@escaping (CameraSessionEvent) -> Void) -> any CameraSessionControlling
    private lazy var captureSession: any CameraSessionControlling = makeSession { [weak self] event in
        // Session events are FIFO. Face results have an invalidatable, bounded mailbox.
        DispatchQueue.main.async { [weak self] in self?.handle(event) }
    }

    init(permission: CameraPermissionProvider? = nil,
         makeSession: @escaping (@escaping (CameraSessionEvent) -> Void) -> any CameraSessionControlling = {
             CameraSession(onEvent: $0)
         }) {
        self.permission = permission ?? .system
        self.makeSession = makeSession
    }

    // Used only by the UIViewRepresentable preview adapter.
    var previewSession: AVCaptureSession {
        captureSession.setBeautyConfiguration(beautyParameters.processingConfiguration)
        return captureSession.session
    }
    var beautyPreviewFrames: BeautyPreviewFrameStore { captureSession.beautyPreviewFrames }

    func setActive(_ active: Bool) async {
        isActive = active
        guard active else {
            faceDetection = nil
            captureSession.setRunning(false)
            state.status = .idle
            return
        }
        guard !permissionRequestInFlight else { return }
        state.access = permission.current()
        if state.access == .unknown {
            permissionRequestInFlight = true
            state.access = .requesting
            state.access = await permission.request()
            permissionRequestInFlight = false
        }
        // A permission prompt or background transition can change activity while awaiting.
        captureSession.setRunning(isActive && state.access == .authorized)
        if state.access != .authorized { faceDetection = nil }
    }

    func switchCamera() {
        guard state.canCapture, state.canSwitchCamera else { return }
        state.isSwitching = true
        faceDetection = nil
        captureSession.switchCamera()
    }

    func cycleFlash() {
        guard state.canCapture else { return }
        state.flash = state.flash.next(supported: state.supportedFlashModes)
    }

    func capture() {
        guard state.canCapture else { return }
        state.isCapturing = true
        failure = nil
        // Snapshot the value at the shutter boundary. Later slider changes cannot
        // affect this capture's asynchronous final processing.
        let beauty = beautyParameters.processingConfiguration
        captureSession.capture(flash: state.flash, beauty: beauty)
    }

    func selectMode(_ mode: CameraMode) { state.selectMode(mode) }

    private func handle(_ event: CameraSessionEvent) {
        switch event {
        case let .configuration(device, position, canSwitch, flashModes):
            previewDevice = device
            state.position = position
            state.canSwitchCamera = canSwitch
            state.updateFlashCapabilities(flashModes)
        case let .status(status):
            state.status = isActive ? status : .idle
            if state.status != .running { faceDetection = nil }
        case let .switching(value):
            state.isSwitching = value
        case let .captureFinished(photo):
            guard let photo else {
                state.isCapturing = false
                failure = .captureFailed
                return
            }
            Task { [weak self] in
                guard let self else { return }
                if await PhotoLibrarySaver.save(photo.data) { capturedPhoto = photo }
                else { failure = .captureFailed }
                state.isCapturing = false
            }
        case .switchFailed:
            state.isSwitching = false
            failure = .switchFailed
        case let .faceDetection(delivery):
            guard let delivery else {
                faceDetection = nil
                return
            }
            // Always consume, including while inactive, to release the producer's gate.
            guard let frame = delivery.consume(), isActive, state.access == .authorized,
                  state.status == .running, !state.isSwitching else { return }
            faceDetection = frame
        case let .faceDetectionAvailability(available):
            isFaceDetectionAvailable = available
            if !available { faceDetection = nil }
        }
    }
}
