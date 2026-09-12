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
                for makeup in MakeupTool.allCases { parameters.setValue(0, for: makeup) }
                parameters.setValue(0, for: SkinTool.auto)
                parameters.setValue(auto * 100, for: FaceTool.auto)
                for other in FaceTool.allCases where other != .auto {
                    parameters.setValue(0, for: other)
                }
                parameters.setValue(100, for: tool)
                let full = try warp(kind, in: FaceCorrectionGeometry.warps(faces: [completeFace()],
                    configuration: parameters.processingConfiguration,
                    extent: CGRect(x: 0, y: 0, width: 200, height: 300)))
                for strength in [0.0, 0.25, 0.5, 0.75, 1.0, 0.0] {
                    parameters.setValue(strength * 100, for: tool)
                    configurations.replace(parameters.processingConfiguration)
                    let snapshot = configurations.snapshot()
                    XCTAssertEqual(snapshot[keyPath: key], auto * strength, accuracy: 0.000_001)
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
        XCTAssertEqual(backLeft.radius, 43.2, accuracy: 0.000_001)
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

    func testFinalFaceCorrectionBypassesZeroAndRunsForDetectedFace() throws {
        let extent = CGRect(x: 0, y: 0, width: 200, height: 300)
        let source = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5)).cropped(to: extent)
        let zero = BeautyConfiguration(enabled: true, faceOverallStrength: 1)
        let enabled = BeautyConfiguration(enabled: true, faceOverallStrength: 1, faceSlimStrength: 1)
        try runOffMain {
            XCTAssertTrue(try BeautyImageProcessor().process(source, faces: [completeFace()],
                configuration: zero, quality: .final) === source)
            XCTAssertTrue(try BeautyImageProcessor().process(source, faces: [],
                configuration: enabled, quality: .final) === source)
            let corrected = try BeautyImageProcessor().process(source, faces: [completeFace()],
                configuration: enabled, quality: .final)
            XCTAssertFalse(corrected === source)
            XCTAssertEqual(corrected.extent, source.extent)
        }
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

    func testSlimHasSixRegionsPerSideAndContinuousFractionalStrength() throws {
        let extent = CGRect(x: 0, y: 0, width: 600, height: 800)
        var previous: [FaceCorrectionWarp]?
        for value in [0.0001, 0.01, 0.49, 0.495, 0.50, 0.505, 0.51, 1.0] {
            let warps = FaceCorrectionGeometry.warps(faces: [completeFace()],
                configuration: BeautyConfiguration(enabled: true, faceOverallStrength: 1,
                                                    faceSlimStrength: value), extent: extent)
            XCTAssertEqual(warps.filter { $0.kind == .slimLeft }.count, 6)
            XCTAssertEqual(warps.filter { $0.kind == .slimRight }.count, 6)
            for (index, warp) in warps.enumerated() {
                XCTAssertGreaterThan(abs(warp.visibleOffset.dx), 0)
                XCTAssertEqual(warp.visibleOffset.dy, 0)
                XCTAssertLessThanOrEqual(abs(warp.visibleOffset.dx), 360 * 0.12 * value)
                if let previous {
                    XCTAssertEqual(warp.center, previous[index].center)
                    XCTAssertEqual(warp.radius, previous[index].radius)
                }
            }
            XCTAssertEqual(warps[0].visibleOffset.dx, 360 * 0.12 * value, accuracy: 1e-9)
            XCTAssertLessThan(abs(warps[10].visibleOffset.dx), abs(warps[0].visibleOffset.dx))
            previous = warps
        }
    }

    func testSlimDoesNotSwitchNearestLandmarkForOnePixelPerturbations() throws {
        let extent = CGRect(x: 0, y: 0, width: 600, height: 800)
        let box = CGRect(x: 0, y: 0, width: 1, height: 1)
        let a = CGPoint(x: 0.08, y: 0.39), b = CGPoint(x: 0.22, y: 0.30)
        let config = BeautyConfiguration(enabled: true, faceOverallStrength: 1, faceSlimStrength: 1)
        var last: [FaceCorrectionWarp]?
        for pixels in [0.0, 1.0, 2.0] {
            let face = DetectedFace(boundingBox: box, confidence: 1, landmarks: [.faceContour: [
                CGPoint(x: a.x - pixels / 600, y: a.y + pixels / 800), b,
                CGPoint(x: 0.5, y: 0.03), CGPoint(x: 0.78, y: 0.30), CGPoint(x: 0.92, y: 0.39)
            ]])
            let warps = FaceCorrectionGeometry.warps(faces: [face], configuration: config, extent: extent)
            XCTAssertEqual(warps.count, 12)
            if let last {
                for (old, current) in zip(last, warps) {
                    XCTAssertLessThan(hypot(old.center.x - current.center.x,
                                            old.center.y - current.center.y), 3)
                }
            }
            last = warps
        }
        // Old closest(target: .12, .30) switches A -> B after the 1px perturbation.
        XCTAssertGreaterThan(hypot((a.x - b.x) * 600, (a.y - b.y) * 800), 100)
    }

    func testPreviewSlimSmoothingSuppressesJitterAndFollowsMotionAtFrameCadence() throws {
        var smoother = PreviewSlimLandmarkSmoother()
        let base = completeFace()
        XCTAssertEqual(smoother.update(faces: [base], observationTime: 1, time: 1), [base])
        let stable = try XCTUnwrap(smoother.update(faces: [base], observationTime: 1, time: 1.03).first)
        XCTAssertEqual(stable.landmarks[.faceContour], base.landmarks[.faceContour])
        let jitter = shiftedFace(base, dx: 1.0 / 600)
        let damped = try XCTUnwrap(smoother.update(faces: [jitter], observationTime: 1.06, time: 1.06).first)
        let shift = damped.boundingBox.minX - base.boundingBox.minX
        XCTAssertGreaterThan(shift, 0)
        XCTAssertLessThan(shift, 1.0 / 600 * 0.6)

        let moved = shiftedFace(base, dx: base.boundingBox.width * 0.08)
        let first = try XCTUnwrap(smoother.update(faces: [moved], observationTime: 1.09, time: 1.09).first)
        XCTAssertGreaterThan(first.boundingBox.minX - base.boundingBox.minX,
                             (moved.boundingBox.minX - base.boundingBox.minX) * 0.7)
        // Same Vision observation continues to converge on subsequent camera frames.
        let second = try XCTUnwrap(smoother.update(faces: [moved], observationTime: 1.09, time: 1.12).first)
        XCTAssertGreaterThan(second.boundingBox.minX, first.boundingBox.minX)
        XCTAssertLessThan(second.boundingBox.minX, moved.boundingBox.minX)
    }

    func testPreviewSlimSmoothingResetsOnLossAmbiguityStaleTopologyAndNewGeneration() throws {
        let face = completeFace(), next = shiftedFace(completeFace(), dx: 0.02)
        var smoother = PreviewSlimLandmarkSmoother()
        _ = smoother.update(faces: [face], observationTime: 1, time: 1)
        XCTAssertTrue(smoother.update(faces: [], observationTime: 1.03, time: 1.03).isEmpty)
        XCTAssertEqual(smoother.update(faces: [next], observationTime: 1.06, time: 1.06), [next])
        XCTAssertEqual(smoother.update(faces: [face, next], observationTime: 1.09, time: 1.09), [face, next])
        XCTAssertEqual(smoother.update(faces: [face], observationTime: 1.12, time: 1.12), [face])
        XCTAssertTrue(smoother.update(faces: [face], observationTime: 1.12, time: 1.7).isEmpty)
        XCTAssertEqual(smoother.update(faces: [next], observationTime: 1.73, time: 1.73), [next])
        let far = shiftedFace(face, dx: 0.15)
        XCTAssertEqual(smoother.update(faces: [far], observationTime: 1.76, time: 1.76), [far])
        let fewer = DetectedFace(boundingBox: far.boundingBox, confidence: 1,
            landmarks: [.faceContour: Array(try XCTUnwrap(far.landmarks[.faceContour]).dropLast())])
        XCTAssertEqual(smoother.update(faces: [fewer], observationTime: 1.79, time: 1.79), [fewer])
        let weak = DetectedFace(boundingBox: face.boundingBox, confidence: 0.2, landmarks: face.landmarks)
        XCTAssertTrue(smoother.update(faces: [weak], observationTime: 1.82, time: 1.82).isEmpty)
        XCTAssertEqual(smoother.update(faces: [next], observationTime: 1.85, time: 1.85), [next])
        // A new camera/orientation/activation processor owns a fresh smoother.
        smoother = PreviewSlimLandmarkSmoother()
        XCTAssertEqual(smoother.update(faces: [face], observationTime: 1.88, time: 1.88), [face])
    }

    func testPreviewConsumesSmoothedContourOnlyForSlim() throws {
        let raw = completeFace(), smoothed = shiftedFace(completeFace(), dx: 0.01)
        let buffer = try pixelBuffer(width: 200, height: 300)
        let config = faceConfiguration()
        let snapshot = try XCTUnwrap(runOffMain {
            try BeautyImageProcessor().previewResult(for: BeautyPreviewFrame(pixelBuffer: buffer,
                orientation: .up, mirrored: false, faces: [raw], configuration: config,
                slimFaces: [smoothed]), displayRotationAngle: 0,
                targetSize: CGSize(width: 200, height: 300)).geometryDebug
        })
        let extent = CGRect(x: 0, y: 0, width: 200, height: 300)
        let expected = FaceCorrectionGeometry.warps(faces: [smoothed], configuration: config, extent: extent)
        let original = FaceCorrectionGeometry.warps(faces: [raw], configuration: config, extent: extent)
        for (actual, desired) in zip(snapshot.warps, original) where !actual.isSlim {
            XCTAssertEqual(actual.center.x, desired.center.x, accuracy: 1e-9)
            XCTAssertEqual(actual.center.y, desired.center.y, accuracy: 1e-9)
        }
        for (actual, desired) in zip(snapshot.smallFaceWarps, expected.filter(\.isSlim)) {
            XCTAssertEqual(actual.center.x, desired.center.x, accuracy: 1e-9)
            XCTAssertEqual(actual.center.y, desired.center.y, accuracy: 1e-9)
        }
    }

    func testMakeupSmootherDampsFeatureJitterIndependentlyAndContinuesBetweenDetections() throws {
        let base = makeupTrackingFace()
        var features = base.landmarks
        let lipShift: CGFloat = 1.0 / 600
        features[.outerLips] = features[.outerLips]?.map { CGPoint(x: $0.x + lipShift, y: $0.y) }
        features[.innerLips] = features[.innerLips]?.map { CGPoint(x: $0.x + lipShift, y: $0.y) }
        let jitter = DetectedFace(boundingBox: base.boundingBox, confidence: 1, landmarks: features)
        var smoother = PreviewSlimLandmarkSmoother(includesAllFeatures: true)
        XCTAssertEqual(smoother.update(faces: [base], observationTime: 1, time: 1), [base])
        let first = try XCTUnwrap(smoother.update(faces: [jitter], observationTime: 1.03, time: 1.03).first)
        let originalLip = try XCTUnwrap(base.landmarks[.outerLips]?.first)
        let firstLip = try XCTUnwrap(first.landmarks[.outerLips]?.first)
        XCTAssertGreaterThan(firstLip.x - originalLip.x, 0)
        XCTAssertLessThan(firstLip.x - originalLip.x, lipShift * 0.6)
        XCTAssertEqual(first.boundingBox, base.boundingBox)
        for feature: FacialLandmarkRegion in [.faceContour, .leftEye, .rightEye, .leftEyebrow, .rightEyebrow] {
            XCTAssertEqual(first.landmarks[feature], base.landmarks[feature],
                "Lip motion must not move another feature's landmarks")
        }
        let next = try XCTUnwrap(smoother.update(faces: [jitter], observationTime: 1.03, time: 1.06).first)
        let nextLip = try XCTUnwrap(next.landmarks[.outerLips]?.first)
        XCTAssertGreaterThan(nextLip.x, firstLip.x)
        XCTAssertLessThan(nextLip.x, originalLip.x + lipShift)
        XCTAssertEqual(Set(next.landmarks.keys), Set(base.landmarks.keys))
    }

    func testMakeupSmootherResetsFeatureTopologyLossAndStaleHistory() throws {
        let base = makeupTrackingFace()
        let moved = shiftedFace(base, dx: 0.01)
        var smoother = PreviewSlimLandmarkSmoother(includesAllFeatures: true)
        _ = smoother.update(faces: [base], observationTime: 1, time: 1)
        _ = smoother.update(faces: [moved], observationTime: 1.03, time: 1.03)
        var features = moved.landmarks
        features[.outerLips] = Array(try XCTUnwrap(features[.outerLips]).dropLast())
        let changed = DetectedFace(boundingBox: moved.boundingBox, confidence: 1, landmarks: features)
        XCTAssertEqual(smoother.update(faces: [changed], observationTime: 1.06, time: 1.06), [changed],
            "A topology change must not pair old landmarks with different new points")
        features.removeValue(forKey: .innerLips)
        let missing = DetectedFace(boundingBox: moved.boundingBox, confidence: 1, landmarks: features)
        XCTAssertEqual(smoother.update(faces: [missing], observationTime: 1.09, time: 1.09), [missing])
        XCTAssertEqual(smoother.update(faces: [moved], observationTime: 1.12, time: 1.12), [moved],
            "A returning feature must not acquire stale geometry")
        XCTAssertTrue(smoother.update(faces: [moved], observationTime: 1.12, time: 1.70).isEmpty)
        XCTAssertEqual(smoother.update(faces: [base], observationTime: 1.73, time: 1.73), [base])
        XCTAssertTrue(smoother.update(faces: [], observationTime: 1.76, time: 1.76).isEmpty)
        XCTAssertEqual(smoother.update(faces: [moved], observationTime: 1.79, time: 1.79), [moved])
    }

    func testDefaultSlimSmootherStillIgnoresMakeupFeatureMotionAndTopology() throws {
        let base = makeupTrackingFace()
        let moved = shiftedFace(base, dx: 1.0 / 600)
        var changedFeatures = moved.landmarks
        changedFeatures[.outerLips] = [CGPoint(x: 0.9, y: 0.9)]
        changedFeatures.removeValue(forKey: .innerLips)
        let changed = DetectedFace(boundingBox: moved.boundingBox, confidence: 1, landmarks: changedFeatures)
        var ordinary = PreviewSlimLandmarkSmoother()
        var changedMakeup = PreviewSlimLandmarkSmoother()
        _ = ordinary.update(faces: [base], observationTime: 1, time: 1)
        _ = changedMakeup.update(faces: [base], observationTime: 1, time: 1)
        let expected = try XCTUnwrap(ordinary.update(faces: [moved], observationTime: 1.03, time: 1.03).first)
        let actual = try XCTUnwrap(changedMakeup.update(faces: [changed], observationTime: 1.03, time: 1.03).first)
        XCTAssertEqual(actual, expected,
            "The existing contour smoother must ignore new makeup tracking features")
        XCTAssertEqual(Set(actual.landmarks.keys), Set([FacialLandmarkRegion.faceContour]))
        XCTAssertGreaterThan(actual.boundingBox.minX, base.boundingBox.minX)
        XCTAssertLessThan(actual.boundingBox.minX, moved.boundingBox.minX,
            "Makeup topology must not reset the existing Slim history")
    }

    private func makeupTrackingFace() -> DetectedFace {
        let base = completeFace()
        var features = base.landmarks
        features[.leftEye] = [CGPoint(x: 0.34, y: 0.61), CGPoint(x: 0.37, y: 0.63), CGPoint(x: 0.4, y: 0.61)]
        features[.rightEye] = [CGPoint(x: 0.6, y: 0.61), CGPoint(x: 0.63, y: 0.63), CGPoint(x: 0.66, y: 0.61)]
        features[.outerLips] = [CGPoint(x: 0.42, y: 0.34), CGPoint(x: 0.5, y: 0.37),
                                CGPoint(x: 0.58, y: 0.34), CGPoint(x: 0.5, y: 0.31)]
        features[.innerLips] = [CGPoint(x: 0.45, y: 0.34), CGPoint(x: 0.5, y: 0.35), CGPoint(x: 0.55, y: 0.34)]
        return DetectedFace(boundingBox: base.boundingBox, confidence: base.confidence, landmarks: features)
    }

    private func shiftedFace(_ face: DetectedFace, dx: CGFloat) -> DetectedFace {
        DetectedFace(boundingBox: face.boundingBox.offsetBy(dx: dx, dy: 0), confidence: face.confidence,
                     landmarks: face.landmarks.mapValues { $0.map { CGPoint(x: $0.x + dx, y: $0.y) } })
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
