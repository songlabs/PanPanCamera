import AVFoundation
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.updateDevice(device)
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

    func updateDevice(_ device: AVCaptureDevice?) {
        guard let device else { return }
        if deviceID != device.uniqueID {
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
        updateConnection()
    }

    private func updateConnection() {
        guard let rotation, let connection = previewLayer.connection else { return }
        let angle = rotation.videoRotationAngleForHorizonLevelPreview
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = rotation.device?.position == .front
        }
    }

    func detach() {
        observation = nil
        rotation = nil
        deviceID = nil
        previewLayer.session = nil
    }
}
