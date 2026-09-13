import AVFoundation
import CoreImage
import ImageIO
import XCTest
@testable import PanPanCamera

final class AdaptiveBeautyPipelineTests: XCTestCase {
    func testPreviewDebugObservesOneExistingMaskAndLeavesPixelsUnchanged() async throws {
        try await Task.detached {
            let source = Self.source(in: CGRect(x: 0, y: 0, width: 128, height: 128))
            let face = SkinTestFace.make()
            let analysis = AnalysisFixture.result([face], size: source.extent.size)
            let calls = PhotoProcessingTestValue(0)
            let observed = PhotoProcessingTestValue(0)
            let processor = BeautyProcessor(makeSkinMask: { image, faces, quality in
                calls.update { $0 += 1 }
                return try AdaptiveSkinMaskGenerator().makeMask(source: image, faces: faces, quality: quality)
            })
            let configuration = BeautyConfiguration(enabled: true, overallStrength: 1, brighteningStrength: 0.6,
                faceOverallStrength: 1, faceWidthStrength: 0.4)
            let plain = try processor.process(source, analysis: analysis, configuration: configuration, quality: .preview)
            let debug = try processor.process(source, analysis: analysis, configuration: configuration, quality: .preview,
                previewDebug: { mask, geometry, _ in
                    observed.update { $0 += 1 }
                    XCTAssertNotNil(mask)
                    XCTAssertEqual(geometry.warps, FaceCorrectionGeometry.warps(faces: [face],
                        configuration: configuration, extent: source.extent))
                })
            XCTAssertEqual(calls.value, 2, "Exactly one mask build per preview, including Debug ON")
            XCTAssertEqual(observed.value, 1)
            XCTAssertEqual(try ColorPipelineFixture.pixels(debug), try ColorPipelineFixture.pixels(plain))
            _ = try processor.process(source, analysis: analysis, configuration: configuration, quality: .final,
                previewDebug: { _, _, _ in XCTFail("Final must not publish Preview diagnostics") })
            let bypassed = try processor.process(source, analysis: analysis, configuration: .disabled, quality: .preview,
                previewDebug: { _, _, _ in XCTFail("Debug must not enable a bypassed pipeline") })
            XCTAssertTrue(bypassed === source)
            XCTAssertEqual(calls.value, 3)
        }.value
    }

    func testPreviewDebugUsesPortraitMirrorAndAspectFillGeometryWithNoEffects() async throws {
        try await Task.detached {
            let buffer = try ColorPipelineFixture.buffer() // sensor-native 192 x 256
            let face = SkinTestFace.make()
            let point = try XCTUnwrap(face.landmarks[.leftEye]?.first)
            let analysis = AnalysisFixture.result([face], size: CGSize(width: 192, height: 256))
            let processor = BeautyPreviewProcessor()
            let target = CGSize(width: 180, height: 320)
            for orientation in FaceImageOrientation.allCases {
                for mirror in [false, true] {
                    let frame = BeautyPreviewFrame(pixelBuffer: buffer, orientation: .up, mirrored: mirror,
                        analysis: analysis, configuration: .disabled)
                    let off = try processor.previewResult(for: frame, displayRotationAngle: CGFloat(orientation.rawValue),
                        targetSize: target, includeDebug: false)
                    XCTAssertNil(off.analysisDebug)
                    XCTAssertNil(off.image)
                    let on = try processor.previewResult(for: frame, displayRotationAngle: CGFloat(orientation.rawValue),
                        targetSize: target, includeDebug: true)
                    let snapshot = try XCTUnwrap(on.analysisDebug)
                    let rotatedSize = orientation == .right || orientation == .left
                        ? CGSize(width: 256, height: 192) : CGSize(width: 192, height: 256)
                    let p = FaceAnalysisCoordinates.reorientation(from: .up, sourceMirrored: false,
                        to: orientation, mirrored: mirror).point(point)
                    let scale = max(target.width / rotatedSize.width, target.height / rotatedSize.height)
                    let expected = CGPoint(x: (p.x * rotatedSize.width * scale + (target.width - rotatedSize.width * scale) / 2) / target.width,
                        y: (p.y * rotatedSize.height * scale + (target.height - rotatedSize.height * scale) / 2) / target.height)
                    XCTAssertTrue(snapshot.points.contains { abs($0.x - expected.x) < 1e-8 && abs($0.y - expected.y) < 1e-8 })
                    XCTAssertEqual(snapshot.mirrored, mirror)
                    XCTAssertEqual(snapshot.extent.size, target)
                    XCTAssertNil(snapshot.skinImage, "No extra skin processing when skin effects are OFF")
                    XCTAssertNil(on.image, "Guides must stay outside the Beauty image")
                }
            }
        }.value
    }

