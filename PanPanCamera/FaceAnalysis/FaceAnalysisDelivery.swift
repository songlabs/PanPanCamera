import Foundation

/// Main-actor observation mailbox; never controls ML admission or preview cadence.
final class FaceAnalysisDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var latest: FaceAnalysisResult?

    func complete(_ result: FaceAnalysisResult) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return false }
        let notify = latest == nil
        latest = result
        return notify
    }

    func consume() -> FaceAnalysisResult? {
        lock.lock(); defer { lock.unlock() }
        defer { latest = nil }
        return active ? latest : nil
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        active = false; latest = nil
    }
}
