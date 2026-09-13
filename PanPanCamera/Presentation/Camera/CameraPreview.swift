import AVFoundation
import Metal
import QuartzCore
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?
    let beautyFrames: BeautyPreviewFrameStore
    let beautyConfiguration: BeautyConfiguration
    let isActive: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.updateDevice(device)
        uiView.updateBeauty(frames: beautyFrames, configuration: beautyConfiguration,
                            isActive: isActive)
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: ()) {
        uiView.detach()
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private var deviceID: String?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var observation: NSKeyValueObservation?
    private let beautySurface = BeautyPreviewSurfaceView()
    private var beautyRenderer: BeautyPreviewRenderer?
    private var beautyFrames: BeautyPreviewFrameStore?
    private var beautyConfiguration = BeautyConfiguration.disabled
    private var beautyIsActive = false
    private var beautyRotationAngle: CGFloat = 0
    private var displayLink: CADisplayLink?
    private var faceOverlay: FaceAnalysisDebugOverlay?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(beautySurface)
        if let device = MTLCreateSystemDefaultDevice() {
            beautySurface.configure(device: device)
            beautyRenderer = BeautyPreviewRenderer(device: device)
        }
        if FaceAnalysisDebugOverlay.isEnabled {
            faceOverlay = FaceAnalysisDebugOverlay(previewLayer: previewLayer)
        }
        displayLink = CADisplayLink(target: self, selector: #selector(renderBeautyFrame))
        displayLink?.add(to: .main, forMode: .common)
        displayLink?.isPaused = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateDevice(_ device: AVCaptureDevice?) {
        guard let device else { return }
        if deviceID != device.uniqueID {
            hideBeautyFrame()
            faceOverlay?.update(nil)
            deviceID = device.uniqueID
            observation = nil
            rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            observation = rotation?.observe(\.videoRotationAngleForHorizonLevelPreview,
                                             options: [.initial, .new]) { [weak self] _, _ in
                // RotationCoordinator delivers its KVO updates on the main queue.
                MainActor.assumeIsolated { self?.updateConnection() }
            }
        }
        updateConnection()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        beautySurface.frame = bounds
        if beautySurface.updateDrawableSize() {
            hideBeautyFrame()
            faceOverlay?.update(nil)
        }
        faceOverlay?.redraw()
        updateConnection()
    }

    private func updateConnection() {
        guard let rotation, let connection = previewLayer.connection else { return }
        let angle = rotation.videoRotationAngleForHorizonLevelPreview
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        if angle.isFinite, abs(angle - beautyRotationAngle) > 0.01 {
            beautyRotationAngle = angle
            hideBeautyFrame()
            faceOverlay?.update(nil)
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = rotation.device?.position == .front
        }
        faceOverlay?.redraw()
    }

    func updateBeauty(frames: BeautyPreviewFrameStore, configuration: BeautyConfiguration,
                      isActive: Bool) {
        beautyFrames = frames
        let changed = configuration != beautyConfiguration || isActive != beautyIsActive
        beautyConfiguration = configuration
        beautyIsActive = isActive
        displayLink?.isPaused = !isActive ||
            (configuration.isBypassed && !FaceAnalysisDebugOverlay.isEnabled) || beautyRenderer == nil
        if changed { hideBeautyFrame() }
    }

    @objc private func renderBeautyFrame() {
        guard beautyIsActive,
              (!beautyConfiguration.isBypassed || FaceAnalysisDebugOverlay.isEnabled),
              let beautyFrames, let beautyRenderer,
              beautySurface.metalLayer.drawableSize.width >= 1,
              beautySurface.metalLayer.drawableSize.height >= 1 else { return }
        beautyRenderer.requestFrame(from: beautyFrames, layer: beautySurface.metalLayer,
            rotationAngle: beautyRotationAngle,
            targetSize: beautySurface.metalLayer.drawableSize) { [weak self] success, geometry in
                guard let self, self.beautyIsActive else { return }
                self.faceOverlay?.update(geometry)
                self.beautySurface.isHidden = !success ||
                    (self.beautyConfiguration.isBypassed && !FaceAnalysisDebugMode.isEnabled)
            }
    }

    private func hideBeautyFrame() {
        beautyRenderer?.invalidate()
        beautySurface.isHidden = true
    }

    func detach() {
        displayLink?.invalidate()
        displayLink = nil
        hideBeautyFrame()
        beautyFrames = nil
        observation = nil
        rotation = nil
        deviceID = nil
        faceOverlay?.update(nil)
        previewLayer.session = nil
    }
}

private final class BeautyPreviewSurfaceView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        metalLayer.isOpaque = true
        metalLayer.framebufferOnly = false
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.contentsGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(device: MTLDevice) { metalLayer.device = device }

    func updateDrawableSize() -> Bool {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let native = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let longest = max(native.width, native.height)
        let previewScale = longest > 1280 ? 1280 / longest : 1
        let size = CGSize(width: max(1, floor(native.width * previewScale)),
                          height: max(1, floor(native.height * previewScale)))
        guard size != metalLayer.drawableSize else { return false }
        metalLayer.drawableSize = size
        return true
    }
}