    private static func sample(_ image: CIImage, _ point: CGPoint) -> Float {
        ProcessingTestPixels.floats(image, bounds: CGRect(x: floor(image.extent.minX + point.x * image.extent.width),
            y: floor(image.extent.minY + point.y * image.extent.height), width: 1, height: 1))[0]
    }

    private static func source(in extent: CGRect) -> CIImage {
        let skin = CIImage(color: CIColor(red: 0.60, green: 0.43, blue: 0.34)).cropped(to: extent)
        let hair = CGRect(x: extent.minX, y: extent.minY + extent.height * 0.84,
                          width: extent.width, height: extent.height * 0.16)
        let background = CGRect(x: extent.minX, y: extent.minY, width: extent.width * 0.19, height: extent.height)
        return CIImage(color: CIColor(red: 0.035, green: 0.03, blue: 0.025)).cropped(to: hair)
            .composited(over: CIImage(color: .blue).cropped(to: background).composited(over: skin))
            .cropped(to: extent)
    }

    func testActualColorCubeIncludesForeheadAndProtectsHairEyesBrowsAndLips() async throws {
        try await Task.detached {
            let extent = CGRect(x: 11, y: -7, width: 256, height: 256)
            let source = Self.source(in: extent)
            let face = SkinTestFace.make()
            for quality in [BeautyProcessingQuality.preview, .final] {
                let mask = try XCTUnwrap(AdaptiveSkinMaskGenerator().makeMask(source: source, faces: [face], quality: quality)).mask
                let forehead = CGPoint(x: 0.40, y: 0.77), cheek = CGPoint(x: 0.32, y: 0.46)
                XCTAssertGreaterThan(Self.sample(mask, forehead), 0.55)
                XCTAssertGreaterThan(Self.sample(mask, cheek), 0.55)
                for point in [CGPoint(x: 0.40, y: 0.88), CGPoint(x: 0.18, y: 0.75),
                              CGPoint(x: 0.35, y: 0.57), CGPoint(x: 0.65, y: 0.57),
                              CGPoint(x: 0.35, y: 0.645), CGPoint(x: 0.65, y: 0.645), CGPoint(x: 0.5, y: 0.33)] {
                    XCTAssertLessThan(Self.sample(mask, point), 0.04, "Protected \(point)")
                }
                let output = try BeautyProcessor().process(source,
                    analysis: AnalysisFixture.result([face], size: extent.size),
                    configuration: BeautyConfiguration(enabled: true, overallStrength: 1, brighteningStrength: 1), quality: quality)
                XCTAssertGreaterThan(Self.sample(output, forehead), Self.sample(source, forehead) + 0.015)
                XCTAssertEqual(Self.sample(output, CGPoint(x: 0.4, y: 0.88)), Self.sample(source, CGPoint(x: 0.4, y: 0.88)), accuracy: 0.002)
            }
        }.value
    }

