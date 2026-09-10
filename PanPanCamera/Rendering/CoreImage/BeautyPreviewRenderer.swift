import CoreImage
import Foundation
import Metal
import QuartzCore

/// Latest-only Core Image renderer. Camera frame delivery already drops late frames;
/// this additional one-command-buffer gate prevents display work from queuing.
final class BeautyPreviewRenderer: @unchecked Sendable {
    private let processor = BeautyImageProcessor()
    private let queue = DispatchQueue(label: "camera.panpan.beauty-preview", qos: .userInteractive)
    private let commandQueue: MTLCommandQueue
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let lock = NSLock()
    private var inFlight = false
    private var generation = 0

    init?(device: MTLDevice) {
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue
    }

    func requestFrame(from store: BeautyPreviewFrameStore, layer: CAMetalLayer,
                      rotationAngle: CGFloat, targetSize: CGSize,
                      completion: @escaping (Bool) -> Void) {
        guard let token = begin() else { return }
        guard let frame = store.take() else { cancelReservation(); return }
        queue.async { [self] in
            autoreleasepool {
                do {
                    guard let image = try processor.previewImage(for: frame,
                        displayRotationAngle: rotationAngle, targetSize: targetSize),
                          let drawable = layer.nextDrawable(),
                          let commandBuffer = commandQueue.makeCommandBuffer() else {
                        finish(token: token, success: false, completion: completion)
                        return
                    }
                    CoreImageRendering.render(image, to: drawable.texture,
                                              commandBuffer: commandBuffer,
                                              bounds: CGRect(origin: .zero, size: targetSize),
                                              colorSpace: colorSpace)
                    commandBuffer.present(drawable)
                    commandBuffer.addCompletedHandler { [weak self] buffer in
                        self?.finish(token: token, success: buffer.status == .completed,
                                     completion: completion)
                    }
                    commandBuffer.commit()
                } catch {
                    finish(token: token, success: false, completion: completion)
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

    private func finish(token: Int, success: Bool, completion: @escaping (Bool) -> Void) {
        lock.lock()
        inFlight = false
        let current = token == generation
        lock.unlock()
        guard current else { return }
        DispatchQueue.main.async { completion(success) }
    }
}
