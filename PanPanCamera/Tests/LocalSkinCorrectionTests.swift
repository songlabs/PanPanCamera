#if DEBUG
import CoreImage
import CoreVideo
import XCTest
@testable import PanPanCamera

/// Real CI pixel readback on Apple, with synthetic fixtures only. Task.detached
/// keeps graph construction AND rendering off main, including synchronous XCTest.
final class LocalSkinCorrectionTests: XCTestCase {
    private let extent = CGRect(x: 0, y: 0, width: 256, height: 256)

    func testZeroStrengthAndMissingLandmarksBypassWithoutChangingPixels() async throws {
        try await Task.detached { [self] in
            let face = try landmarks()
            let source = try fixture(face)
            let white = solid(1, 1, 1)
            let point = blemishPoint(face)
            for strength in [0.0, -1, .nan, .infinity] {
                let blemish = try BlemishAttenuationStep().makeOutput(source: source,
                    regions: [face.region], landmarks: [face], effectiveSkinMask: white,
                    strength: strength, quality: .final)
                let dark = try DarkCircleCorrectionStep().makeOutput(source: source,
                    regions: [face.region], landmarks: [face], effectiveSkinMask: white,
                    strength: strength, quality: .preview)
                XCTAssertNil(blemish)
                XCTAssertNil(dark)
                XCTAssertEqual(pixel(blemish ?? source, point), pixel(source, point))
                XCTAssertEqual(pixel(dark ?? source, point), pixel(source, point))
            }
            let empty = FacialLandmarks(region: face.region, features: [:])
            XCTAssertNil(try DarkCircleCorrectionStep().makeOutput(source: source,
                regions: [face.region], landmarks: [empty], effectiveSkinMask: white,
                strength: 1, quality: .final))
            XCTAssertNil(try BlemishAttenuationStep().makeOutput(source: source,
                regions: [face.region], landmarks: [empty], effectiveSkinMask: white,
                strength: 1, quality: .preview))
        }.value
    }

