@preconcurrency import AVFoundation

enum CameraSessionEvent {
    case configuration(AVCaptureDevice, CameraPosition, Bool, [FlashMode])
    case status(CameraStatus)
    case switching(Bool)
    case captureFinished(succeeded: Bool)
    case photoProcessingFinished(PhotoProcessingResult)
    case photoProcessingStateChanged(PhotoProcessingState)
    case captureBacklogFull
    case switchFailed
    case faceDetection(FaceDetectionDelivery?)
    case faceDetectionAvailability(Bool)
}

/// Commands consumed by CameraService. Hardware work remains inside CameraSession.
protocol CameraSessionControlling: AnyObject {
    var session: AVCaptureSession { get }
    var beautyPreviewFrames: BeautyPreviewFrameStore { get }
    func setRunning(_ shouldRun: Bool)
    func setBeautyConfiguration(_ configuration: BeautyConfiguration)
    func switchCamera()
    func capture(flash: FlashMode, beauty: BeautyConfiguration, diagnostics: PhotoCaptureDiagnostics)
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
    private let frameStore = SilentFrameStore()
    let beautyPreviewFrames = BeautyPreviewFrameStore()
    private let beautyConfiguration = BeautyConfigurationStore()
    private lazy var photoProcessing = PhotoProcessingQueue(stateChanged: { [weak self] state in
        self?.queue.async { [weak self] in self?.onEvent(.photoProcessingStateChanged(state)) }
    }) { [weak self] photo in
        self?.queue.async { [weak self] in self?.onEvent(.photoProcessingFinished(photo)) }
    }
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

