import Foundation

/// Owns native input and the immutable shutter snapshot until final processing ends.
struct PhotoProcessingJob: @unchecked Sendable {
    enum Source {
        case photoData(Data)
        case silentFrame(SilentFrame)
    }
    let source: Source
    let configuration: BeautyConfiguration
    let diagnostics: PhotoCaptureDiagnostics
    let captureID: UUID

    init(source: Source, configuration: BeautyConfiguration, diagnostics: PhotoCaptureDiagnostics) {
        self.source = source
        self.configuration = configuration
        self.diagnostics = diagnostics
        // Keep disabled Preview diagnostics allocation-free. Even jobs using that
        // singleton need distinct completion identities for duplicate-save guards.
        captureID = diagnostics.captureID ?? UUID()
    }
}

struct PhotoProcessingState: Equatable, Sendable {
    var processingQueued = 0
    var processingActive = 0
    var saveQueued = 0
    var saveActive = 0
    var revision: UInt64 = 0
    let maximumPendingCount: Int
    var pendingProcessing: Int { processingQueued + processingActive }
    var pendingSave: Int { saveQueued + saveActive }
    var pendingTotal: Int { pendingProcessing + pendingSave }
    var hasCapacity: Bool { pendingTotal < maximumPendingCount }
}

enum PhotoProcessingFailure: Error, Equatable, Sendable {
    case processingFailed, saveFailed
}

struct PhotoProcessingResult: @unchecked Sendable {
    let captureID: UUID
    let result: Result<CapturedPhoto, PhotoProcessingFailure>
    var photo: CapturedPhoto? { try? result.get() }
}

/// Independent serial processing and asynchronous serial saving. All admissions
/// share one bound (3), including encoded photos waiting on PhotoKit. No semaphore
/// or main-thread sync. The delivery queue orders capacity events and FIFO results.
final class PhotoProcessingQueue: @unchecked Sendable {
    typealias Process = (PhotoProcessingJob) -> CapturedPhoto?
    typealias Save = (Data, PhotoCaptureDiagnostics, @escaping (Bool) -> Void) -> Void

    private struct SaveJob {
        let captureID: UUID
        let diagnostics: PhotoCaptureDiagnostics
        // Encoded bytes + bounded display thumbnail only; never native input,
        // BeautyConfiguration, CI graphs, analysis results or masks.
        let photo: CapturedPhoto?
    }

    private let queue = DispatchQueue(label: "camera.panpan.photo-processing", qos: .utility)
    private let saveQueue = DispatchQueue(label: "camera.panpan.photo-save", qos: .utility)
    private let deliveryQueue = DispatchQueue(label: "camera.panpan.photo-delivery", qos: .utility)
    private let lock = NSLock()
    private var state: PhotoProcessingState // Protected by lock.
    private var saveJobs: [SaveJob] = [] // Save-queue confined.
    private var activeSaveID: UUID?
    private let process: Process
    private let save: Save
    private let stateChanged: (PhotoProcessingState) -> Void
    private let completion: (PhotoProcessingResult) -> Void

