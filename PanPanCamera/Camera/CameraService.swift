import AVFoundation
import Combine

/// Main-actor UI boundary. It knows nothing about beauty panels or their parameters.
@MainActor
final class CameraService: ObservableObject {
    @Published private(set) var state = CameraState()
    @Published private(set) var previewDevice: AVCaptureDevice?
    @Published var capturedPhoto: CapturedPhoto?
    @Published var errorMessage: L10n?

    private var isActive = false
    private var permissionRequestInFlight = false
    private lazy var captureSession = CameraSession { [weak self] event in
        // Preserve event order from the serial session queue.
        DispatchQueue.main.async { [weak self] in self?.handle(event) }
    }

    // Used only by the UIViewRepresentable preview adapter.
    var previewSession: AVCaptureSession { captureSession.session }

    func setActive(_ active: Bool) async {
        isActive = active
        guard active else {
            captureSession.setRunning(false)
            state.status = .idle
            return
        }
        guard !permissionRequestInFlight else { return }
        state.access = CameraPermission.current
        if state.access == .unknown {
            permissionRequestInFlight = true
            state.access = .requesting
            state.access = await CameraPermission.request()
            permissionRequestInFlight = false
        }
        // A permission prompt or background transition can change activity while awaiting.
        captureSession.setRunning(isActive && state.access == .authorized)
    }

    func switchCamera() {
        guard state.canCapture, state.canSwitchCamera else { return }
        state.isSwitching = true
        captureSession.switchCamera()
    }

    func cycleFlash() {
        guard state.canCapture else { return }
        state.flash = state.flash.next(supported: state.supportedFlashModes)
    }

    func capture() {
        guard state.canCapture else { return }
        state.isCapturing = true
        errorMessage = nil
        captureSession.capture(flash: state.flash)
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
        case let .switching(value):
            state.isSwitching = value
        case let .captureFinished(photo):
            state.isCapturing = false
            if let photo { capturedPhoto = photo }
            else { errorMessage = .captureFailed }
        case .switchFailed:
            state.isSwitching = false
            errorMessage = .switchFailed
        }
    }
}
