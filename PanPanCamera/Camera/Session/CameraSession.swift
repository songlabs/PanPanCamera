@preconcurrency import AVFoundation

enum CameraSessionEvent {
    case configuration(AVCaptureDevice, CameraPosition, Bool, [FlashMode])
    case status(CameraStatus)
    case switching(Bool)
    case captureFinished(CapturedPhoto?)
    case switchFailed
    case faceDetection(FaceDetectionDelivery?)
    case faceDetectionAvailability(Bool)
}

/// Commands consumed by CameraService. Hardware work remains inside CameraSession.
protocol CameraSessionControlling: AnyObject {
    var session: AVCaptureSession { get }
    func setRunning(_ shouldRun: Bool)
    func switchCamera()
    func capture(flash: FlashMode)
}

/// Owns all capture graph mutations on queue. The preview layer is the only external
/// consumer of session, and never starts/stops or changes its inputs and outputs.
final class CameraSession: CameraSessionControlling, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.panpan.session", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "camera.panpan.faces", qos: .utility)
    private let faceDetector = VisionFaceDetector()
    private var faceProcessor: CameraFaceFrameProcessor?
    private var faceRotationObservation: NSKeyValueObservation?
    private var videoOutputReady = false
    private let onEvent: (CameraSessionEvent) -> Void
    private var input: AVCaptureDeviceInput?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    // Retain delegates until final completion, including a capture invalidated by a reset.
    private var captures = PhotoCaptureRegistry<PhotoCaptureProcessor>()
    private var observers: [NSObjectProtocol] = []
    private var flashObservation: NSKeyValueObservation?
    private var configured = false
    private var lifecycle = CameraSessionLifecycle()

    init(onEvent: @escaping (CameraSessionEvent) -> Void) {
        self.onEvent = onEvent
        observeSession()
    }

    deinit {
        faceProcessor?.delivery.invalidate()
        queue.async { [videoOutput] in videoOutput.setSampleBufferDelegate(nil, queue: nil) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func setRunning(_ shouldRun: Bool) {
        queue.async { [self] in
            lifecycle.wantsRunning = shouldRun
            if shouldRun { startIfNeeded() }
            else {
                stopFaceDetection()
                if session.isRunning { session.stopRunning() }
                onEvent(.status(.idle))
            }
        }
    }

    func switchCamera() {
        queue.async { [self] in
            guard configured, session.isRunning, captures.activeID == nil,
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
            stopFaceDetection()
            let replacement = CameraInputReplacement<AVCaptureDeviceInput>.perform(
                current: oldInput, replacement: newInput,
                begin: { session.beginConfiguration() },
                remove: { session.removeInput($0) },
                canAdd: { session.canAddInput($0) },
                add: { session.addInput($0) },
                commit: { session.commitConfiguration() }
            )
            input = replacement.input
            configured = replacement.isConfigured
            if let active = input {
                configureVideoConnection()
                onEvent(.faceDetectionAvailability(videoOutputReady))
                observeDevice(active.device)
                publishConfiguration()
                updateFaceDetection()
            } else {
                session.stopRunning()
                onEvent(.status(.failed))
            }
            if !replacement.switched { onEvent(.switchFailed) }
            onEvent(.switching(false))
        }
    }

    func capture(flash: FlashMode) {
        queue.async { [self] in
            guard configured, session.isRunning, !session.isInterrupted,
                  captures.activeID == nil, let connection = output.connection(with: .video),
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
            let processor = PhotoCaptureProcessor { [weak self] data in
                guard let self else { return }
                self.queue.async {
                    guard self.captures.finish(id: captureID) else { return }
                    let photo = data.flatMap(CapturedPhoto.init(data:))
                    self.onEvent(.captureFinished(photo))
                }
            }
            captures.register(processor, id: captureID)
            output.capturePhoto(with: settings, delegate: processor)
        }
    }

    private func startIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard lifecycle.wantsRunning else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            stopFaceDetection()
            onEvent(.status(.idle))
            return
        }
        onEvent(.status(.configuring))
        if !configured {
            guard configure() else { return }
        }
        // Reassert the raw-buffer contract after a stop/reset as well as initial setup.
        configureVideoConnection()
        onEvent(.faceDetectionAvailability(videoOutputReady))
        if session.isInterrupted {
            stopFaceDetection()
            onEvent(.status(.interrupted))
            return
        }
        if !session.isRunning { session.startRunning() }
        publishConfiguration()
        onEvent(.status(session.isRunning ? .running : .failed))
        updateFaceDetection()
    }

    private func configure() -> Bool {
        stopFaceDetection()
        videoOutputReady = false
        onEvent(.faceDetectionAvailability(false))
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
        // Optional analysis output: failure must leave photo capture and preview usable.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.automaticallyConfiguresOutputBufferDimensions = true
        videoOutputReady = session.canAddOutput(videoOutput)
        if videoOutputReady {
            session.addOutput(videoOutput)
            // Prefer camera-native YUV over an unnecessary full-frame BGRA conversion.
            let formats = videoOutput.availableVideoPixelFormatTypes
            if let format = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].first(where: { formats.contains($0) }) {
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
            }
            configureVideoConnection()
        }
        onEvent(.faceDetectionAvailability(videoOutputReady))
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
        faceRotationObservation = nil
        rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        faceRotationObservation = rotation?.observe(\.videoRotationAngleForHorizonLevelCapture,
                                                    options: [.new]) { [weak self] _, _ in
            self?.queue.async { [weak self] in self?.updateFaceDetection() }
        }
        flashObservation = device.observe(\.isFlashAvailable, options: [.new]) { [weak self] _, _ in
            self?.queue.async { [weak self] in self?.publishConfiguration() }
        }
    }

    private func configureVideoConnection() {
        guard session.outputs.contains(where: { $0 === videoOutput }),
              let connection = videoOutput.connection(with: .video),
              connection.isVideoRotationAngleSupported(0) else {
            videoOutputReady = false
            return
        }
        // Vision receives sensor-native orientation; only Preview/photos are mirrored.
        connection.videoRotationAngle = 0
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        videoOutputReady = true
    }

    private func updateFaceDetection() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard videoOutputReady, lifecycle.wantsRunning, session.isRunning, !session.isInterrupted,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = input?.device, let rotation,
              let orientation = FaceImageOrientation(captureAngle: rotation.videoRotationAngleForHorizonLevelCapture) else {
            stopFaceDetection()
            return
        }
        guard faceProcessor?.deviceID != device.uniqueID || faceProcessor?.orientation != orientation else { return }
        stopFaceDetection()
        // Replacing the immutable delegate also rejects queued buffers from the old input.
        let processor = CameraFaceFrameProcessor(deviceID: device.uniqueID, orientation: orientation,
                                                 detector: faceDetector) { [weak self] delivery in
            self?.onEvent(.faceDetection(delivery))
        }
        faceProcessor = processor
        videoOutput.setSampleBufferDelegate(processor, queue: videoQueue)
    }

    private func stopFaceDetection() {
        faceProcessor?.delivery.invalidate()
        faceProcessor = nil
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        onEvent(.faceDetection(nil))
    }

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                             object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.lifecycle.wantsRunning else { return }
                self.stopFaceDetection()
                self.onEvent(.status(.interrupted))
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.didStopRunningNotification,
                                             object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, !self.session.isRunning else { return }
                self.stopFaceDetection()
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
                self.stopFaceDetection()
                if self.captures.invalidateActive() {
                    self.onEvent(.captureFinished(nil))
                }
                self.lifecycle.recover(wasReset: wasReset,
                                       restart: { self.startIfNeeded() },
                                       reportFailure: { self.onEvent(.status(.failed)) })
            }
        })
    }
}