    func setBeautyConfiguration(_ configuration: BeautyConfiguration) {
        beautyConfiguration.replace(configuration)
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

    func capture(flash: FlashMode, beauty: BeautyConfiguration, diagnostics: PhotoCaptureDiagnostics) {
        queue.async { [self] in
            guard configured, session.isRunning, !session.isInterrupted, captures.activeID == nil else {
                onEvent(.captureFinished(succeeded: false))
                return
            }
            let strategy = captureStrategy()
            diagnostics.selectSource(strategy == .silentVideoFrame ? "silent_frame" : "photo_output")
            // Reject before obtaining another native image, never after silently
            // accumulating an unbounded set of full-resolution frames.
            guard photoProcessing.canAcceptJob else {
                diagnostics.backlog(photoProcessing.snapshot, rejected: true)
                onEvent(.photoProcessingStateChanged(photoProcessing.snapshot))
                onEvent(.captureBacklogFull)
                return
            }
            if strategy == .silentVideoFrame {
                captureSilentFrame(beauty: beauty, diagnostics: diagnostics)
                return
            }
            guard let connection = output.connection(with: .video), connection.isActive else {
                onEvent(.captureFinished(succeeded: false)); return
            }
            let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
            guard connection.isVideoRotationAngleSupported(angle) else {
                onEvent(.captureFinished(succeeded: false))
                return
            }
            connection.videoRotationAngle = angle
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                // Match the mirrored selfie preview; rear captures remain unmirrored.
                connection.isVideoMirrored = input?.device.position == .front
            }
            let settings = output.availablePhotoCodecTypes.contains(.jpeg)
                ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                : AVCapturePhotoSettings()
            if #available(iOS 18.0, *), output.isShutterSoundSuppressionSupported {
                settings.isShutterSoundSuppressionEnabled = true
            }
            let requested = avFlash(flash)
            settings.flashMode = availableFlashModes().contains(flash) ? requested : .off
            settings.photoQualityPrioritization = .quality
            settings.maxPhotoDimensions = output.maxPhotoDimensions
            let captureID = settings.uniqueID
            let processor = PhotoCaptureProcessor(diagnostics: diagnostics) { [weak self] data in
                self?.queue.async { [weak self] in
                    guard let self, self.captures.finish(id: captureID) else { return }
                    diagnostics.mark("capture_slot_released")
                    if let data {
                        self.submitPhoto(.photoData(data), beauty: beauty, diagnostics: diagnostics)
                    }
                    self.onEvent(.captureFinished(succeeded: data != nil))
                }
            }
            captures.register(processor, id: captureID)
            diagnostics.mark("avcapture_submitted")
            output.capturePhoto(with: settings, delegate: processor)
        }
    }

    private func captureStrategy() -> SilentCaptureStrategy {
        if #available(iOS 18.0, *) {
            return .select(suppressionSupported: output.isShutterSoundSuppressionSupported)
        }
        return .silentVideoFrame
    }

    private func captureSilentFrame(beauty: BeautyConfiguration, diagnostics: PhotoCaptureDiagnostics) {
        dispatchPrecondition(condition: .onQueue(queue))
        diagnostics.mark("silent_frame_start")
        guard let frame = frameStore.take() else {
            onEvent(.captureFinished(succeeded: false)); return
        }
        // Taking the native buffer completes acquisition; no AV delegate/slot is
        // needed for the independent job that now owns that immutable frame.
        #if DEBUG
        diagnostics.input(width: CVPixelBufferGetWidth(frame.pixelBuffer),
                          height: CVPixelBufferGetHeight(frame.pixelBuffer),
                          pixelFormat: String(CVPixelBufferGetPixelFormatType(frame.pixelBuffer)))
        #endif
        diagnostics.mark("capture_data_ready")
        diagnostics.value("photo_data_bytes", 0) // Native buffer source, no encoded acquisition data.
        diagnostics.mark("capture_slot_released")
        submitPhoto(.silentFrame(frame), beauty: beauty, diagnostics: diagnostics)
        onEvent(.captureFinished(succeeded: true))
    }

    private func submitPhoto(_ source: PhotoProcessingJob.Source, beauty: BeautyConfiguration,
                             diagnostics: PhotoCaptureDiagnostics) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Only this session queue admits jobs; an in-flight acquisition prevents
        // another submitter, and workers can only release capacity in between.
        let accepted = photoProcessing.enqueue(PhotoProcessingJob(source: source, configuration: beauty,
                                                                  diagnostics: diagnostics))
        assert(accepted, "Capacity checked before the sole native acquisition")
        if !accepted { onEvent(.captureBacklogFull) }
        // Publish capacity before releasing the shutter. Revision rejects older
        // queued worker snapshots that arrive after this synchronous snapshot.
        onEvent(.photoProcessingStateChanged(photoProcessing.snapshot))
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
        output.maxPhotoQualityPrioritization = .quality
        if #available(iOS 17.0, *) {
            let supportedDimensions = newInput.device.activeFormat.supportedMaxPhotoDimensions
            var largestDimension: CMVideoDimensions?
            var largestPixelCount: Int64 = -1
            for dimension in supportedDimensions {
                let width = Int64(dimension.width)
                let height = Int64(dimension.height)
                let pixelCount = width * height
                if pixelCount > largestPixelCount {
                    largestPixelCount = pixelCount
                    largestDimension = dimension
                }
            }
            if let largestDimension {
                output.maxPhotoDimensions = largestDimension
            }
        }
        // Optional analysis output: failure must leave photo capture and preview usable.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.automaticallyConfiguresOutputBufferDimensions = false
        videoOutputReady = session.canAddOutput(videoOutput)
        if videoOutputReady {
            session.addOutput(videoOutput)
            // Prefer camera-native YUV over an unnecessary full-frame BGRA conversion.
            let formats = videoOutput.availableVideoPixelFormatTypes
            if let format = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].first(where: { formats.contains($0) }) {
                let dimensions = CMVideoFormatDescriptionGetDimensions(newInput.device.activeFormat.formatDescription)
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: format,
                    kCVPixelBufferWidthKey as String: Int(dimensions.width),
                    kCVPixelBufferHeightKey as String: Int(dimensions.height)
                ]
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
        guard captureStrategy() == .suppressedPhotoOutput else { return [.off] }
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
        let processor = CameraFaceFrameProcessor(device: device, orientation: orientation,
                                                 detector: faceDetector, frameStore: frameStore,
                                                 previewFrameStore: beautyPreviewFrames,
                                                 beautyConfiguration: beautyConfiguration) { [weak self] delivery in
            self?.onEvent(.faceDetection(delivery))
        }
        faceProcessor = processor
        videoOutput.setSampleBufferDelegate(processor, queue: videoQueue)
    }

    private func stopFaceDetection() {
        frameStore.clear()
        beautyPreviewFrames.clear()
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
                    self.onEvent(.captureFinished(succeeded: false))
                }
                self.lifecycle.recover(wasReset: wasReset,
                                       restart: { self.startIfNeeded() },
                                       reportFailure: { self.onEvent(.status(.failed)) })
            }
        })
    }
}
