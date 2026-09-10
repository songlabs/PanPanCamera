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

    func testNewestConfigurationReachesPreviewGeometryForEveryControlAndResolution() throws {
        let configurations = BeautyConfigurationStore()
        let frames = BeautyPreviewFrameStore()
        let processor = BeautyImageProcessor()
        let buffer = try pixelBuffer(width: 200, height: 300)
        let controls: [(FaceTool, FaceCorrectionWarp.Kind, KeyPath<BeautyConfiguration, Double>)] = [
            (.slim, .slimLeft, \.effectiveFaceSlim), (.width, .widthLeft, \.effectiveFaceWidth),
            (.chin, .chinCenter, \.effectiveChin), (.forehead, .foreheadLeft, \.effectiveForehead),
            (.cheekbones, .cheekbonesLeft, \.effectiveCheekbones)
        ]
        for auto in [0.5, 1.0] {
            for (tool, kind, key) in controls {
                var parameters = BeautyParameters()
                parameters.setValue(0, for: SkinTool.auto)
                for other in FaceTool.allCases { parameters.setValue(0, for: other) }
                parameters.setValue(auto * 100, for: FaceTool.auto)
                parameters.setValue(100, for: tool)
                let full = try warp(kind, in: FaceCorrectionGeometry.warps(faces: [completeFace()],
                    configuration: parameters.processingConfiguration,
                    extent: CGRect(x: 0, y: 0, width: 200, height: 300)))
                for strength in [0.0, 0.25, 0.5, 0.75, 1.0, 0.0] {
                    parameters.setValue(strength * 100, for: tool)
                    configurations.replace(parameters.processingConfiguration)
                    let snapshot = configurations.snapshot()
                    XCTAssertEqual(snapshot[keyPath: key], strength, accuracy: 0.000_001)
                    for size in [CGSize(width: 200, height: 300), CGSize(width: 100, height: 150)] {
                        frames.replace(BeautyPreviewFrame(pixelBuffer: buffer, orientation: .up,
                            mirrored: false, faces: [completeFace()], configuration: snapshot))
                        let frame = try XCTUnwrap(frames.take())
                        XCTAssertEqual(frame.configuration, snapshot)
                        let result = try runOffMain {
                            try processor.previewResult(for: frame, displayRotationAngle: 0, targetSize: size)
                        }
                        if strength == 0 { XCTAssertNil(result.image) }
                        else { XCTAssertNotNil(result.image) }
                        let fittedBox = try XCTUnwrap(result.geometryDebug?.faceBox)
                        let geometry = try XCTUnwrap(result.geometryDebug?.warps)
                        if strength == 0 { XCTAssertTrue(geometry.isEmpty); continue }
                        let actual = try warp(kind, in: geometry)
                        let scale = size.width / 200
                        XCTAssertEqual(actual.visibleOffset.dx, full.visibleOffset.dx * strength * scale, accuracy: 1e-9)
                        XCTAssertEqual(actual.visibleOffset.dy, full.visibleOffset.dy * strength * scale, accuracy: 1e-9)
                        XCTAssertEqual(actual.radius, full.radius * scale, accuracy: 1e-9)
                        XCTAssertEqual(fittedBox.width, 120 * scale, accuracy: 1e-9)
                    }
                }
            }
        }
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

    func testFaceCorrectionGeometryBypassesZeroNoFaceAndIncompleteLandmarks() {
        let extent = CGRect(x: 0, y: 0, width: 200, height: 300)
        let enabledButZero = BeautyConfiguration(enabled: true, faceOverallStrength: 1)
        XCTAssertTrue(FaceCorrectionGeometry.warps(faces: [completeFace()],
            configuration: enabledButZero, extent: extent).isEmpty)

        let active = faceConfiguration()
        XCTAssertTrue(FaceCorrectionGeometry.warps(faces: [], configuration: active,
                                                    extent: extent).isEmpty)
        let incomplete = DetectedFace(
            boundingBox: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8),
            confidence: 1,
            landmarks: [.faceContour: [CGPoint(x: .nan, y: 0.3), CGPoint(x: 0.5, y: 0.1)]]
        )
        XCTAssertTrue(FaceCorrectionGeometry.warps(faces: [incomplete], configuration: active,
                                                    extent: extent).isEmpty)
    }

    func testLandmarksProduceDeterministicBoundedWarpsForFiveControls() throws {
        let extent = CGRect(x: 0, y: 0, width: 200, height: 300)
        let warps = FaceCorrectionGeometry.warps(faces: [completeFace()],
            configuration: faceConfiguration(), extent: extent)

        XCTAssertEqual(warps.count, 11)
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
        let output = try runOffMain {
            try FaceCorrectionPreviewStep().makeOutput(source: source, faces: [face],
                                                       configuration: configuration)
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
        XCTAssertEqual(zero.smallFaceWarps.count, 2)
        XCTAssertTrue(zero.smallFaceWarps.allSatisfy { $0.visibleOffset == .zero })
        XCTAssertEqual(try warp(.slimLeft, in: zero.smallFaceWarps).radius, 26.4,
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

    func testPreviewGeometryUsesPortraitAspectFillAndSingleFrontMirror() throws {
        let buffer = try pixelBuffer(width: 400, height: 300)
        let face = completeFace(box: CGRect(x: 0.25, y: 0.20, width: 0.30, height: 0.60))

        func snapshot(mirrored: Bool) throws -> FaceGeometryDebugSnapshot {
            let frame = BeautyPreviewFrame(pixelBuffer: buffer, orientation: .right,
                mirrored: mirrored, faces: [face], configuration: .disabled)
            return try XCTUnwrap(runOffMain {
                try BeautyImageProcessor().previewResult(
                    for: frame, displayRotationAngle: 90,
                    targetSize: CGSize(width: 300, height: 600)
                ).geometryDebug
            })
        }

        let back = try snapshot(mirrored: false)
        let front = try snapshot(mirrored: true)
        let backBox = try XCTUnwrap(back.faceBox)
        let frontBox = try XCTUnwrap(front.faceBox)
        XCTAssertEqual(backBox.minX, 37.5, accuracy: 0.000_001)
        XCTAssertEqual(backBox.minY, 120, accuracy: 0.000_001)
        XCTAssertEqual(backBox.width, 135, accuracy: 0.000_001)
        XCTAssertEqual(backBox.height, 360, accuracy: 0.000_001)
        XCTAssertEqual(frontBox.minX, 127.5, accuracy: 0.000_001)
        XCTAssertEqual(frontBox.minY, 120, accuracy: 0.000_001)
        XCTAssertEqual(frontBox.width, 135, accuracy: 0.000_001)
        XCTAssertEqual(frontBox.height, 360, accuracy: 0.000_001)
        XCTAssertEqual(back.contour[0].x, 48.3, accuracy: 0.000_001)
        XCTAssertEqual(back.contour[0].y, 328.8, accuracy: 0.000_001)
        XCTAssertEqual(front.contour[0].x, 251.7, accuracy: 0.000_001)
        XCTAssertEqual(front.contour[0].y, 328.8, accuracy: 0.000_001)

        let backLeft = try warp(.slimLeft, in: back.smallFaceWarps)
        let frontRight = try warp(.slimRight, in: front.smallFaceWarps)
        XCTAssertEqual(backLeft.radius, 29.7, accuracy: 0.000_001)
        XCTAssertEqual(frontRight.radius, backLeft.radius, accuracy: 0.000_001)
        XCTAssertEqual(frontRight.center.x, 300 - backLeft.center.x, accuracy: 0.000_001)
        XCTAssertEqual(frontRight.center.y, backLeft.center.y, accuracy: 0.000_001)
        XCTAssertEqual(back.captureOrientation, .right)
        XCTAssertEqual(back.displayOrientation, .right)
        XCTAssertTrue(back.faceDetected)
        XCTAssertTrue(front.faceDetected)
        XCTAssertFalse(back.mirrored)
        XCTAssertTrue(front.mirrored)
    }

    func testFaceOnlyConfigurationDoesNotDecodeOrRewritePhotoData() throws {
        let original = Data([0x50, 0x41, 0x4E, 0x50, 0x41, 0x4E])
        let output = try runOffMain {
            FinalBeautyProcessor().processPhotoData(original, configuration: BeautyConfiguration(
                enabled: true, faceOverallStrength: 1, faceSlimStrength: 1))
        }
        XCTAssertEqual(try XCTUnwrap(output), original)
    }

    func testPrimaryFaceUsesLargestThenNearestCenter() {
        let small = completeFace(box: CGRect(x: 0.05, y: 0.1, width: 0.2, height: 0.3))
        let largeEdge = completeFace(box: CGRect(x: 0.02, y: 0.1, width: 0.5, height: 0.6))
        let largeCenter = completeFace(box: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6))
        XCTAssertEqual(FaceCorrectionGeometry.primaryFace(in: [small, largeEdge])?.boundingBox,
                       largeEdge.boundingBox)
        XCTAssertEqual(FaceCorrectionGeometry.primaryFace(in: [largeEdge, largeCenter])?.boundingBox,
                       largeCenter.boundingBox)
    }

    func testMirroringReflectsGeometryOnceAndReversesHorizontalMovement() throws {
        let extent = CGRect(x: 0, y: 0, width: 200, height: 300)
        let originalFace = completeFace(box: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.8))
        let mirroredFace = try XCTUnwrap(BeautyImageProcessor.reorientedFaces(
            [originalFace], from: .up, to: .up, mirrored: true).first)
        let original = FaceCorrectionGeometry.warps(faces: [originalFace],
            configuration: faceConfiguration(), extent: extent)
        let mirrored = FaceCorrectionGeometry.warps(faces: [mirroredFace],
            configuration: faceConfiguration(), extent: extent)

        let originalLeft = try warp(.slimLeft, in: original)
        let mirroredRight = try warp(.slimRight, in: mirrored)
        XCTAssertEqual(mirroredRight.center.x, extent.width - originalLeft.center.x, accuracy: 0.000_001)
        XCTAssertEqual(mirroredRight.center.y, originalLeft.center.y, accuracy: 0.000_001)
        XCTAssertEqual(mirroredRight.visibleOffset.dx, -originalLeft.visibleOffset.dx,
                       accuracy: 0.000_001)
    }

    private func faceConfiguration() -> BeautyConfiguration {
        BeautyConfiguration(enabled: true, faceOverallStrength: 1,
            faceSlimStrength: 1, faceWidthStrength: 1, chinStrength: 1,
            foreheadStrength: 1, cheekbonesStrength: 1)
    }

    private func completeFace(
        box: CGRect = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
    ) -> DetectedFace {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: box.minX + x * box.width, y: box.minY + y * box.height)
        }
        return DetectedFace(
            boundingBox: box,
            confidence: 1,
            landmarks: [
                .faceContour: [
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
