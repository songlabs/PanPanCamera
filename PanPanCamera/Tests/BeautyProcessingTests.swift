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

    func testSkinProductAmplitudesAreTwicePreviousBaselineWithoutChangingStrength() {
        XCTAssertEqual(BeautyEffectAmplitude.brightening, 0.03 * 2, accuracy: 0.000_001)
        XCTAssertEqual(1 - BeautyEffectAmplitude.previewSmoothingDetailRetention,
                       (1 - 0.94) * 2, accuracy: 0.000_001)
        XCTAssertEqual(1 - BeautyEffectAmplitude.finalSmoothingDetailRetention,
                       (1 - 0.90) * 2, accuracy: 0.000_001)
        XCTAssertEqual(BeautyEffectAmplitude.previewToneConsistency,
                       0.20 * 2, accuracy: 0.000_001)
        XCTAssertEqual(BeautyEffectAmplitude.finalToneConsistency,
                       0.25 * 2, accuracy: 0.000_001)
    }

    func testFaceProductAmplitudesAreTwicePreviousBaseline() {
        XCTAssertEqual(FaceCorrectionGeometry.maximumSlimDisplacementRatio,
                       0.060 * 2, accuracy: 0.000_001)
        XCTAssertEqual(FaceCorrectionGeometry.maximumWidthDisplacementRatio,
                       0.022 * 2, accuracy: 0.000_001)
        XCTAssertEqual(FaceCorrectionGeometry.maximumChinSideDisplacementRatio,
                       0.010 * 2, accuracy: 0.000_001)
        XCTAssertEqual(FaceCorrectionGeometry.maximumChinCenterDisplacementRatio,
                       0.018 * 2, accuracy: 0.000_001)
        XCTAssertEqual(FaceCorrectionGeometry.maximumForeheadDisplacementRatio,
                       0.012 * 2, accuracy: 0.000_001)
        XCTAssertEqual(FaceCorrectionGeometry.maximumCheekbonesDisplacementRatio,
                       0.015 * 2, accuracy: 0.000_001)
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
        let processor = BeautyTestHarness()
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

    #if DEBUG
    #endif

    func testPreviewGraphUsesRequestedAspectFillExtentWithResidualRotationAndMirror() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48,
            kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let face = AnalyzedFace(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
                                confidence: 1, landmarks: [:])
        let configuration = BeautyConfiguration(enabled: true, overallStrength: 1,
            smoothingStrength: 0, brighteningStrength: 1, toneStrength: 0,
            filter: FilterConfiguration(preset: .warm, intensity: 0.5))
        let frame = BeautyPreviewFrame(pixelBuffer: try XCTUnwrap(buffer), orientation: .right,
            mirrored: true, faces: [face], configuration: configuration)
        let output = try runOffMain {
            try BeautyTestHarness().previewImage(for: frame, displayRotationAngle: 95,
                                                    targetSize: CGSize(width: 30, height: 60))
        }
        XCTAssertEqual(try XCTUnwrap(output).extent, CGRect(x: 0, y: 0, width: 30, height: 60))
    }

    func testFaceCorrectionGeometryBypassesZeroNoFaceAndIncompleteLandmarks() {
        let extent = CGRect(x: 0, y: 0, width: 200, height: 300)
        let enabledButZero = BeautyConfiguration(enabled: true, faceOverallStrength: 1)
        XCTAssertTrue(FaceCorrectionGeometry.warps(faces: [completeFace()],
            configuration: enabledButZero, extent: extent).isEmpty)

        let active = faceConfiguration()
        XCTAssertTrue(FaceCorrectionGeometry.warps(faces: [], configuration: active,
                                                    extent: extent).isEmpty)
        let incomplete = AnalyzedFace(
            boundingBox: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8),
            confidence: 1,
            landmarks: [.jawline: [CGPoint(x: .nan, y: 0.3), CGPoint(x: 0.5, y: 0.1)]]
        )
        XCTAssertTrue(FaceCorrectionGeometry.warps(faces: [incomplete], configuration: active,
                                                    extent: extent).isEmpty)
    }

    func testLandmarksProduceDeterministicBoundedWarpsForFiveControls() throws {
        let extent = CGRect(x: 0, y: 0, width: 200, height: 300)
        let warps = FaceCorrectionGeometry.warps(faces: [completeFace()],
            configuration: faceConfiguration(), extent: extent)

        XCTAssertEqual(warps.count, 21)
        XCTAssertTrue(warps.allSatisfy { extent.insetBy(dx: -1, dy: -1).contains($0.center) })
        XCTAssertTrue(warps.allSatisfy { $0.radius >= 1 && $0.radius < 40 })
        XCTAssertGreaterThan(try warp(.slimLeft, in: warps).visibleOffset.dx, 0)
        XCTAssertLessThan(try warp(.slimRight, in: warps).visibleOffset.dx, 0)
        XCTAssertGreaterThan(try warp(.widthLeft, in: warps).visibleOffset.dx, 0)
        XCTAssertLessThan(try warp(.widthRight, in: warps).visibleOffset.dx, 0)
        XCTAssertGreaterThan(try warp(.chinCenter, in: warps).visibleOffset.dy, 0)
        XCTAssertLessThan(try warp(.foreheadLeft, in: warps).visibleOffset.dy, 0)
        XCTAssertGreaterThan(try warp(.cheekbonesLeft, in: warps).visibleOffset.dx, 0)
        XCTAssertLessThan(try warp(.cheekbonesRight, in: warps).visibleOffset.dx, 0)
    }

    func testFaceCorrectionPreviewBuildsLocalDisplacementGraphOffMain() throws {
        let extent = CGRect(x: 0, y: 0, width: 200, height: 300)
        let source = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5)).cropped(to: extent)
        let face = completeFace()
        let configuration = faceConfiguration()
        let output = try runOffMain(timeout: 15) {
            try FaceCorrectionPreviewStep().makeOutput(source: source, warps:
                FaceCorrectionGeometry.warps(faces: [face], configuration: configuration, extent: extent))
        }
        XCTAssertEqual(try XCTUnwrap(output).extent, extent)
    }

    func testSlimJawDisplacementIsZeroThenContinuousAndInwardThroughHundred() throws {
        let extent = CGRect(x: 0, y: 0, width: 200, height: 300)
        var parameters = BeautyParameters()
        parameters.setValue(50, for: FaceTool.auto)
        for tool in [FaceTool.width, .chin, .forehead, .cheekbones] {
            parameters.setValue(0, for: tool)
        }

        var magnitudes: [CGFloat] = []
        for uiValue in [0.0, 25.0, 50.0, 75.0, 100.0] {
            parameters.setValue(uiValue, for: FaceTool.slim)
            let warps = FaceCorrectionGeometry.warps(faces: [completeFace()],
                configuration: parameters.processingConfiguration, extent: extent)
            if uiValue == 0 {
                XCTAssertTrue(warps.isEmpty)
                magnitudes.append(0)
                continue
            }
            let left = try warp(.slimLeft, in: warps)
            let right = try warp(.slimRight, in: warps)
            XCTAssertGreaterThan(left.visibleOffset.dx, 0)
            XCTAssertLessThan(right.visibleOffset.dx, 0)
            XCTAssertEqual(left.visibleOffset.dx, -right.visibleOffset.dx, accuracy: 0.000_001)
            magnitudes.append(abs(left.visibleOffset.dx))
        }

        for (actual, expected) in zip(magnitudes, [0, 1.8, 3.6, 5.4, 7.2]) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
        for pair in zip(magnitudes, magnitudes.dropFirst()) {
            XCTAssertLessThan(pair.0, pair.1)
        }
    }

    func testGeometryDiagnosticsShareExactProductionSlimWarpsAtZeroAndHundred() throws {
        let extent = CGRect(x: 0, y: 0, width: 200, height: 300)
        var parameters = BeautyParameters()
        parameters.setValue(50, for: FaceTool.auto)
        for tool in [FaceTool.slim, .width, .chin, .forehead, .cheekbones] {
            parameters.setValue(0, for: tool)
        }

        let zero = FaceCorrectionGeometry.result(faces: [completeFace()],
            configuration: parameters.processingConfiguration, extent: extent)
        XCTAssertTrue(zero.warps.isEmpty)
        XCTAssertEqual(zero.smallFaceWarps.count, 12)
        XCTAssertTrue(zero.smallFaceWarps.allSatisfy { $0.visibleOffset == .zero })
        XCTAssertEqual(try warp(.slimLeft, in: zero.smallFaceWarps).radius, 38.4,
                       accuracy: 0.000_001)

        parameters.setValue(100, for: FaceTool.slim)
        let full = FaceCorrectionGeometry.result(faces: [completeFace()],
            configuration: parameters.processingConfiguration, extent: extent)
        XCTAssertEqual(full.smallFaceWarps, full.warps)
        XCTAssertEqual(try warp(.slimLeft, in: full.smallFaceWarps).visibleOffset.dx, 7.2,
                       accuracy: 0.000_001)
        XCTAssertEqual(try warp(.slimRight, in: full.smallFaceWarps).visibleOffset.dx, -7.2,
                       accuracy: 0.000_001)
    }

    private func faceConfiguration() -> BeautyConfiguration {
        BeautyConfiguration(enabled: true, faceOverallStrength: 1,
            faceSlimStrength: 1, faceWidthStrength: 1, chinStrength: 1,
            foreheadStrength: 1, cheekbonesStrength: 1)
    }

    private func completeFace(
        box: CGRect = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
    ) -> AnalyzedFace {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: box.minX + x * box.width, y: box.minY + y * box.height)
        }
        return AnalyzedFace(
            boundingBox: box,
            confidence: 1,
            landmarks: [
                .jawline: [
                    point(0.08, 0.58), point(0.10, 0.42), point(0.18, 0.24),
                    point(0.34, 0.08), point(0.50, 0.03), point(0.66, 0.08),
                    point(0.82, 0.24), point(0.90, 0.42), point(0.92, 0.58)
                ],
                .leftEyebrow: [point(0.24, 0.70), point(0.36, 0.72)],
                .rightEyebrow: [point(0.64, 0.72), point(0.76, 0.70)]
            ]
        )
    }

    private func warp(_ kind: FaceCorrectionWarp.Kind,
                      in warps: [FaceCorrectionWarp]) throws -> FaceCorrectionWarp {
        try XCTUnwrap(warps.first { $0.kind == kind })
    }

    private func pixelBuffer(width: Int = 2, height: Int = 2) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func runOffMain<Value>(timeout: TimeInterval = 5,
                                   _ operation: @escaping () throws -> Value) throws -> Value {
        let completed = expectation(description: "Beauty processing completed off-main")
        let result = LockedResult<Value>()
        processingQueue.async {
            defer { completed.fulfill() }
            XCTAssertFalse(Thread.isMainThread)
            result.store(Result { try operation() })
        }
        wait(for: [completed], timeout: timeout)
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
