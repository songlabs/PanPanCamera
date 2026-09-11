#if DEBUG
import CoreImage
import XCTest
@testable import PanPanCamera

/// Synthetic Apple Core Image pixel tests. Windows parsing does not execute them;
/// real faces, preview timing and 50%/100% appearance require iPhone acceptance.
final class MakeupProcessingTests: XCTestCase {
    private let extent = CGRect(x: 0, y: 0, width: 256, height: 256)
    private let unchangedTolerance: Float = 0.0003

    func testZeroNoFaceAndMissingFeaturesBypass() async throws {
        try await Task.detached { [self] in
            let source = try fixture()
            let step = MakeupProcessingStep()
            XCTAssertNil(try step.makeOutput(source: source, faces: [face()], configuration: config()))
            XCTAssertNil(try step.makeOutput(source: source, faces: [], configuration: config(1, 1, 1, 1)))
            let missing = DetectedFace(boundingBox: face().boundingBox, confidence: 1, landmarks: [:])
            XCTAssertNil(try step.makeOutput(source: source, faces: [missing], configuration: config(1, 1, 1, 1)))
            var withoutMouth = face().landmarks
            withoutMouth.removeValue(forKey: .innerLips)
            let partial = DetectedFace(boundingBox: face().boundingBox, confidence: 1, landmarks: withoutMouth)
            XCTAssertNil(try step.makeOutput(source: source, faces: [partial], configuration: config(1)))
        }.value
    }

    func testEachLayerChangesItsRegionContinuouslyAndProtectsEyesMouthNoseAndBackground() async throws {
        try await Task.detached { [self] in
            let source = try fixture()
            let step = MakeupProcessingStep()
            let targetRegions = [
                CGRect(x: 112, y: 82, width: 30, height: 8), // upper lip, outside oral cavity
                CGRect(x: 75, y: 114, width: 15, height: 15), // left cheek
                CGRect(x: 75, y: 179, width: 15, height: 6), // above left eye
                CGRect(x: 69, y: 191, width: 25, height: 6) // existing brow hair
            ]
            for component in 0..<4 {
                let full = try XCTUnwrap(step.makeOutput(source: source, faces: [face()],
                    configuration: componentConfiguration(component, strength: 1)))
                let point = largestChange(source, full, in: targetRegions[component])
                let original = pixel(source, at: point)
                let fullPixel = pixel(full, at: point)
                let maximum = difference(source, full, at: point)
                XCTAssertGreaterThan(maximum, 0.003, "Layer \(component) must change its intended region")
                var previous: Float = 0
                for strength in [0.25, 0.5, 0.75, 1.0] {
                    let output = try XCTUnwrap(step.makeOutput(source: source, faces: [face()],
                        configuration: componentConfiguration(component, strength: strength)))
                    let change = difference(source, output, at: point)
                    XCTAssertGreaterThan(change, previous + 0.0001)
                    previous = change
                    XCTAssertEqual(output.extent, source.extent)
                    for channel in 0..<3 {
                        XCTAssertEqual(pixel(output, at: point)[channel],
                            original[channel] + Float(strength) * (fullPixel[channel] - original[channel]),
                            accuracy: 0.0005, "Slider interpolation must be continuous")
                    }
                    for protected in [CGPoint(x: 82, y: 169), CGPoint(x: 174, y: 169),
                                      CGPoint(x: 128, y: 77), CGPoint(x: 128, y: 132),
                                      CGPoint(x: 10, y: 10)] {
                        XCTAssertLessThan(difference(source, output, at: protected), unchangedTolerance,
                                          "Layer \(component) leaked into protected pixels")
                    }
                }
            }
        }.value
    }

    func testCombinedLayersRetainEveryEffectAndDuplicateFacesDoNotIntensifyIt() async throws {
        try await Task.detached { [self] in
            let source = try fixture()
            let step = MakeupProcessingStep()
            let once = try XCTUnwrap(step.makeOutput(source: source, faces: [face()],
                configuration: config(1, 1, 1, 1)))
            let repeated = try XCTUnwrap(step.makeOutput(source: source, faces: [face(), face()],
                configuration: config(1, 1, 1, 1)))
            for region in [CGRect(x: 112, y: 82, width: 30, height: 8),
                           CGRect(x: 75, y: 114, width: 15, height: 15),
                           CGRect(x: 75, y: 179, width: 15, height: 6),
                           CGRect(x: 69, y: 191, width: 25, height: 6)] {
                let point = largestChange(source, once, in: region)
                XCTAssertGreaterThan(difference(source, once, at: point), 0.003)
                XCTAssertLessThan(difference(once, repeated, at: point), unchangedTolerance)
            }
        }.value
    }

