@preconcurrency import AVFoundation

enum CameraSessionEvent {
    case configuration(AVCaptureDevice, CameraPosition, Bool, [FlashMode])
    case status(CameraStatus)
    case switching(Bool)
    case captureFinished(CapturedPhoto?)
    case switchFailed
}

/// Owns all capture graph mutations on queue. The preview layer is the only external
/// consumer of session, and never starts/stops or changes its inputs and outputs.
final class CameraSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.panpan.session", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private let onEvent: (CameraSessionEvent) -> Void
    private var input: AVCaptureDeviceInput?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    // Retain delegates until final completion, including a capture invalidated by a reset.
    private var photoProcessors: [Int64: PhotoCaptureProcessor] = [:]
    private var activeCaptureID: Int64?
    private var observers: [NSObjectProtocol] = []
    private var flashObservation: NSKeyValueObservation?
    private var configured = false
    private var wantsRunning = false

    init(onEvent: @escaping (CameraSessionEvent) -> Void) {
        self.onEvent = onEvent
        observeSession()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func setRunning(_ shouldRun: Bool) {
        queue.async { [self] in
            wantsRunning = shouldRun
            if shouldRun { startIfNeeded() }
            else {
                if session.isRunning { session.stopRunning() }
                onEvent(.status(.idle))
            }
        }
    }

    func switchCamera() {
        queue.async { [self] in
            guard configured, session.isRunning, activeCaptureID == nil,
                  let oldInput = input else {
                onEvent(.switching(false))
                return
            }
            let next: CameraPosition = oldInput.device.position == .front ? .back : .front
            guard let device = device(for: next),
                  let newInput = try? AVCaptureDeviceInput(device: device) else {
                onEvent(.switchFailed)
                return
            }
            session.beginConfiguration()
            session.removeInput(oldInput)
            let switched = session.canAddInput(newInput)
            if switched {
                session.addInput(newInput)
                input = newInput
            } else if session.canAddInput(oldInput) {
                session.addInput(oldInput)
            } else {
                input = nil
                configured = false
            }
            session.commitConfiguration()
            if let active = input {
                observeDevice(active.device)
                publishConfiguration()
            } else {
                session.stopRunning()
                onEvent(.status(.failed))
            }
            if !switched { onEvent(.switchFailed) }
            onEvent(.switching(false))
        }
    }

    func capture(flash: FlashMode) {
        queue.async { [self] in
            guard configured, session.isRunning, !session.isInterrupted,
                  activeCaptureID == nil, let connection = output.connection(with: .video),
                  connection.isActive else {
                onEvent(.captureFinished(nil))
                return
            }
            let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
            guard connection.isVideoRotationAngleSupported(angle) else {
                onEvent(.captureFinished(nil))
                return
            }
            connection.videoRotationAngle = angle
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                // Match the mirrored selfie preview; rear captures remain unmirrored.
                connection.isVideoMirrored = input?.device.position == .front
            }
            let settings = AVCapturePhotoSettings()
            let requested = avFlash(flash)
            settings.flashMode = availableFlashModes().contains(flash) ? requested : .off
            settings.photoQualityPrioritization = .balanced
            let captureID = settings.uniqueID
            activeCaptureID = captureID
            let processor = PhotoCaptureProcessor { [weak self] data in
                guard let self else { return }
                self.queue.async {
                    self.photoProcessors.removeValue(forKey: captureID)
                    guard self.activeCaptureID == captureID else { return }
                    let photo = data.flatMap(CapturedPhoto.init(data:))
                    self.activeCaptureID = nil
                    self.onEvent(.captureFinished(photo))
                }
            }
            photoProcessors[captureID] = processor
            output.capturePhoto(with: settings, delegate: processor)
        }
    }

    private func startIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard wantsRunning else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            onEvent(.status(.idle))
            return
        }
        onEvent(.status(.configuring))
        if !configured {
            guard configure() else { return }
        }
        if session.isInterrupted {
            onEvent(.status(.interrupted))
            return
        }
        if !session.isRunning { session.startRunning() }
        publishConfiguration()
        onEvent(.status(session.isRunning ? .running : .failed))
    }

    private func configure() -> Bool {
        guard let device = device(for: .front) ?? device(for: .back) else {
            onEvent(.status(.unavailable))
            return false
        }
        guard let newInput = try? AVCaptureDeviceInput(device: device) else {
            onEvent(.status(.failed))
            return false
        }
        session.beginConfiguration()
        // This also permits a clean retry after a failed input rollback.
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.sessionPreset = .photo
        guard session.canAddInput(newInput) else {
            session.commitConfiguration()
            onEvent(.status(.failed))
            return false
        }
        session.addInput(newInput)
        guard session.canAddOutput(output) else {
            session.removeInput(newInput)
            session.commitConfiguration()
            onEvent(.status(.failed))
            return false
        }
        session.addOutput(output)
        output.maxPhotoQualityPrioritization = .balanced
        input = newInput
        session.commitConfiguration()
        configured = true
        observeDevice(device)
        publishConfiguration()
        return true
    }

    private func device(for position: CameraPosition) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                position: position == .front ? .front : .back)
    }

    private func avFlash(_ mode: FlashMode) -> AVCaptureDevice.FlashMode {
        switch mode {
        case .off: return .off
        case .auto: return .auto
        case .on: return .on
        }
    }

    private func availableFlashModes() -> [FlashMode] {
        guard let device = input?.device, device.hasFlash, device.isFlashAvailable else {
            return [.off]
        }
        return FlashMode.allCases.filter { output.supportedFlashModes.contains(avFlash($0)) }
    }

    private func publishConfiguration() {
        guard let device = input?.device else { return }
        let position: CameraPosition = device.position == .front ? .front : .back
        onEvent(.configuration(device, position, self.device(for: position.opposite) != nil,
                               availableFlashModes()))
    }

    private func observeDevice(_ device: AVCaptureDevice) {
        rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        flashObservation = device.observe(\.isFlashAvailable, options: [.new]) { [weak self] _, _ in
            self?.queue.async { [weak self] in self?.publishConfiguration() }
        }
    }

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                             object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.wantsRunning else { return }
                self.onEvent(.status(.interrupted))
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                             object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in self?.startIfNeeded() }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                             object: session, queue: nil) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            let wasReset = error?.code == .mediaServicesWereReset
            self?.queue.async { [weak self] in
                guard let self else { return }
                if self.activeCaptureID != nil {
                    self.activeCaptureID = nil
                    self.onEvent(.captureFinished(nil))
                }
                if wasReset && self.wantsRunning { self.startIfNeeded() }
                else if self.wantsRunning { self.onEvent(.status(.failed)) }
            }
        })
    }
}
