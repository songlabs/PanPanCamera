enum CameraPosition: String, Sendable {
    case front, back
    var opposite: Self { self == .front ? .back : .front }
}

enum CameraMode: String, CaseIterable, Identifiable, Sendable {
    case video, photo, portrait
    var id: Self { self }
    var isAvailable: Bool { self == .photo }
}

enum FlashMode: String, CaseIterable, Sendable {
    case off, auto, on

    func next(supported: [Self]) -> Self {
        let allowed = Self.allCases.filter { supported.contains($0) }
        guard !allowed.isEmpty else { return .off }
        guard let index = allowed.firstIndex(of: self) else { return allowed[0] }
        return allowed[(index + 1) % allowed.count]
    }
}

enum CameraAccess: Equatable, Sendable {
    case unknown, requesting, authorized, denied, restricted
}

enum CameraStatus: Equatable, Sendable {
    case idle, configuring, running, interrupted, unavailable, failed
}

struct CameraState: Equatable, Sendable {
    var access: CameraAccess = .unknown
    var status: CameraStatus = .idle
    private(set) var mode: CameraMode = .photo
    // Actual hardware position is updated only after a successful input transaction.
    var position: CameraPosition = .front
    var supportedFlashModes: [FlashMode] = [.off]
    var flash: FlashMode = .off
    var canSwitchCamera = false
    // Only native acquisition occupies the shutter, never final processing/saving.
    var isCapturing = false
    var isSwitching = false

    var canCapture: Bool {
        access == .authorized && status == .running && mode.isAvailable
            && !isCapturing && !isSwitching
    }

    mutating func selectMode(_ mode: CameraMode) {
        guard mode.isAvailable else { return }
        self.mode = mode
    }

    mutating func updateFlashCapabilities(_ supported: [FlashMode]) {
        supportedFlashModes = supported.isEmpty ? [.off] : supported
        if !supportedFlashModes.contains(flash) { flash = .off }
    }
}