    func testLipRetainsTextureAndBlushHasBroadFeatheredSupport() async throws {
        try await Task.detached { [self] in
            let source = try fixture()
            let step = MakeupProcessingStep()
            let lip = try XCTUnwrap(step.makeOutput(source: source, faces: [face()], configuration: config(1)))
            // Alternating two-pixel source stripes run through the same lip band.
            // A solid paint polygon would erase this local high-frequency contrast.
            let a = CGPoint(x: 124, y: 86), b = CGPoint(x: 126, y: 86)
            let before = abs(pixel(source, at: a)[1] - pixel(source, at: b)[1])
            let after = abs(pixel(lip, at: a)[1] - pixel(lip, at: b)[1])
            XCTAssertGreaterThan(before, 0.1)
            XCTAssertGreaterThan(after, before * 0.80)
            let blush = try XCTUnwrap(step.makeOutput(source: source, faces: [face()], configuration: config(0, 1)))
            let flat = solid(0.5, 0.35, 0.3)
            let flatBlush = try XCTUnwrap(step.makeOutput(source: flat, faces: [face()], configuration: config(0, 1)))
            let center = difference(flat, flatBlush, at: CGPoint(x: 82, y: 120))
            let feather = difference(flat, flatBlush, at: CGPoint(x: 58, y: 120))
            let outside = difference(flat, flatBlush, at: CGPoint(x: 35, y: 120))
            XCTAssertGreaterThan(center, feather + 0.005)
            XCTAssertGreaterThan(feather, outside + 0.001)
            XCTAssertLessThan(outside, unchangedTolerance)
            XCTAssertEqual(blush.extent, source.extent)
        }.value
    }

    func testEyebrowsKeepExistingHairAndCacheNeverReusesSourcePixels() async throws {
        try await Task.detached { [self] in
            let source = try fixture()
            let step = MakeupProcessingStep()
            let output = try XCTUnwrap(step.makeOutput(source: source, faces: [face()], configuration: config(0, 0, 0, 1)))
            let point = largestChange(source, output, in: CGRect(x: 69, y: 191, width: 25, height: 6))
            XCTAssertGreaterThan(difference(source, output, at: point), 0.003)
            let flat = solid(0.5, 0.35, 0.3)
            let flatOutput = try XCTUnwrap(step.makeOutput(source: flat, faces: [face()], configuration: config(0, 0, 0, 1)))
            for x in stride(from: 64, through: 99, by: 3) {
                XCTAssertLessThan(difference(flat, flatOutput, at: CGPoint(x: x, y: 194)), unchangedTolerance,
                                  "Geometry cache must not carry hair or color from the preceding source")
            }
        }.value
    }

    func testTranslatedExtentAndMovingLandmarksMoveMakeupWithTheFace() async throws {
        try await Task.detached { [self] in
            let source = solid(0.5, 0.35, 0.3)
            let step = MakeupProcessingStep()
            let output = try XCTUnwrap(step.makeOutput(source: source, faces: [face()], configuration: config(1)))
            let translation = CGAffineTransform(translationX: 17, y: -23)
            let shifted = source.transformed(by: translation)
            let shiftedOutput = try XCTUnwrap(step.makeOutput(source: shifted, faces: [face()], configuration: config(1)))
            let point = CGPoint(x: 128, y: 86)
            XCTAssertEqual(shiftedOutput.extent, shifted.extent)
            for channel in 0..<4 {
                XCTAssertEqual(pixel(output, at: point)[channel],
                    pixel(shiftedOutput, at: point.applying(translation))[channel], accuracy: 0.0005)
            }
            let offset: CGFloat = 40.0 / 256
            let moved = DetectedFace(boundingBox: face().boundingBox.offsetBy(dx: offset, dy: 0),
                confidence: 1, landmarks: face().landmarks.mapValues { points in
                    points.map { CGPoint(x: $0.x + offset, y: $0.y) }
                })
            let movedOutput = try XCTUnwrap(step.makeOutput(source: source, faces: [moved], configuration: config(1)))
            XCTAssertLessThan(difference(source, movedOutput, at: point), unchangedTolerance)
            XCTAssertGreaterThan(difference(source, movedOutput, at: CGPoint(x: point.x + 40, y: point.y)), 0.01)
        }.value
    }

