import AVFoundation

enum CameraPermission {
    static var current: CameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return .unknown
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }

    static func request() async -> CameraAccess {
        if current == .unknown {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        return current
    }
}
