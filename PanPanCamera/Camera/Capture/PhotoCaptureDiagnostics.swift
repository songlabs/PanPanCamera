import Foundation

/// Opt-in, per-shutter monotonic timings. No pixels, metadata or face coordinates
/// are logged. Release builds retain the call surface but no timing/logging work.
final class PhotoCaptureDiagnostics: @unchecked Sendable {
    static let disabled = PhotoCaptureDiagnostics()
    let captureID: UUID?

    #if DEBUG
    private let enabled: Bool
    private let effects: String
    private let lock = NSLock()
    private var source = "unselected"
    private var milestones: [String: ContinuousClock.Instant] = [:]
    #endif

    private init() {
        captureID = nil
        #if DEBUG
        enabled = false
        effects = "none"
        #endif
    }

    init(configuration: BeautyConfiguration) {
        captureID = UUID()
        #if DEBUG
        enabled = ProcessInfo.processInfo.arguments.contains("-PanPanPhotoPerformanceDiagnostics")
        var active: [String] = []
        if !configuration.isSkinBypassed { active.append("skin") }
        if configuration.enabled && !configuration.makeup.isBypassed { active.append("makeup") }
        if configuration.enabled && !configuration.filter.isBypassed { active.append("filter") }
        effects = active.isEmpty ? "none" : active.joined(separator: "+")
        #endif
        mark("capture_requested")
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
        log(stage, milliseconds: milliseconds(from: milestones["capture_requested"] ?? now, to: now))
        let intervals: [(String, String)]
        switch stage {
        case "capture_data_ready": intervals = [("capture_requested", "shutter_to_capture")]
        case "processing_start": intervals = [("processing_enqueue", "queue_wait_processing"),
                                                ("capture_data_ready", "capture_to_processing")]
        case "processing_end": intervals = [("processing_start", "processing_total")]
        case "save_start": intervals = [("save_enqueue", "queue_wait_save")]
        case "save_end": intervals = [("save_start", "save_total")]
        case "photo_saved": intervals = [("capture_requested", "shutter_to_saved")]
        case "authorization_end": intervals = [("authorization_start", "authorization")]
        case "photokit_completion_callback": intervals = [("performChanges_start", "performChanges")]
        default: intervals = []
        }
        for (start, name) in intervals {
            if let instant = milestones[start] {
                log(name, milliseconds: milliseconds(from: instant, to: now))
            }
        }
        if stage == "photo_saved" || stage == "save_failed" { logSummary(endingAt: now) }
        #endif
    }

    func backlog(_ state: PhotoProcessingState, rejected: Bool = false) {
        #if DEBUG
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        log("\(rejected ? "backlog_rejected" : "backlog") pending_total=\(state.pendingTotal) pending_processing=\(state.pendingProcessing) pending_save=\(state.pendingSave) processingQueued=\(state.processingQueued) processingActive=\(state.processingActive) saveQueued=\(state.saveQueued) saveActive=\(state.saveActive)", milliseconds: 0)
        #endif
    }

    func value(_ name: String, _ value: @autoclosure () -> Int) {
        #if DEBUG
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        log("\(name)=\(value())", milliseconds: 0)
        #endif
    }

    func input(width: Int, height: Int, pixelFormat: String) {
        #if DEBUG
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        log("input_width=\(width) input_height=\(height) input_pixel_format=\(pixelFormat)", milliseconds: 0)
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
        print("[PhotoPerformance] id=\(captureID?.uuidString ?? "disabled") source=\(source) effects=\(effects) stage=\(stage) ms=\(String(format: "%.2f", milliseconds))")
    }

    private func logSummary(endingAt end: ContinuousClock.Instant) {
        guard let requested = milestones["capture_requested"],
              let captured = milestones["capture_data_ready"],
              let processingStarted = milestones["processing_start"],
              let processingEnded = milestones["processing_end"],
              let saveStarted = milestones["save_start"] else { return }
        let effectsEnded = milestones["encoding_start"] ?? processingEnded
        let encoding = duration(from: milestones["encoding_start"], to: milestones["encoding_end"])
        print("[CameraPerformance] id=\(captureID?.uuidString ?? "disabled") source=\(source) effects=\(effects) " +
              "Capture=\(format(milliseconds(from: requested, to: captured)))ms " +
              "Processing=\(format(milliseconds(from: processingStarted, to: effectsEnded)))ms " +
              "Encoding=\(format(encoding))ms " +
              "PhotoKit=\(format(milliseconds(from: saveStarted, to: end)))ms " +
              "Total=\(format(milliseconds(from: requested, to: end)))ms")
    }

    private func duration(from start: ContinuousClock.Instant?, to end: ContinuousClock.Instant?) -> Double {
        guard let start, let end else { return 0 }
        return milliseconds(from: start, to: end)
    }

    private func format(_ milliseconds: Double) -> String {
        String(format: "%.2f", milliseconds)
    }
    #endif
}