    func testMaskFeathersInwardAndROIAloneCannotEnableSkin() async throws {
        try await Task.detached {
            let extent = CGRect(x: 0, y: 0, width: 256, height: 256)
            let face = SkinTestFace.make()
            let mask = try XCTUnwrap(AdaptiveSkinMaskGenerator().makeMask(source: Self.source(in: extent), faces: [face], quality: .final)).mask
            // Feature protection has a full plateau plus a continuous outer ramp.
            let values = (0..<25).map { Self.sample(mask, CGPoint(x: 0.35, y: 0.57 + CGFloat($0) / 512)) }
            XCTAssertTrue(values.contains { $0 > 0.05 && $0 < 0.50 })
            let neutral = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: extent)
            XCTAssertNil(try AdaptiveSkinMaskGenerator().makeMask(source: neutral, faces: [face], quality: .final))
        }.value
    }

    func testMaskAndLandmarksStayAlignedAcrossQuarterTurnsAndFrontMirror() async throws {
        try await Task.detached {
            let source = Self.source(in: CGRect(x: 0, y: 0, width: 256, height: 256))
            for orientation in FaceImageOrientation.allCases {
                for mirror in [false, true] {
                    let exif = SilentFrameOrientation.exif(captureOrientation: orientation, mirrored: mirror)
                    let image = FaceImageNormalization.normalize(source, exif: exif)
                    let transform = FaceAnalysisCoordinates.reorientation(from: .up, sourceMirrored: false,
                        to: orientation, mirrored: mirror)
                    let faces = FaceAnalysisCoordinates.map([SkinTestFace.make()], by: transform)
                    let mask = try XCTUnwrap(AdaptiveSkinMaskGenerator().makeMask(source: image, faces: faces, quality: .final)).mask
                    XCTAssertGreaterThan(Self.sample(mask, transform.point(CGPoint(x: 0.40, y: 0.77))), 0.40)
                    XCTAssertLessThan(Self.sample(mask, transform.point(CGPoint(x: 0.40, y: 0.88))), 0.04)
                    XCTAssertLessThan(Self.sample(mask, transform.point(CGPoint(x: 0.35, y: 0.57))), 0.04)
                }
            }
        }.value
    }

    func testMultipleFacesKeepIndependentComplexionsAndGlobalFeatureProtection() async throws {
        try await Task.detached {
            let extent = CGRect(x: 0, y: 0, width: 512, height: 256)
            let left = FaceAnalysisCoordinates.map([SkinTestFace.make()], by: FaceAnalysisTransform(a: 0.48))[0]
            let right = FaceAnalysisCoordinates.map([SkinTestFace.make()], by: FaceAnalysisTransform(a: 0.48, tx: 0.52))[0]
            let source = CIImage(color: CIColor(red: 0.31, green: 0.20, blue: 0.15))
                .cropped(to: CGRect(x: 256, y: 0, width: 256, height: 256))
                .composited(over: CIImage(color: CIColor(red: 0.79, green: 0.64, blue: 0.54)).cropped(to: extent))
            let result = try XCTUnwrap(AdaptiveSkinMaskGenerator().makeMask(source: source, faces: [left, right], quality: .final))
            XCTAssertEqual(result.instances.count, 2)
            XCTAssertGreaterThan(Self.sample(result.mask, CGPoint(x: 0.19, y: 0.77)), 0.35)
            XCTAssertGreaterThan(Self.sample(result.mask, CGPoint(x: 0.71, y: 0.77)), 0.35)
            XCTAssertLessThan(Self.sample(result.mask, CGPoint(x: 0.168, y: 0.57)), 0.05)
            XCTAssertLessThan(Self.sample(result.mask, CGPoint(x: 0.688, y: 0.57)), 0.05)
            XCTAssertEqual(Self.sample(try XCTUnwrap(result.instances[left.trackingID]), CGPoint(x: 0.71, y: 0.77)), 0, accuracy: 0.001)
        }.value
    }

    func testOneMaskForAllSkinEffectsAndFailureStillRunsFilter() async throws {
        try await Task.detached {
            let source = Self.source(in: CGRect(x: 0, y: 0, width: 128, height: 128))
            let faces = [SkinTestFace.make()]
            let analysis = AnalysisFixture.result(faces, size: source.extent.size)
            let calls = PhotoProcessingTestValue(0)
            let processor = BeautyProcessor(makeSkinMask: { image, faces, quality in
                calls.update { $0 += 1 }
                return try AdaptiveSkinMaskGenerator().makeMask(source: image, faces: faces, quality: quality)
            })
            let all = BeautyConfiguration(enabled: true, overallStrength: 1, smoothingStrength: 1,
                brighteningStrength: 1, toneStrength: 1, blemishStrength: 1, darkCirclesStrength: 1)
            for quality in [BeautyProcessingQuality.preview, .final] {
                _ = try processor.process(source, analysis: analysis, configuration: all, quality: quality)
            }
            XCTAssertEqual(calls.value, 2)
            _ = try processor.process(source, analysis: analysis, configuration: .disabled, quality: .final)
            XCTAssertEqual(calls.value, 2)
            let failing = BeautyProcessor(makeSkinMask: { _, _, _ in throw CoreImageRendering.Failure.renderFailed })
            let filter = FilterConfiguration(preset: .warm, intensity: 1)
            let skinFilter = BeautyConfiguration(enabled: true, overallStrength: 1, brighteningStrength: 1, filter: filter)
            let expected = try BeautyProcessor().process(source, analysis: nil,
                configuration: BeautyConfiguration(enabled: true, filter: filter), quality: .final)
            let output = try failing.process(source, analysis: analysis, configuration: skinFilter, quality: .final)
            XCTAssertEqual(try ColorPipelineFixture.pixels(output), try ColorPipelineFixture.pixels(expected))
            XCTAssertNotEqual(try ColorPipelineFixture.pixels(output), try ColorPipelineFixture.pixels(source))
            for empty in [AnalysisFixture.result([], size: source.extent.size),
                          FaceAnalysisEngine(makeAnalyzer: { FixtureFaceAnalyzer(failure: true) })
                            .analyze(source, timestamp: 1, orientation: .up, mirrored: false),
                          AnalysisFixture.result(faces, size: CGSize(width: 1, height: 1))] {
                let output = try BeautyProcessor().process(source, analysis: empty, configuration: skinFilter, quality: .final)
                XCTAssertEqual(try ColorPipelineFixture.pixels(output), try ColorPipelineFixture.pixels(expected))
                XCTAssertTrue(try processor.process(source, analysis: empty,
                    configuration: BeautyConfiguration(enabled: true), quality: .final) === source)
            }
        }.value
    }

    func testSimpleShapeMissingFeaturesBypassAndEyesHaveSmallBoundedEffect() async throws {
        try await Task.detached {
            let extent = CGRect(x: 0, y: 0, width: 256, height: 256)
            let face = SkinTestFace.make()
            let eyes = BeautyConfiguration(enabled: true, faceOverallStrength: 1, eyeStrength: 1)
            let adjustments = FaceCorrectionGeometry.eyes(faces: [face], configuration: eyes, extent: extent)
            XCTAssertEqual(adjustments.count, 2)
            XCTAssertTrue(adjustments.allSatisfy { $0.scale <= 0.06 && $0.radius < 30 })
            let noFeatures = AnalyzedFace(boundingBox: face.boundingBox, confidence: 1)
            XCTAssertTrue(FaceCorrectionGeometry.eyes(faces: [noFeatures], configuration: eyes, extent: extent).isEmpty)
            let source = CIImage(cvPixelBuffer: try ColorPipelineFixture.buffer())
            let analysis = AnalysisFixture.result([face], size: source.extent.size)
            let output = try BeautyProcessor().process(source, analysis: analysis, configuration: eyes, quality: .final)
            XCTAssertNotEqual(try ColorPipelineFixture.pixels(output), try ColorPipelineFixture.pixels(source))
            let unsupported = BeautyConfiguration(enabled: true, faceOverallStrength: 1, foreheadStrength: 1, cheekbonesStrength: 1)
            XCTAssertTrue(try BeautyProcessor().process(source, analysis: analysis, configuration: unsupported, quality: .final) === source)
        }.value
    }

    func testNativePhotoAndSilentInputsShareFinalAnalysisAndKeepFullResolution() async throws {
        try await Task.detached {
            let buffer = try ColorPipelineFixture.buffer()
            let source = CIImage(cvPixelBuffer: buffer)
            let png = try ColorPipelineFixture.png(source)
            let face = SkinTestFace.make()
            let sizes = PhotoProcessingTestValue<[CGSize]>([])
            final class Analyzer: FaceAnalyzer {
                let face: AnalyzedFace
                let sizes: PhotoProcessingTestValue<[CGSize]>
                init(_ face: AnalyzedFace, _ sizes: PhotoProcessingTestValue<[CGSize]>) { self.face = face; self.sizes = sizes }
                func faces(in image: CIImage) throws -> [AnalyzedFace] { sizes.update { $0.append(image.extent.size) }; return [face] }
            }
            let final = FinalBeautyProcessor(engine: FaceAnalysisEngine(makeAnalyzer: { Analyzer(face, sizes) }),
                encodeImage: { image, metadata, _ in FinalBeautyProcessor.encodeImage(image, metadata: metadata, type: "public.png" as CFString) })
            let configuration = BeautyConfiguration(enabled: true, overallStrength: 1, brighteningStrength: 1,
                filter: .init(preset: .warm, intensity: 0.4))
            let photo = try XCTUnwrap(final.processPhotoData(png, configuration: configuration))
            let frame = SilentFrame(pixelBuffer: buffer, timestamp: .zero, orientation: .up, position: .back, mirrored: false, metadata: [:])
            let silent = try XCTUnwrap(final.processSilentFrame(frame, configuration: configuration))
            XCTAssertEqual(sizes.value, [source.extent.size, source.extent.size])
            XCTAssertEqual(try ColorPipelineFixture.pixels(ColorPipelineFixture.decode(photo)),
                           try ColorPipelineFixture.pixels(ColorPipelineFixture.decode(silent)))
            for exif in [CGImagePropertyOrientation.up, .right, .down, .left, .upMirrored, .leftMirrored, .downMirrored, .rightMirrored] {
                let output = try XCTUnwrap(final.processSource(source, exif: exif, configuration: configuration))
                XCTAssertEqual(output.extent.size, source.oriented(exif).extent.size)
            }
        }.value
    }
}
