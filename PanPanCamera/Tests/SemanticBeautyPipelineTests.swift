import AVFoundation
import CoreImage
import ImageIO
import XCTest
@testable import PanPanCamera

final class SemanticBeautyPipelineTests: XCTestCase {
    func testAsymmetricSemanticRasterKeepsBottomOriginThroughMirrorAndQuarterTurns() async throws {
        try await Task.detached {
            let extent = CGRect(x: 9, y: -13, width: 80, height: 80)
            // Bottom-left quadrant only. Reading CI pixels verifies row order,
            // scalar transfer, extent origin and the actual rendering adapter.
            let values: [Float] = (0..<64).map { index in index % 8 < 4 && index / 8 < 4 ? 1 : 0 }
            let plane = try FaceSemanticPlane(width: 8, height: 8, values: values)
            for orientation in FaceImageOrientation.allCases {
                for mirror in [false, true] {
                    let transform = FaceAnalysisCoordinates.reorientation(from: .up, sourceMirrored: false,
                        to: orientation, mirrored: mirror)
                    let image = try FaceSemanticRaster.image(plane.transformed(by: transform), in: extent)
                    for point in [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25),
                                  CGPoint(x: 0.25, y: 0.75), CGPoint(x: 0.75, y: 0.75)] {
                        let mapped = transform.point(point)
                        let pixel = ProcessingTestPixels.floats(image, bounds: CGRect(
                            x: extent.minX + mapped.x * extent.width, y: extent.minY + mapped.y * extent.height,
                            width: 1, height: 1))[0]
                        XCTAssertEqual(pixel, point.x < 0.5 && point.y < 0.5 ? 1 : 0, accuracy: 0.001)
                    }
                }
            }
        }.value
    }

    func testSemanticForeheadBrightensAboveBoxAndEveryProtectedClassStaysUnchanged() async throws {
        try await Task.detached {
            let extent = CGRect(x: 11, y: -7, width: 128, height: 128)
            let source = CIImage(color: CIColor(red: 0.4, green: 0.3, blue: 0.25)).cropped(to: extent)
            let configuration = BeautyConfiguration(enabled: true, overallStrength: 1, brighteningStrength: 1)
            let processor = BeautyProcessor()
            for protected in [FaceSemanticClass.hair, .leftEye, .rightEye, .leftEyebrow, .rightEyebrow, .lips, .mouth, .glasses] {
                let masks = try SemanticFixture.masks { x, y in
                    if x < 2 || x > 13 || y < 2 || y > 13 { return .background }
                    if (6...9).contains(x) && (6...9).contains(y) { return protected }
                    return .skin
                }
                let face = AnalyzedFace(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.4),
                    confidence: 1, semanticMasks: masks)
                for quality in [BeautyProcessingQuality.preview, .final] {
                    let output = try processor.process(source, analysis: SemanticFixture.result([face], size: extent.size),
                        configuration: configuration, quality: quality)
                    func sample(_ image: CIImage, _ x: Int, _ y: Int) -> [Float] {
                        ProcessingTestPixels.floats(image, bounds: CGRect(x: extent.minX + CGFloat(x),
                            y: extent.minY + CGFloat(y), width: 1, height: 1))
                    }
                    // Forehead y=100 lies above the detector box's y=76.8 top.
                    XCTAssertGreaterThan(sample(output, 40, 100)[0], sample(source, 40, 100)[0] + 0.005)
                    for point in [(64, 64), (4, 4)] {
                        for (a, b) in zip(sample(source, point.0, point.1), sample(output, point.0, point.1)) {
                            XCTAssertEqual(a, b, accuracy: 2.0 / 255.0, protected.rawValue)
                        }
                    }
                }
            }
        }.value
    }

    func testParsingUnavailableNeverEnablesSkinButDenseMakeupAndShapeRemainUsable() async throws {
        try await Task.detached {
            let source = CIImage(cvPixelBuffer: try ColorPipelineFixture.buffer())
            let face = ColorPipelineFixture.face()
            let analysis = SemanticFixture.result([face], size: source.extent.size)
            let processor = BeautyProcessor()
            let skin = BeautyConfiguration(enabled: true, overallStrength: 1, smoothingStrength: 1,
                brighteningStrength: 1, toneStrength: 1, blemishStrength: 1, darkCirclesStrength: 1)
            XCTAssertTrue(try processor.process(source, analysis: analysis, configuration: skin, quality: .final) === source)
            let makeup = BeautyConfiguration(enabled: true, makeup: MakeupConfiguration(lip: 1))
            XCTAssertNotEqual(try ColorPipelineFixture.pixels(processor.process(source, analysis: analysis,
                configuration: makeup, quality: .final)), try ColorPipelineFixture.pixels(source))
            let shape = BeautyConfiguration(enabled: true, faceOverallStrength: 1, faceWidthStrength: 1)
            XCTAssertNotEqual(try ColorPipelineFixture.pixels(processor.process(source, analysis: analysis,
                configuration: shape, quality: .final)), try ColorPipelineFixture.pixels(source))
        }.value
    }

    func testLandmarksUnavailableKeepsSemanticSkinAndBypassesShapeAndMakeup() async throws {
        try await Task.detached {
            let source = CIImage(cvPixelBuffer: try ColorPipelineFixture.buffer())
            let masks = try SemanticFixture.masks { _, _ in .skin }
            let face = AnalyzedFace(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), confidence: 1, semanticMasks: masks)
            let analysis = SemanticFixture.result([face], size: source.extent.size)
            let processor = BeautyProcessor()
            let shapeMakeup = BeautyConfiguration(enabled: true, faceOverallStrength: 1, faceWidthStrength: 1,
                makeup: MakeupConfiguration(lip: 1, blush: 1, eye: 1, brow: 1))
            XCTAssertTrue(try processor.process(source, analysis: analysis, configuration: shapeMakeup, quality: .final) === source)
            let skin = BeautyConfiguration(enabled: true, overallStrength: 1, brighteningStrength: 1)
            XCTAssertNotEqual(try ColorPipelineFixture.pixels(processor.process(source, analysis: analysis,
                configuration: skin, quality: .final)), try ColorPipelineFixture.pixels(source))
        }.value
    }

    func testUnavailableAnalysisAndContractMismatchStillRunFilterAndZeroReturnsIdentity() async throws {
        try await Task.detached {
            let source = CIImage(cvPixelBuffer: try ColorPipelineFixture.buffer())
            let engine = FaceAnalysisEngine()
            let unavailable = engine.analyze(source, timestamp: 1, orientation: .up, mirrored: false)
            XCTAssertEqual(unavailable.outcome, .unavailable)
            let failed = FaceAnalysisEngine(makeAnalyzer: { FixtureFaceAnalyzer(failure: true) })
                .analyze(source, timestamp: 1, orientation: .up, mirrored: false)
            XCTAssertEqual(failed.outcome, .failed)
            let mismatch = SemanticFixture.result([ColorPipelineFixture.face()], size: CGSize(width: 1, height: 1))
            let processor = BeautyProcessor()
            let filter = BeautyConfiguration(enabled: true, filter: .init(preset: .warm, intensity: 1))
            let expected = try ColorPipelineFixture.pixels(processor.process(source, analysis: nil, configuration: filter, quality: .final))
            for result in [unavailable, failed, mismatch] {
                XCTAssertEqual(try ColorPipelineFixture.pixels(processor.process(source, analysis: result,
                    configuration: filter, quality: .final)), expected)
                XCTAssertTrue(try processor.process(source, analysis: result, configuration: .disabled, quality: .final) === source)
            }
        }.value
    }

    func testMultipleFaceWarpsAndMasksRemainBoundToIdentity() async throws {
        try await Task.detached {
            let base = ColorPipelineFixture.face()
            let left = try XCTUnwrap(FaceAnalysisCoordinates.map([base], by: FaceAnalysisTransform(a: 0.45, d: 0.8)).first)
            let right = try XCTUnwrap(FaceAnalysisCoordinates.map([base], by: FaceAnalysisTransform(a: 0.45, d: 0.8, tx: 0.55)).first)
            let configuration = BeautyConfiguration(enabled: true, faceOverallStrength: 1, faceSlimStrength: 1)
            let extent = CGRect(x: 0, y: 0, width: 384, height: 256)
            let all = FaceCorrectionGeometry.warps(faces: [left, right], configuration: configuration, extent: extent)
            XCTAssertEqual(all.count, 24)
            XCTAssertTrue(all.prefix(12).allSatisfy { $0.center.x < extent.midX })
            XCTAssertTrue(all.suffix(12).allSatisfy { $0.center.x > extent.midX })
            let source = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: extent)
            let image = try XCTUnwrap(FaceCorrectionPreviewStep().makeOutput(source: source, warps: all))
            XCTAssertEqual(try XCTUnwrap(CoreImageRendering.createCGImage(image, colorSpace: nil)).width, 384)
            let skin = try SemanticFixture.masks { x, _ in x < 8 ? .skin : .background }
            let hair = try SemanticFixture.masks { _, _ in .hair }
            let a = AnalyzedFace(boundingBox: left.boundingBox, confidence: 1, semanticMasks: skin)
            let b = AnalyzedFace(boundingBox: right.boundingBox, confidence: 1, semanticMasks: hair)
            // A protected class in another overlapping instance vetoes skin.
            let mask = try XCTUnwrap(SemanticSkinMaskComposer().makeMask(source: source, faces: [a, b]))
            XCTAssertLessThan(ProcessingTestPixels.floats(mask, bounds: CGRect(x: 80, y: 100, width: 1, height: 1))[0], 0.001)
        }.value
    }

    func testNativePhotoAndSilentInputsShareFinalAnalysisAndKeepFullResolution() async throws {
        try await Task.detached {
            let buffer = try ColorPipelineFixture.buffer()
            let source = CIImage(cvPixelBuffer: buffer)
            let png = try ColorPipelineFixture.png(source)
            let masks = try SemanticFixture.masks { _, _ in .skin }
            let face = AnalyzedFace(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), confidence: 1, semanticMasks: masks)
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