    func testMirroringAndQuarterTurnKeepEveryMakeupLayerOnCorrespondingPixels() async throws {
        try await Task.detached { [self] in
            let source = try fixture()
            let originalFace = face()
            let step = MakeupProcessingStep()
            let targets = [CGRect(x: 112, y: 82, width: 30, height: 8),
                           CGRect(x: 75, y: 114, width: 15, height: 15),
                           CGRect(x: 75, y: 179, width: 15, height: 6),
                           CGRect(x: 69, y: 191, width: 25, height: 6)]
            let orientations: [(FaceImageOrientation, Bool)] = [(.up, true), (.right, false), (.right, true)]
            for component in 0..<4 {
                let configuration = componentConfiguration(component, strength: 1)
                let original = try XCTUnwrap(step.makeOutput(source: source, faces: [originalFace],
                    configuration: configuration))
                let target = largestChange(source, original, in: targets[component])
                XCTAssertGreaterThan(difference(source, original, at: target), 0.003)
                for (orientation, mirrored) in orientations {
                    let exif = SilentFrameOrientation.exif(captureOrientation: orientation, mirrored: mirrored)
                    let transformedSource = source.oriented(exif)
                    let expected = original.oriented(exif)
                    let faces = BeautyImageProcessor.reorientedFaces([originalFace], from: .up,
                        to: orientation, mirrored: mirrored)
                    let actual = try XCTUnwrap(step.makeOutput(source: transformedSource, faces: faces,
                        configuration: configuration))
                    XCTAssertEqual(actual.extent, expected.extent)
                    for point in [target, CGPoint(x: 82, y: 169), CGPoint(x: 174, y: 169),
                                  CGPoint(x: 128, y: 77), CGPoint(x: 128, y: 132), CGPoint(x: 10, y: 10)] {
                        // Transform pixel centers, not integer corners: reflecting a
                        // corner would accidentally sample the adjacent texture stripe.
                        let normalized = CGPoint(x: (point.x + 0.5) / extent.width,
                                                 y: (point.y + 0.5) / extent.height)
                        let oriented = FaceCoordinates.reorient(normalized, from: .up,
                            to: orientation, mirrored: mirrored)
                        let sample = CGPoint(x: actual.extent.minX + oriented.x * actual.extent.width,
                                             y: actual.extent.minY + oriented.y * actual.extent.height)
                        for channel in 0..<4 {
                            XCTAssertEqual(pixel(actual, at: sample)[channel], pixel(expected, at: sample)[channel],
                                accuracy: 0.002, "Layer \(component), \(orientation), mirror \(mirrored)")
                        }
                        if point == target {
                            XCTAssertGreaterThan(difference(transformedSource, actual, at: sample), 0.003,
                                "The selected feature must move with the oriented source")
                        }
                    }
                }
            }
        }.value
    }

    func testSmallFaceWithoutEyebrowsCannotChangePrimaryFaceBrowReference() async throws {
        try await Task.detached { [self] in
            // A broad dark hair band makes neighborhood scale observable: a
            // one-pixel blur stays inside it, while the primary face's blur sees skin.
            let source = solid(0.25, 0.18, 0.15)
                .cropped(to: CGRect(x: 77, y: 0, width: 8, height: 256))
                .composited(over: solid(0.5, 0.35, 0.3)).cropped(to: extent)
            let primary = face()
            let smallWithoutBrows = DetectedFace(boundingBox: CGRect(x: 0.02, y: 0.03, width: 0.06, height: 0.06),
                confidence: 1, landmarks: [:])
            let step = MakeupProcessingStep()
            let once = try XCTUnwrap(step.makeOutput(source: source, faces: [primary],
                configuration: config(0, 0, 0, 1)))
            let sample = CGPoint(x: 81, y: 195)
            XCTAssertGreaterThan(difference(source, once, at: sample), 0.003,
                "Fixture must expose local hair contrast at the primary face's scale")
            for faces in [[primary, smallWithoutBrows], [smallWithoutBrows, primary]] {
                let multiple = try XCTUnwrap(step.makeOutput(source: source, faces: faces,
                    configuration: config(0, 0, 0, 1)))
                let bounds = CGRect(x: 77, y: 191, width: 8, height: 8)
                let before = ProcessingTestPixels.floats(once, bounds: bounds)
                let after = ProcessingTestPixels.floats(multiple, bounds: bounds)
                for (a, b) in zip(before, after) { XCTAssertEqual(a, b, accuracy: unchangedTolerance) }
            }
        }.value
    }

