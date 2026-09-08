import Foundation

/// One capture-generation's admission gate and single-result mailbox.
/// All fields are lock protected. Invalidation never waits for Vision or the main queue.
final class FaceDetectionDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var busy = false
    private var startedAt: TimeInterval = 0
    private var nextStart: TimeInterval = 0
    private var latest: FaceDetectionFrame?

    func begin(at time: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active, !busy, time >= nextStart else { return false }
        busy = true
        startedAt = time
        return true
    }

    /// Returns true only when the consumer needs one notification. Admission stays closed
    /// until consumption, so even a stalled main thread cannot accumulate result callbacks.
    func complete(_ frame: FaceDetectionFrame, at time: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active, busy, latest == nil else { return false }
        latest = frame
        // At most 8 starts/sec, and a cooldown at least as long as the last request.
        nextStart = max(startedAt + 0.125, time + max(0.05, time - startedAt))
        return true
    }

    func consume() -> FaceDetectionFrame? {
        lock.lock()
        defer { lock.unlock() }
        defer { latest = nil; busy = false }
        return active ? latest : nil
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        active = false
        latest = nil
    }
}