    init(maximumPendingCount: Int = 3, process: Process? = nil,
         makeThumbnail: @escaping (Data) -> CapturedPhoto? = CapturedPhoto.init(data:),
         save: @escaping Save = { data, diagnostics, completion in
             Task { completion(await PhotoLibrarySaver.save(data, diagnostics: diagnostics)) }
         }, stateChanged: @escaping (PhotoProcessingState) -> Void = { _ in },
         completion: @escaping (PhotoProcessingResult) -> Void) {
        precondition(maximumPendingCount > 0)
        state = PhotoProcessingState(maximumPendingCount: maximumPendingCount)
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
            job.diagnostics.value("final_data_bytes", data.count)
            job.diagnostics.mark("final_encoded")
            let photo = job.diagnostics.measure("thumbnail") { makeThumbnail(data) }
            if photo == nil { job.diagnostics.mark("thumbnail_failed") }
            return photo
        }
        self.save = save
        self.stateChanged = stateChanged
        self.completion = completion
    }

    var snapshot: PhotoProcessingState {
        lock.lock(); defer { lock.unlock() }
        return state
    }
    var pendingCount: Int { snapshot.pendingTotal }
    var canAcceptJob: Bool { snapshot.hasCapacity }

    /// CameraSession alone submits, before allowing the next native acquisition.
    /// Enqueue under lock also preserves admission order for concurrent callers.
    @discardableResult
    func enqueue(_ job: PhotoProcessingJob) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state.hasCapacity else {
            job.diagnostics.backlog(state, rejected: true)
            return false
        }
        state.processingQueued += 1
        publishStateLocked(diagnostics: job.diagnostics)
        job.diagnostics.mark("processing_enqueue")
        queue.async { [self] in processJob(job) }
        return true
    }

    private func processJob(_ job: PhotoProcessingJob) {
        dispatchPrecondition(condition: .onQueue(queue))
        changeState(diagnostics: job.diagnostics) {
            $0.processingQueued -= 1
            $0.processingActive += 1
        }
        job.diagnostics.mark("processing_start")
        let next = autoreleasepool {
            SaveJob(captureID: job.captureID, diagnostics: job.diagnostics, photo: process(job))
        }
        job.diagnostics.mark("processing_end")
        if next.photo == nil { job.diagnostics.mark("processing_failed") }
        changeState(diagnostics: job.diagnostics) {
            $0.processingActive -= 1
            $0.saveQueued += 1
        }
        job.diagnostics.mark("save_enqueue")
        // A processing failure is a FIFO terminal entry too: it cannot overtake
        // an older save. The closure retains only next, never job/source.
        saveQueue.async { [self, next] in
            saveJobs.append(next)
            startNextSaveIfNeeded()
        }
        // Returning releases source and temporary graphs before the next render.
    }

    private func startNextSaveIfNeeded() {
        dispatchPrecondition(condition: .onQueue(saveQueue))
        guard activeSaveID == nil, !saveJobs.isEmpty else { return }
        let job = saveJobs.removeFirst()
        activeSaveID = job.captureID
        changeState(diagnostics: job.diagnostics) {
            $0.saveQueued -= 1
            $0.saveActive += 1
        }
        guard let photo = job.photo else {
            finish(job, result: .failure(.processingFailed))
            return
        }
        job.diagnostics.mark("save_start")
        save(photo.data, job.diagnostics) { [self, job] saved in
            saveQueue.async { [self, job] in
                // Broken/double/late callbacks cannot decrement capacity twice,
                // publish twice, or finish a newer save.
                guard activeSaveID == job.captureID else { return }
                job.diagnostics.mark("save_end")
                job.diagnostics.mark(saved ? "photo_saved" : "save_failed")
                finish(job, result: saved ? .success(photo) : .failure(.saveFailed))
            }
        }
    }

    private func finish(_ job: SaveJob, result: Result<CapturedPhoto, PhotoProcessingFailure>) {
        dispatchPrecondition(condition: .onQueue(saveQueue))
        guard activeSaveID == job.captureID else { return }
        activeSaveID = nil
        lock.lock()
        state.saveActive -= 1
        publishStateLocked(diagnostics: job.diagnostics)
        let event = PhotoProcessingResult(captureID: job.captureID, result: result)
        deliveryQueue.async { [self] in completion(event) }
        lock.unlock()
        saveQueue.async { [self] in startNextSaveIfNeeded() }
    }

    private func changeState(diagnostics: PhotoCaptureDiagnostics, _ update: (inout PhotoProcessingState) -> Void) {
        lock.lock(); defer { lock.unlock() }
        update(&state)
        publishStateLocked(diagnostics: diagnostics)
    }

    private func publishStateLocked(diagnostics: PhotoCaptureDiagnostics) {
        state.revision += 1
        let current = state
        diagnostics.backlog(current)
        deliveryQueue.async { [self] in stateChanged(current) }
    }
}
