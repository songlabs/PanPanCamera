/// Session-queue intent, shared by ordinary activation and runtime-error recovery.
struct CameraSessionLifecycle {
    var wantsRunning = false

    func recover(wasReset: Bool, restart: () -> Void, reportFailure: () -> Void) {
        guard wantsRunning else { return }
        if wasReset { restart() }
        else { reportFailure() }
    }
}
