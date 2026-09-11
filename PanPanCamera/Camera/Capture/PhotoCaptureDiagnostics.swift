import Foundation

/// Opt-in, per-shutter monotonic timings. No pixels, metadata or face coordinates
/// are logged. Release builds retain the call surface but no timing/logging work.
final class PhotoCaptureDiagnostics: @unchecked Sendable {
    static let disabled = PhotoCaptureDiagnostics()

    #if DEBUG
    private let enabled: Bool
    private let id = UUID()
    private let effects: String
    private let lock = NSLock()
    private var source = "unselected"
    private var milestones: [String: ContinuousClock.Instant] = [:]
    #endif

    private init() {
        #if DEBUG
        enabled = false
        effects = "none"
        #endif
    }

    init(configuration: BeautyConfiguration) {
        #if DEBUG
        enabled = ProcessInfo.processInfo.arguments.contains("-PanPanPhotoPerformanceDiagnostics")
        var active: [String] = []
        if !configuration.isSkinBypassed { active.append("skin") }
        if configuration.enabled && !configuration.makeup.isBypassed { active.append("makeup") }
        if configuration.enabled && !configuration.filter.isBypassed { active.append("filter") }
        effects = active.isEmpty ? "none" : active.joined(separator: "+")
        #endif
        mark("shutter_requested")
    }

    func selectSource(_ value: String) {
        #if DEBUG
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        source = value
        log("source_selected", milliseconds: 0)
        #endif
    }

    func mark(_ stage: String) {
        #if DEBUG
        guard enabled else { return }
        let now = ContinuousClock.now
        lock.lock(); defer { lock.unlock() }
        milestones[stage] = now
        log(stage, milliseconds: milliseconds(from: milestones["shutter_requested"] ?? now, to: now))
        let interval: (String, String)?
        switch stage {
        case "capture_data": interval = ("shutter_requested", "total_shutter_to_capture_data")
        case "final_encoded": interval = ("capture_data", "total_capture_data_to_final_encoded")
        case "final_beauty_start": interval = ("job_enqueued", "queue_wait")
        case "photo_saved": interval = ("shutter_requested", "total_shutter_to_photo_saved")
        case "photokit_complete", "photokit_failed": interval = ("photokit_start", "photokit_latency")
        default: interval = nil
        }
        if let (start, name) = interval, let instant = milestones[start] {
            log(name, milliseconds: milliseconds(from: instant, to: now))
        }
        #endif
    }

    func backlog(_ count: Int, rejected: Bool = false) {
        #if DEBUG
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        log(rejected ? "backlog_rejected_count=\(count)" : "pending_count=\(count)", milliseconds: 0)
        #endif
    }

    func measure<T>(_ stage: String, _ operation: () throws -> T) rethrows -> T {
        #if DEBUG
        guard enabled else { return try operation() }
        let start = ContinuousClock.now
        defer {
            let end = ContinuousClock.now
            lock.lock()
            log(stage, milliseconds: milliseconds(from: start, to: end))
            lock.unlock()
        }
        #endif
        return try operation()
    }

    #if DEBUG
    private func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: end).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1_000_000_000_000_000
    }

    // Call only while holding lock; each log line has the same shutter identity.
    private func log(_ stage: String, milliseconds: Double) {
        print("[PhotoPerformance] id=\(id) source=\(source) effects=\(effects) stage=\(stage) ms=\(String(format: "%.2f", milliseconds))")
    }
    #endif
}
