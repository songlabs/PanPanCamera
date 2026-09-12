"""Run the real FIFO/registry on the host, substituting only Apple image/save APIs.

This does not execute AVCapturePhotoOutput, ImageIO, Vision, Core Image, UIKit or
PhotoKit. The Apple XCTest suite exercises the actual image pipeline separately.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'PanPanCamera'

PROBE = r'''
import Foundation

struct SilentFrame { let data: Data }
struct CapturedPhoto: Sendable {
    let data: Data
    init?(data: Data) { self.data = data }
}
final class FinalBeautyProcessor {
    func processPhotoData(_ data: Data, configuration: BeautyConfiguration,
                          diagnostics: PhotoCaptureDiagnostics) -> Data? { data }
    func processSilentFrame(_ frame: SilentFrame, configuration: BeautyConfiguration,
                            diagnostics: PhotoCaptureDiagnostics) -> Data? { frame.data }
}
enum PhotoLibrarySaver { static func save(_ data: Data, diagnostics: PhotoCaptureDiagnostics) async -> Bool { true } }
#if !canImport(ObjectiveC)
func autoreleasepool<T>(_ body: () -> T) -> T { body() }
#endif

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    @discardableResult
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
final class DelegateToken {}

@main struct CoordinationProbe {
    static func wait(_ signal: DispatchSemaphore) {
        precondition(signal.wait(timeout: .now() + 5) == .success, "Worker did not advance")
    }
    static func main() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let saveStarted = DispatchSemaphore(value: 0)
        let secondProcessed = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let seen = Box<[BeautyConfiguration]>([])
        let saveCount = Box(0)
        let results = Box<[Bool]>([])
        let saveReply = Box<((Bool) -> Void)?>(nil)
        let first = BeautyConfiguration(enabled: true, overallStrength: 0.8, smoothingStrength: 0.3)
        let second = BeautyConfiguration(enabled: true, filter: .init(preset: .warm, intensity: 0.7))
        let trace = PhotoCaptureDiagnostics(configuration: first)
        trace.selectSource("photo_output")
        trace.mark("capture_data_ready")
        let worker = PhotoProcessingQueue(maximumPendingCount: 2, process: { job in
            precondition(!Thread.isMainThread)
            let count = seen.withValue { $0.append(job.configuration); return $0.count }
            if count == 1 { started.signal(); wait(release) }
            if count == 2 { secondProcessed.signal() }
            if case let .photoData(data) = job.source { return CapturedPhoto(data: data) }
            return nil
        }, save: { _, _, completion in
            precondition(!Thread.isMainThread)
            let count = saveCount.withValue { $0 += 1; return $0 }
            if count == 1 {
                saveReply.withValue { $0 = completion }
                saveStarted.signal()
            } else { completion(true) }
        }, completion: { outcome in
            results.withValue { $0.append(outcome.photo != nil) }
            done.signal()
        })
        var registry = PhotoCaptureRegistry<DelegateToken>()
        var delegate: DelegateToken? = DelegateToken()
        weak var retained = delegate
        registry.register(delegate!, id: 1)
        delegate = nil
        precondition(retained != nil)
        precondition(registry.finish(id: 1))
        precondition(retained == nil && registry.activeID == nil)
        precondition(worker.enqueue(PhotoProcessingJob(source: .photoData(Data([1])),
            configuration: first, diagnostics: trace)))
        wait(started)
        registry.register(DelegateToken(), id: 2)
        precondition(registry.activeID == 2 && worker.pendingCount == 1)
        precondition(worker.enqueue(PhotoProcessingJob(source: .photoData(Data([2])),
            configuration: second, diagnostics: PhotoCaptureDiagnostics(configuration: second))))
        precondition(!worker.enqueue(PhotoProcessingJob(source: .photoData(Data([3])),
            configuration: .disabled, diagnostics: trace)))
        precondition(worker.pendingCount == 2 && !worker.canAcceptJob)
        release.signal()
        wait(saveStarted)
        wait(secondProcessed)
        precondition(seen.withValue { $0 } == [first, second])
        precondition(saveCount.withValue { $0 } == 1)
        precondition(results.withValue { $0.isEmpty })
        precondition(worker.pendingCount == 2)
        saveReply.withValue { $0 }?(false)
        wait(done); wait(done)
        precondition(seen.withValue { $0 } == [first, second])
        precondition(results.withValue { $0 } == [false, true])
        precondition(worker.pendingCount == 0 && worker.canAcceptJob)
        precondition(registry.activeID == 2)
        precondition(registry.invalidateActive())
        registry.register(DelegateToken(), id: 3)
        precondition(!registry.finish(id: 2) && registry.activeID == 3)
        precondition(registry.finish(id: 3))

        let failed = DispatchSemaphore(value: 0)
        let failureWorker = PhotoProcessingQueue(process: { _ in nil }, save: { _, _, _ in
            preconditionFailure("A failed image must never be saved")
        }, completion: { outcome in precondition(outcome.photo == nil); failed.signal() })
        for _ in 0..<2 {
            precondition(failureWorker.enqueue(PhotoProcessingJob(source: .photoData(Data()),
                configuration: first, diagnostics: PhotoCaptureDiagnostics(configuration: first))))
        }
        wait(failed); wait(failed)
        precondition(failureWorker.pendingCount == 0 && failureWorker.canAcceptJob)
        print("PASS host FIFO, snapshots, slot independence, bounded backlog, delayed save failure, processing failure")
    }
}
'''


class PhotoProcessingCoordinationTests(unittest.TestCase):
    def test_production_coordination_runs_in_debug_and_release_on_host(self):
        swiftc = shutil.which('swiftc')
        if not swiftc:
            self.skipTest('Swift compiler unavailable; host coordination not executed')
        sources = [*sorted((APP / 'Domain').glob('*.swift')),
                   APP / 'Camera/Capture/PhotoCaptureRegistry.swift',
                   APP / 'Camera/Capture/PhotoCaptureDiagnostics.swift',
                   APP / 'Camera/Capture/PhotoProcessingQueue.swift']
        with tempfile.TemporaryDirectory(prefix='panpan-coordination-') as directory:
            directory = Path(directory)
            probe = directory / 'Probe.swift'
            binary = directory / ('probe.exe' if os.name == 'nt' else 'probe')
            # A parser-only Windows Swift install may lack the C runtime SDK.
            # Check the independent prerequisite before compiling product code.
            probe.write_text('import Foundation\nprint(ProcessInfo.processInfo.systemUptime)\n', encoding='utf-8')
            prerequisite = subprocess.run([swiftc, str(probe), '-o', str(binary)],
                                          capture_output=True, text=True, timeout=60)
            if prerequisite.returncode != 0:
                self.skipTest('Host Foundation SDK/linker unavailable; coordination runtime not executed')
            probe.write_text(PROBE, encoding='utf-8')
            for debug in (False, True):
                with self.subTest(debug=debug):
                    compile_result = subprocess.run(
                        [swiftc, '-swift-version', '5', '-parse-as-library',
                         *(['-D', 'DEBUG'] if debug else []), *map(str, sources),
                         str(probe), '-o', str(binary)], capture_output=True, text=True, timeout=60)
                    self.assertEqual(compile_result.returncode, 0, compile_result.stdout + compile_result.stderr)
                    run = subprocess.run([str(binary), '-PanPanPhotoPerformanceDiagnostics'],
                                         capture_output=True, text=True, timeout=20)
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                    self.assertIn('PASS host FIFO', run.stdout)
                    if debug:
                        self.assertIn('stage=backlog_rejected pending_total=2', run.stdout)
                        self.assertIn('stage=save_failed', run.stdout)
                        self.assertIn('stage=processing_failed', run.stdout)
                    else:
                        self.assertNotIn('[PhotoPerformance]', run.stdout)


if __name__ == '__main__':
    unittest.main()