    private func config(_ lip: Double = 0, _ blush: Double = 0,
                        _ eye: Double = 0, _ brow: Double = 0) -> MakeupConfiguration {
        MakeupConfiguration(lip: lip, blush: blush, eye: eye, brow: brow)
    }

    private func componentConfiguration(_ component: Int, strength: Double) -> MakeupConfiguration {
        config(component == 0 ? strength : 0, component == 1 ? strength : 0,
               component == 2 ? strength : 0, component == 3 ? strength : 0)
    }

    private func face() -> DetectedFace {
        func oval(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> [CGPoint] {
            (0..<16).map { i in
                let angle = CGFloat(i) / 16 * 2 * .pi
                return CGPoint(x: x + cos(angle) * rx, y: y + sin(angle) * ry)
            }
        }
        return DetectedFace(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
            confidence: 1, landmarks: [
                .leftEye: oval(0.32, 0.66, 0.065, 0.025),
                .rightEye: oval(0.68, 0.66, 0.065, 0.025),
                .leftEyebrow: [CGPoint(x: 0.255, y: 0.755), CGPoint(x: 0.32, y: 0.765), CGPoint(x: 0.385, y: 0.755)],
                .rightEyebrow: [CGPoint(x: 0.615, y: 0.755), CGPoint(x: 0.68, y: 0.765), CGPoint(x: 0.745, y: 0.755)],
                .nose: [CGPoint(x: 0.48, y: 0.61), CGPoint(x: 0.45, y: 0.46),
                        CGPoint(x: 0.55, y: 0.46), CGPoint(x: 0.52, y: 0.61)],
                .outerLips: oval(0.5, 0.30, 0.13, 0.065),
                .innerLips: oval(0.5, 0.30, 0.085, 0.015)
            ])
    }

    private func fixture() throws -> CIImage {
        var image = solid(0.5, 0.35, 0.3)
        for x in stride(from: 0, to: 256, by: 4) {
            image = solid(0.24, 0.15, 0.12)
                .cropped(to: CGRect(x: x, y: 0, width: 2, height: 256)).composited(over: image)
        }
        return image.cropped(to: extent)
    }

    private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1,
            colorSpace: ProcessingTestPixels.linearColorSpace)!).cropped(to: extent)
    }

    private func pixel(_ image: CIImage, at point: CGPoint) -> [Float] {
        ProcessingTestPixels.floats(image,
            bounds: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1))
    }

    private func difference(_ a: CIImage, _ b: CIImage, at point: CGPoint) -> Float {
        zip(pixel(a, at: point).prefix(3), pixel(b, at: point).prefix(3)).map { abs($0 - $1) }.max() ?? 0
    }

    private func largestChange(_ source: CIImage, _ output: CIImage, in region: CGRect) -> CGPoint {
        let original = ProcessingTestPixels.floats(source, bounds: region)
        let adjusted = ProcessingTestPixels.floats(output, bounds: region)
        let width = Int(region.width)
        var best = 0, maximum: Float = 0
        for i in stride(from: 0, to: original.count, by: 4) {
            let delta = (0..<3).map { abs(original[i + $0] - adjusted[i + $0]) }.max() ?? 0
            if delta > maximum { maximum = delta; best = i / 4 }
        }
        return CGPoint(x: region.minX + CGFloat(best % width), y: region.minY + CGFloat(best / width))
    }
}
#endif