    func testBlemishPixelsIncreaseMonotonicallyAndPreserveOutsideAndExtent() async throws {
        try await Task.detached { [self] in
            let face = try landmarks()
            let source = try fixture(face)
            let point = blemishPoint(face)
            let permitted = CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)
            let mask = solid(1, 1, 1).cropped(to: permitted).composited(over: solid(0, 0, 0))
            for quality in [BeautyProcessingQuality.preview, .final] {
                var previous: Float = 0
                for strength in [0.25, 0.5, 0.75, 1.0] {
                    let output = try XCTUnwrap(BlemishAttenuationStep().makeOutput(source: source,
                        regions: [face.region], landmarks: [face], effectiveSkinMask: mask,
                        strength: strength, quality: quality))
                    let change = difference(source, output, point)
                    XCTAssertGreaterThan(change, previous + 0.000_01)
                    previous = change
                    XCTAssertEqual(output.extent, source.extent)
                    XCTAssertLessThan(change, 0.076)
                    for x in stride(from: 4, through: 252, by: 48) {
                        for y in stride(from: 4, through: 252, by: 48) {
                            let p = CGPoint(x: x, y: y)
                            if !permitted.contains(p) {
                                XCTAssertLessThan(difference(source, output, p), 0.000_1)
                            }
                        }
                    }
                    for p in [CGPoint(x: permitted.minX - 2, y: point.y),
                              CGPoint(x: permitted.maxX + 2, y: point.y),
                              CGPoint(x: point.x, y: permitted.minY - 2),
                              CGPoint(x: point.x, y: permitted.maxY + 2)] {
                        XCTAssertLessThan(difference(source, output, p), 0.000_1)
                    }
                }
            }
            let shifted = source.transformed(by: CGAffineTransform(translationX: 19, y: -23))
            let shiftedMask = mask.transformed(by: CGAffineTransform(translationX: 19, y: -23))
            let output = try XCTUnwrap(BlemishAttenuationStep().makeOutput(source: shifted,
                regions: [face.region], landmarks: [face], effectiveSkinMask: shiftedMask,
                strength: 1, quality: .final))
            XCTAssertEqual(output.extent, shifted.extent)
            XCTAssertGreaterThan(difference(shifted, output,
                CGPoint(x: point.x + 19, y: point.y - 23)), 0.000_1)
        }.value
    }

    func testBlemishProtectsEveryFeatureAndLeavesNeutralDarkMarksAndFlatSkin() async throws {
        try await Task.detached { [self] in
            let face = try landmarks()
            var source = try fixture(face)
            var protected: [CGPoint] = []
            for feature in FacialLandmarkRegion.protectedFeatures {
                let points = face.imagePoints(for: feature, in: extent)
                let p = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                                y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
                protected.append(p)
                source = try spot(over: source, at: p, color: CIColor(red: 0.78, green: 0.43, blue: 0.38))
            }
            let mask = try XCTUnwrap(LocalSkinCorrection.effectiveMask(source: source,
                regions: [face.region], landmarks: [face]))
            let output = try XCTUnwrap(BlemishAttenuationStep().makeOutput(source: source,
                regions: [face.region], landmarks: [face], effectiveSkinMask: mask,
                strength: 1, quality: .final))
            for p in protected {
                XCTAssertLessThan(pixel(mask, p)[0], 0.002)
                XCTAssertLessThan(difference(source, output, p), 0.000_5)
            }
            XCTAssertGreaterThan(difference(source, output, blemishPoint(face)), 0.000_1)
            for mark in [CIColor(red: 0.12, green: 0.12, blue: 0.12),
                         CIColor(red: 0.32, green: 0.23, blue: 0.18)] {
                let input = try spot(over: solid(0.65, 0.50, 0.43), at: blemishPoint(face), color: mark)
                let result = try XCTUnwrap(BlemishAttenuationStep().makeOutput(source: input,
                    regions: [face.region], landmarks: [face], effectiveSkinMask: solid(1, 1, 1),
                    strength: 1, quality: .final))
                XCTAssertLessThan(difference(input, result, blemishPoint(face)), 0.000_1)
            }
            let flat = solid(0.65, 0.50, 0.43)
            let unchanged = try XCTUnwrap(BlemishAttenuationStep().makeOutput(source: flat,
                regions: [face.region], landmarks: [face], effectiveSkinMask: solid(1, 1, 1),
                strength: 1, quality: .final))
            XCTAssertLessThan(difference(flat, unchanged, blemishPoint(face)), 0.000_1)
        }.value
    }

    func testUnderEyeMaskFollowsTiltAndStaysBelowBothEyePolygonsAtNonzeroOrigin() async throws {
        try await Task.detached { [self] in
            let shiftedExtent = extent.offsetBy(dx: 17, dy: -29)
            for tilt: CGFloat in [-0.30, 0, 0.30] {
                let face = try landmarks(tilt: tilt)
                for eye in [FacialLandmarkRegion.leftEye, .rightEye] {
                    let area = try XCTUnwrap(UnderEyeRegion.make(landmarks: face, eye: eye, in: shiftedExtent))
                    let mask = try area.makeMask(in: shiftedExtent)
                    let points = face.imagePoints(for: eye, in: shiftedExtent)
                    XCTAssertEqual(area.along.dy / area.along.dx, tilt, accuracy: 0.000_001)
                    for p in points {
                        let projection = (p.x - area.center.x) * area.down.dx + (p.y - area.center.y) * area.down.dy
                        XCTAssertLessThan(projection, -area.radiusY)
                        XCTAssertLessThan(pixel(mask, p)[0], 0.002)
                    }
                    let eyeCenter = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                                            y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
                    XCTAssertLessThan(pixel(mask, eyeCenter)[0], 0.000_1)
                    XCTAssertGreaterThan(pixel(mask, area.center)[0], 0.9)
                    let farCheek = CGPoint(x: area.center.x + area.down.dx * area.width,
                                          y: area.center.y + area.down.dy * area.width)
                    XCTAssertLessThan(pixel(mask, farCheek)[0], 0.000_1)
                    XCTAssertEqual(mask.extent, shiftedExtent)
                }
            }
        }.value
    }

    func testSingleEyeDarkCirclePixelsAreBoundedMonotonicAndLocal() async throws {
        try await Task.detached { [self] in
            let complete = try landmarks()
            let source = try fixture(complete)
            for missing in [FacialLandmarkRegion.leftEye, .rightEye] {
                let present: FacialLandmarkRegion = missing == .leftEye ? .rightEye : .leftEye
                let face = FacialLandmarks(region: complete.region, features: complete.features.filter { $0.key != missing })
                let area = try XCTUnwrap(UnderEyeRegion.make(landmarks: face, eye: present, in: extent))
                let absentArea = try XCTUnwrap(UnderEyeRegion.make(landmarks: complete, eye: missing, in: extent))
                for quality in [BeautyProcessingQuality.preview, .final] {
                    var previous: Float = 0
                    for strength in [0.25, 0.5, 0.75, 1.0] {
                        let output = try XCTUnwrap(DarkCircleCorrectionStep().makeOutput(source: source,
                            regions: [face.region], landmarks: [face], effectiveSkinMask: solid(1, 1, 1),
                            strength: strength, quality: quality))
                        let lift = luminance(pixel(output, area.center)) - luminance(pixel(source, area.center))
                        XCTAssertGreaterThan(lift, previous + 0.000_01)
                        XCTAssertLessThanOrEqual(lift, 0.056)
                        previous = lift
                        XCTAssertLessThan(difference(source, output, absentArea.center), 0.000_1)
                        for p in [CGPoint(x: 1, y: 1), blemishPoint(face)] + face.imagePoints(for: present, in: extent) {
                            XCTAssertLessThan(difference(source, output, p), 0.000_1)
                        }
                        XCTAssertEqual(output.extent, source.extent)
                    }
                }
            }
            let flat = solid(0.65, 0.50, 0.43)
            let unchanged = try XCTUnwrap(DarkCircleCorrectionStep().makeOutput(source: flat,
                regions: [complete.region], landmarks: [complete], effectiveSkinMask: solid(1, 1, 1),
                strength: 1, quality: .final))
            let area = try XCTUnwrap(UnderEyeRegion.make(landmarks: complete, eye: .leftEye, in: extent))
            XCTAssertLessThan(difference(flat, unchanged, area.center), 0.000_1)
            let translated = source.transformed(by: CGAffineTransform(translationX: -13, y: 21))
            let output = try XCTUnwrap(DarkCircleCorrectionStep().makeOutput(source: translated,
                regions: [complete.region], landmarks: [complete],
                effectiveSkinMask: solid(1, 1, 1).transformed(by: CGAffineTransform(translationX: -13, y: 21)),
                strength: 1, quality: .final))
            XCTAssertEqual(output.extent, translated.extent)
            XCTAssertGreaterThan(difference(translated, output,
                CGPoint(x: area.center.x - 13, y: area.center.y + 21)), 0.000_1)
        }.value
    }

    func testBothControlsReachProductionPreviewAndFinalQualityWithActualPixelChanges() async throws {
        try await Task.detached { [self] in
            let face = try landmarks()
            let buffer = try pixelBuffer(try fixture(face))
            let source = CIImage(cvPixelBuffer: buffer)
            let detected = DetectedFace(boundingBox: face.region.boundingBox, confidence: 1,
                landmarks: face.features.mapValues { points in points.map {
                    CGPoint(x: face.region.boundingBox.minX + $0.x * face.region.boundingBox.width,
                            y: face.region.boundingBox.minY + $0.y * face.region.boundingBox.height)
                } })
            let darkPoint = try XCTUnwrap(UnderEyeRegion.make(landmarks: face, eye: .leftEye, in: extent)).center
            let store = BeautyConfigurationStore()
            for (tool, p) in [(SkinTool.blemish, blemishPoint(face)), (.darkCircles, darkPoint)] {
                var values = BeautyParameters()
                values.setValue(0, for: FaceTool.auto)
                values.setValue(100, for: SkinTool.auto)
                for child in SkinTool.allCases where child != .auto { values.setValue(0, for: child) }
                var previousPreview: Float = 0, previousFinal: Float = 0
                for strength in [0.0, 50, 100] {
                    values.setValue(strength, for: tool)
                    store.replace(values.processingConfiguration)
                    let snapshot = store.snapshot()
                    let frame = BeautyPreviewFrame(pixelBuffer: buffer, orientation: .up, mirrored: false,
                        faces: [detected], configuration: snapshot)
                    let preview = try BeautyImageProcessor().previewImage(for: frame,
                        displayRotationAngle: 0, targetSize: extent.size)
                    let final = try BeautyImageProcessor().process(source, faces: [detected],
                        configuration: snapshot, quality: .final)
                    if strength == 0 {
                        XCTAssertNil(preview)
                        XCTAssertTrue(final === source)
                        XCTAssertEqual(pixel(final, p), pixel(source, p))
                    } else {
                        let rendered = try XCTUnwrap(preview)
                        let previewChange = difference(source, rendered, p)
                        let finalChange = difference(source, final, p)
                        XCTAssertGreaterThan(previewChange, previousPreview + 0.000_01, tool.rawValue)
                        XCTAssertGreaterThan(finalChange, previousFinal + 0.000_01, tool.rawValue)
                        previousPreview = previewChange
                        previousFinal = finalChange
                        XCTAssertEqual(rendered.extent, extent)
                        XCTAssertEqual(final.extent, extent)
                        XCTAssertLessThan(difference(source, rendered, CGPoint(x: 1, y: 1)), 0.000_1)
                        XCTAssertLessThan(difference(source, final, CGPoint(x: 1, y: 1)), 0.000_1)
                    }
                }
            }
        }.value
    }

    private func landmarks(tilt: CGFloat = 0) throws -> FacialLandmarks {
        let region = try FaceRegion(boundingBox: CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.9))
        func eye(_ x: CGFloat) -> [CGPoint] {
            [CGPoint(x: x - 0.11, y: 0.70), CGPoint(x: x, y: 0.735),
             CGPoint(x: x + 0.11, y: 0.70), CGPoint(x: x, y: 0.665)].map {
                CGPoint(x: $0.x, y: $0.y + ($0.x - x) * tilt * 0.8 / 0.9)
            }
        }
        return FacialLandmarks(region: region, features: [
            .leftEye: eye(0.30), .rightEye: eye(0.70),
            .leftEyebrow: [CGPoint(x: 0.20, y: 0.82), CGPoint(x: 0.40, y: 0.82)],
            .rightEyebrow: [CGPoint(x: 0.60, y: 0.82), CGPoint(x: 0.80, y: 0.82)],
            .nose: [CGPoint(x: 0.48, y: 0.56), CGPoint(x: 0.50, y: 0.49), CGPoint(x: 0.52, y: 0.56)],
            .outerLips: [CGPoint(x: 0.40, y: 0.28), CGPoint(x: 0.50, y: 0.31),
                         CGPoint(x: 0.60, y: 0.28), CGPoint(x: 0.50, y: 0.25)]
        ])
    }

    private func blemishPoint(_ face: FacialLandmarks) -> CGPoint {
        let rect = face.region.imageRect(in: extent)
        return CGPoint(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.42)
    }

    private func fixture(_ face: FacialLandmarks) throws -> CIImage {
        var source = try spot(over: solid(0.65, 0.50, 0.43), at: blemishPoint(face),
                              color: CIColor(red: 0.78, green: 0.43, blue: 0.38))
        for eye in [FacialLandmarkRegion.leftEye, .rightEye] {
            let area = try XCTUnwrap(UnderEyeRegion.make(landmarks: face, eye: eye, in: extent))
            source = try CoreImageRendering.blend(solid(0.44, 0.32, 0.32), over: source,
                                                 mask: area.makeMask(in: extent))
        }
        return source
    }

    private func spot(over source: CIImage, at point: CGPoint, color: CIColor) throws -> CIImage {
        let mask = try CoreImageRendering.filter("CIRadialGradient", parameters: [
            "inputCenter": CIVector(cgPoint: point), "inputRadius0": 2.5, "inputRadius1": 4.5,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0)
        ], in: extent)
        return try CoreImageRendering.blend(CIImage(color: color).cropped(to: extent), over: source, mask: mask)
    }

    private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: extent)
    }

    private func pixel(_ image: CIImage, _ point: CGPoint) -> [Float] {
        CoreImageRendering.diagnosticRGBA(image, at: point)
    }

    private func difference(_ a: CIImage, _ b: CIImage, _ point: CGPoint) -> Float {
        zip(pixel(a, point), pixel(b, point)).map { pair in abs(pair.0 - pair.1) }.max() ?? 0
    }

    private func luminance(_ pixel: [Float]) -> Float {
        pixel[0] * 0.2126 + pixel[1] * 0.7152 + pixel[2] * 0.0722
    }

    private func pixelBuffer(_ image: CIImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, Int(extent.width), Int(extent.height),
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        CIContext().render(image, to: result, bounds: extent, colorSpace: colorSpace)
        return result
    }
}
#endif
