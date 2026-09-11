import Foundation

/// Owns native input and the shutter's immutable parameters after the delegate
/// has been released. Silent frames keep their original orientation and metadata.
struct PhotoProcessingJob: @unchecked Sendable {
    enum Source {
        case photoData(Data)
        case silentFrame(SilentFrame)
    }

    let source: Source
    let configuration: BeautyConfiguration
    let diagnostics: PhotoCaptureDiagnostics
}

/// One final render/encode/save at a time, independent of the camera session queue.
/// Admission is bounded including the job awaiting PhotoKit; no worker waits on a
/// semaphore, and a failed job advances the same FIFO as a successful one.
final class PhotoProcessingQueue: @unchecked Sendable {
    typealias Process = (PhotoProcessingJob) -> CapturedPhoto?
    typealias Save = (Data, @escaping (Bool) -> Void) -> Void

    private let queue = DispatchQueue(label: "camera.panpan.photo-processing", qos: .utility)
    private let lock = NSLock()
    private let maximumPendingCount: Int
    private var pending = 0 // Includes queued, processing and saving; protected by lock.
    private var jobs: [PhotoProcessingJob] = [] // Worker-confined.
    private var isProcessing = false
    private let process: Process
    private let save: Save
    private let completion: (CapturedPhoto?) -> Void

    init(maximumPendingCount: Int = 3, process: Process? = nil,
         save: @escaping Save = { data, completion in
             Task { completion(await PhotoLibrarySaver.save(data)) }
         }, completion: @escaping (CapturedPhoto?) -> Void) {
        precondition(maximumPendingCount > 0)
        self.maximumPendingCount = maximumPendingCount
        let processor = FinalBeautyProcessor()
        self.process = process ?? { job in
            let data: Data?
            switch job.source {
            case let .photoData(input):
                data = processor.processPhotoData(input, configuration: job.configuration,
                                                   diagnostics: job.diagnostics)
            case let .silentFrame(frame):
                data = processor.processSilentFrame(frame, configuration: job.configuration,
                                                     diagnostics: job.diagnostics)
            }
            guard let data else { return nil }
            job.diagnostics.mark("final_encoded")
            return job.diagnostics.measure("thumbnail_decode") { CapturedPhoto(data: data) }
        }
        self.save = save
        self.completion = completion
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    var canAcceptJob: Bool { pendingCount < maximumPendingCount }

    /// CameraSession is the only submitter. It checks capacity before acquiring
    /// input and submits at final callback, before admitting another capture.
    @discardableResult
    func enqueue(_ job: PhotoProcessingJob) -> Bool {
        lock.lock()
        guard pending < maximumPendingCount else {
            let count = pending
            lock.unlock()
            job.diagnostics.backlog(count, rejected: true)
            return false
        }
        pending += 1
        let count = pending
        lock.unlock()
        job.diagnostics.backlog(count)
        job.diagnostics.mark("job_enqueued")
        queue.async { [self] in
            jobs.append(job)
            startNextIfNeeded()
        }
        return true
    }

    private func startNextIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isProcessing, !jobs.isEmpty else { return }
        isProcessing = true
        let job = jobs.removeFirst()
        let diagnostics = job.diagnostics
        diagnostics.mark("final_beauty_start")
        let photo = diagnostics.measure("final_processing") { autoreleasepool { process(job) } }
        guard let photo else {
            diagnostics.mark("processing_failed")
            finish(nil, diagnostics: diagnostics)
            return
        }
        diagnostics.mark("photokit_start")
        // Retain only the encoded photo while saving, not the source pixel buffer.
        save(photo.data) { [self] saved in
            queue.async { [self] in
                diagnostics.mark(saved ? "photokit_complete" : "photokit_failed")
                if saved { diagnostics.mark("photo_saved") }
                finish(saved ? photo : nil, diagnostics: diagnostics)
            }
        }
    }

    private func finish(_ photo: CapturedPhoto?, diagnostics: PhotoCaptureDiagnostics) {
        dispatchPrecondition(condition: .onQueue(queue))
        lock.lock()
        pending -= 1
        let count = pending
        lock.unlock()
        diagnostics.backlog(count)
        completion(photo)
        isProcessing = false
        // Allow the current stack and its source image to be released first.
        queue.async { [self] in startNextIfNeeded() }
    }
}
