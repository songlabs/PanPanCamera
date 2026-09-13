import CoreImage
import Foundation
import Metal
import QuartzCore

/// Latest-only Core Image renderer. Camera frame delivery already drops late frames;
/// this additional one-command-buffer gate prevents display work from queuing.
final class BeautyPreviewRenderer: @unchecked Sendable {
    private let processor = BeautyPreviewProcessor()
    private let queue = DispatchQueue(label: "camera.panpan.beauty-preview", qos: .userInteractive)
    private let commandQueue: MTLCommandQueue
    // Accessed only on queue; context creation stays off the main thread.
    private lazy var metalRenderer = CoreImageRendering.MetalRenderer(device: commandQueue.device)
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let lock = NSLock()
    private var inFlight = false
    private var generation = 0
    #if DEBUG
    private var diagnosticSuccess: Bool?
    private var diagnosticTime: TimeInterval = -.infinity
    #endif

    init?(device: MTLDevice) {
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue
    }

    func requestFrame(from store: BeautyPreviewFrameStore, layer: CAMetalLayer,
                      rotationAngle: CGFloat, targetSize: CGSize,
                      completion: @escaping (Bool, FaceAnalysisDebugSnapshot?) -> Void) {
        guard let token = begin() else { return }
        guard let frame = store.take() else { cancelReservation(); return }
        queue.async { [self] in
            autoreleasepool {
                do {
                    let result = try processor.previewResult(for: frame,
                        displayRotationAngle: rotationAngle, targetSize: targetSize)
                    let analysisDebug = result.analysisDebug
                    guard let image = result.image else {
                        finish(token: token, success: false, analysisDebug: analysisDebug,
                               completion: completion)
                        return
                    }
                    guard let drawable = layer.nextDrawable(),
                          let commandBuffer = commandQueue.makeCommandBuffer() else {
                        finish(token: token, success: false, analysisDebug: analysisDebug,
                               completion: completion)
                        return
                    }
                    // startTask must succeed before this drawable can be presented. A completed
                    // empty command buffer alone does not prove that Core Image wrote the frame.
                    try metalRenderer.render(image, to: drawable.texture,
                                             commandBuffer: commandBuffer,
                                             bounds: CGRect(origin: .zero, size: targetSize),
                                             colorSpace: colorSpace)
                    commandBuffer.present(drawable)
                    commandBuffer.addCompletedHandler { [weak self] buffer in
                        self?.finish(token: token, success: buffer.status == .completed,
                                     analysisDebug: analysisDebug,
                                     completion: completion)
                    }
                    commandBuffer.commit()
                } catch {
                    finish(token: token, success: false, analysisDebug: nil,
                           completion: completion)
                }
            }
        }
    }

    func invalidate() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    private func begin() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !inFlight else { return nil }
        inFlight = true
        return generation
    }

    private func cancelReservation() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }

    private func finish(token: Int, success: Bool,
                        analysisDebug: FaceAnalysisDebugSnapshot?,
                        completion: @escaping (Bool, FaceAnalysisDebugSnapshot?) -> Void) {
        lock.lock()
        inFlight = false
        let current = token == generation
        #if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        let report = current && diagnosticSuccess != success &&
            now - diagnosticTime >= 1 &&
            ProcessInfo.processInfo.arguments.contains("-PanPanBeautyStrengthDiagnostics")
        if report { diagnosticSuccess = success; diagnosticTime = now }
        #endif
        lock.unlock()
        guard current else { return }
        #if DEBUG
        if report { print("BeautyStrength Preview render completed: success=\(success)") }
        #endif
        DispatchQueue.main.async { completion(success, analysisDebug) }
    }
}
