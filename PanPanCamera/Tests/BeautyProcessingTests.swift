import CoreImage
import Foundation
import XCTest
@testable import PanPanCamera

final class BeautyProcessingTests: XCTestCase {
    private let processingQueue = DispatchQueue(
        label: "test.panpan.beauty-processing",
        qos: .userInitiated
    )

    private final class LockedResult<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<Value, Error>?

        func store(_ result: Result<Value, Error>) {
            lock.lock()
            defer { lock.unlock() }
            stored = result
        }

        var value: Result<Value, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    func testPreviewFrameStoreKeepsOnlyNewestFrameAndConsumesOnce() throws {
        let store = BeautyPreviewFrameStore()
        let first = try pixelBuffer()
        let second = try pixelBuffer()
        store.replace(BeautyPreviewFrame(pixelBuffer: first, orientation: .up, mirrored: false,
            faces: [], configuration: .disabled))
        store.replace(BeautyPreviewFrame(pixelBuffer: second, orientation: .right, mirrored: true,
            faces: [], configuration: .disabled))
        let actual = try XCTUnwrap(store.take())
        XCTAssertTrue(actual.pixelBuffer === second)
        XCTAssertEqual(actual.orientation, .right)
        XCTAssertTrue(actual.mirrored)
        XCTAssertNil(store.take())
    }

    func testDisabledAndNoFaceProcessingAreExactGraphBypasses() throws {
        let source = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let processor = BeautyImageProcessor()
        let disabled = try runOffMain {
            try processor.process(source, faces: [], configuration: .disabled, quality: .preview)
        }
        XCTAssertTrue(disabled === source)
        let enabled = BeautyConfiguration(enabled: true, overallStrength: 1,
                                          smoothingStrength: 1)
        let noFace = try runOffMain {
            try processor.process(source, faces: [], configuration: enabled, quality: .final)
        }
        XCTAssertTrue(noFace === source)
    }

    func testLocalBrighteningChangesFaceCenterButPreservesFarCorner() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let source = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: extent)
        let face = DetectedFace(boundingBox: CGRect(x: 0.25, y: 0.15, width: 0.5, height: 0.7),
                                confidence: 1, landmarks: [:])
        let configuration = BeautyConfiguration(enabled: true, overallStrength: 1,
            smoothingStrength: 0, brighteningStrength: 1, toneStrength: 0)
        let output = try runOffMain {
            try BeautyImageProcessor().process(source, faces: [face],
                                               configuration: configuration, quality: .final)
        }
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let center = try pixel(output, at: CGPoint(x: 32, y: 32), context: context)
        let corner = try pixel(output, at: CGPoint(x: 1, y: 1), context: context)
        XCTAssertGreaterThan(center, 0.4)
        XCTAssertEqual(corner, 0.4, accuracy: 0.01)
    }

    func testPreviewGraphUsesRequestedAspectFillExtentWithResidualRotationAndMirror() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48,
            kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let face = DetectedFace(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
                                confidence: 1, landmarks: [:])
        let configuration = BeautyConfiguration(enabled: true, overallStrength: 1,
            smoothingStrength: 0, brighteningStrength: 1, toneStrength: 0)
        let frame = BeautyPreviewFrame(pixelBuffer: try XCTUnwrap(buffer), orientation: .right,
            mirrored: true, faces: [face], configuration: configuration)
        let output = try runOffMain {
            try BeautyImageProcessor().previewImage(for: frame, displayRotationAngle: 95,
                                                    targetSize: CGSize(width: 30, height: 60))
        }
        XCTAssertEqual(try XCTUnwrap(output).extent, CGRect(x: 0, y: 0, width: 30, height: 60))
    }

    private func pixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2,
            kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func runOffMain<Value>(_ operation: @escaping () throws -> Value) throws -> Value {
        let completed = expectation(description: "Beauty processing completed off-main")
        let result = LockedResult<Value>()
        processingQueue.async {
            defer { completed.fulfill() }
            XCTAssertFalse(Thread.isMainThread)
            result.store(Result { try operation() })
        }
        wait(for: [completed], timeout: 5)
        return try XCTUnwrap(result.value, "Beauty processing did not complete").get()
    }

    private func pixel(_ image: CIImage, at point: CGPoint, context: CIContext) throws -> Double {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: 4,
                           bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: nil)
        }
        return Double(bytes[0]) / 255
    }
}
