#if DEBUG
import CoreImage
import Foundation
import XCTest
@testable import PanPanCamera

final class FeatureProtectionMaskTests: XCTestCase {
    private static func sample(_ image: CIImage, _ point: CGPoint) -> Float {
        ProcessingTestPixels.floats(image, bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1))[0]
    }

    private static func assertBounded(_ mask: CIImage, extent: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(mask.extent, extent, file: file, line: line)
        let pixels = ProcessingTestPixels.floats(mask, bounds: extent)
        XCTAssertTrue(pixels.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, file: file, line: line)
        XCTAssertTrue(stride(from: 0, to: pixels.count, by: 4).allSatisfy {
            abs(pixels[$0] - pixels[$0 + 1]) < 0.0001 && abs(pixels[$0] - pixels[$0 + 2]) < 0.0001 &&
                abs(pixels[$0 + 3] - 1) < 0.0001
        }, file: file, line: line)
    }

    func testMockEyesBrowsLipsAndNoseExceedNearbySkinAndNoseIsWeaker() async throws {
        let region = try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
        let landmarks = try MockFaceLandmarkDetector<Data>().detectLandmarks(in: Data(), regions: [region])
        try await Task.detached {
            let extent = CGRect(x: 0, y: 0, width: 256, height: 256)
            let mask = try XCTUnwrap(FeatureProtectionMaskGenerator().makeMask(landmarks: landmarks, regions: [region], in: extent))
            Self.assertBounded(mask, extent: extent)
            func value(_ x: CGFloat, _ y: CGFloat) -> Float { Self.sample(mask, CGPoint(x: x * 256, y: y * 256)) }
            let cheek = value(0.25, 0.45)
            for x: CGFloat in [0.30, 0.70] { XCTAssertGreaterThan(value(x, 0.64), cheek + 0.5) }
            for x: CGFloat in [0.27, 0.73] { XCTAssertGreaterThan(value(x, 0.79), value(x, 0.90) + 0.5) }
            XCTAssertGreaterThan(value(0.50, 0.30), value(0.50, 0.15) + 0.5)
            XCTAssertGreaterThan(value(0.50, 0.45), cheek + 0.2)
            XCTAssertLessThan(value(0.50, 0.45), value(0.30, 0.64))
        }.value
    }

    func testEveryFeatureHasCenterGreaterThanFeatherGreaterThanOutside() async throws {
        let region = try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
        try await Task.detached {
            let extent = CGRect(x: 0, y: 0, width: 400, height: 400)
            for feature in FacialLandmarkRegion.protectedFeatures {
                let polygon = [CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.4),
                               CGPoint(x: 0.6, y: 0.6), CGPoint(x: 0.4, y: 0.6)]
                let curve = [CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.6, y: 0.5)]
                let face = FacialLandmarks(region: region, features: [feature: feature.isProtectionPolygon ? polygon : curve])
                let mask = try XCTUnwrap(FeatureProtectionMaskGenerator().makeMask(landmarks: [face], regions: [region], in: extent))
                let policy = FeatureProtectionMaskGenerator.Policy.feature(feature)
                let edgeY = (feature.isProtectionPolygon ? 0.6 : 0.5) * 400 + policy.expansion * 400
                let center = Self.sample(mask, CGPoint(x: 200, y: 200))
                let feather = Self.sample(mask, CGPoint(x: 200, y: edgeY))
                let outside = Self.sample(mask, CGPoint(x: 200, y: edgeY + 4 * policy.feather * 400 + 2))
                XCTAssertGreaterThan(center, feather + 0.1, "\(feature)")
                XCTAssertGreaterThan(feather, outside + 0.1, "\(feature)")
                // Protection extends outside the polygon/curve itself.
                let expanded = Self.sample(mask, CGPoint(x: 200, y: edgeY - policy.expansion * 200))
                XCTAssertGreaterThan(expanded, feather, "\(feature)")
            }
        }.value
    }

    func testMultipleFacesAndOverlapsUseMaximumRegardlessOfOrderOrDuplicates() async throws {
        let a = try FaceRegion(boundingBox: CGRect(x: 0.05, y: 0.2, width: 0.4, height: 0.6))
        let b = try FaceRegion(boundingBox: CGRect(x: 0.30, y: 0.2, width: 0.4, height: 0.6))
        let c = try FaceRegion(boundingBox: CGRect(x: 0.8, y: 0.4, width: 0.2, height: 0.3))
        let faces = try MockFaceLandmarkDetector<Data>().detectLandmarks(in: Data(), regions: [a, b, c])
        try await Task.detached {
            let extent = CGRect(x: 0, y: 0, width: 128, height: 128)
            func pixels(_ landmarks: [FacialLandmarks]) throws -> [Float] {
                let mask = try XCTUnwrap(FeatureProtectionMaskGenerator().makeMask(landmarks: landmarks, regions: [c, b, a], in: extent))
                Self.assertBounded(mask, extent: extent)
                return ProcessingTestPixels.floats(mask, bounds: extent)
            }
            let singles = try faces.map { try pixels([$0]) }
            let combined = try pixels(faces)
            let reverse = try pixels([faces[2], faces[1], faces[0], faces[1]])
            for i in combined.indices {
                XCTAssertEqual(combined[i], singles.map { $0[i] }.max()!, accuracy: 0.0001)
                XCTAssertEqual(combined[i], reverse[i], accuracy: 0.0001)
            }
        }.value
    }

    func testMissingPartialInvalidAndMismatchedLandmarksLeaveRemainingCoverageUsable() async throws {
        let a = try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 0.4, height: 1))
        let b = try FaceRegion(boundingBox: CGRect(x: 0.6, y: 0, width: 0.4, height: 1))
        let partial = FacialLandmarks(region: b, features: [
            .leftEye: [.zero, CGPoint(x: CGFloat.nan, y: 0.5), CGPoint(x: 1, y: 1)],
            .outerLips: MockFaceLandmarkDetector<Data>.proportions[.outerLips]!
        ])
        try await Task.detached {
            let extent = CGRect(x: 0, y: 0, width: 200, height: 200)
            let generator = FeatureProtectionMaskGenerator()
            XCTAssertNil(try generator.makeMask(landmarks: [], regions: [a], in: extent))
            XCTAssertNil(try generator.makeMask(landmarks: [FacialLandmarks(region: a, features: [:])], regions: [a], in: extent))
            XCTAssertNil(try generator.makeMask(landmarks: [partial], regions: [a], in: extent))
            let mask = try XCTUnwrap(generator.makeMask(landmarks: [partial], regions: [a, b], in: extent))
            XCTAssertGreaterThan(Self.sample(mask, CGPoint(x: 160, y: 60)), 0.8)
            XCTAssertLessThan(Self.sample(mask, CGPoint(x: 40, y: 60)), 0.001)
            XCTAssertLessThan(Self.sample(mask, CGPoint(x: 144, y: 128)), 0.001)
        }.value
    }

    func testImageEdgesNonzeroExtentAndOnePixelFacesRemainFiniteAndAligned() async throws {
        let boxes = [CGRect(x: 0, y: 0.3, width: 0.3, height: 0.4), CGRect(x: 0.7, y: 0.3, width: 0.3, height: 0.4),
                     CGRect(x: 0.3, y: 0, width: 0.4, height: 0.3), CGRect(x: 0.3, y: 0.7, width: 0.4, height: 0.3),
                     CGRect(x: 0.5, y: 0.5, width: 0.01, height: 0.01)]
        for box in boxes {
            let region = try FaceRegion(boundingBox: box)
            // A polygon touching every face edge also exercises clipped feathering.
            let face = FacialLandmarks(region: region, features: [.leftEye: [.zero, CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]])
            try await Task.detached {
                let extent = CGRect(x: 11, y: -7, width: 100, height: 100)
                let mask = try XCTUnwrap(FeatureProtectionMaskGenerator().makeMask(landmarks: [face], regions: [region], in: extent))
                Self.assertBounded(mask, extent: extent)
                let rect = region.imageRect(in: extent)
                XCTAssertGreaterThan(Self.sample(mask, CGPoint(x: rect.midX, y: rect.midY)), 0.1)
            }.value
        }
    }

    func testSubpixelFacesSkipAndInvalidExtentsFailBeforeRasterization() async throws {
        let region = try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 1e-12, height: 1e-12))
        let faces = try MockFaceLandmarkDetector<Data>().detectLandmarks(in: Data(), regions: [region])
        try await Task.detached {
            let generator = FeatureProtectionMaskGenerator()
            XCTAssertNil(try generator.makeMask(landmarks: faces, regions: [region], in: CGRect(x: 0, y: 0, width: 100, height: 100)))
            for extent in [CGRect.zero, CGRect.null, CGRect.infinite, CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100)] {
                XCTAssertThrowsError(try generator.makeMask(landmarks: faces, regions: [region], in: extent))
            }
        }.value
    }

    func testCombinedProtectionAndEffectiveWeightsAreBoundedAndOverlapDoesNotAccumulate() async throws {
        try await Task.detached {
            let extent = CGRect(x: 3, y: -5, width: 8, height: 8)
            func constant(_ value: CGFloat) -> CIImage {
                SemanticMaskTestPixels.constant(value, in: extent)
            }
            let configuration = try SkinRetouchConfiguration(intensity: SkinRetouchIntensity(0.5), edgeProtectionStrength: 0.75)
            for (feature, edge): (CGFloat, CGFloat) in [(0, 0), (0.9, 0), (0, 1), (1, 1), (0.8, 0.8), (-0.2, 2)] {
                let combined = try ProtectionMaskCombiner.combined(feature: constant(feature), detail: constant(edge), configuration: configuration)
                let expected = max(min(1, max(0, feature)), min(1, max(0, edge * 0.75)))
                XCTAssertEqual(Self.sample(combined, extent.origin), Float(expected), accuracy: 0.0001)
                Self.assertBounded(combined, extent: extent)
                let effective = try ProtectionMaskCombiner.effective(face: constant(0.6), combined: combined, configuration: configuration)
                XCTAssertEqual(Self.sample(effective, extent.origin), Float(0.6 * (1 - expected) * 0.5), accuracy: 0.0001)
                Self.assertBounded(effective, extent: extent)
            }
            let noFeatures = try ProtectionMaskCombiner.combined(feature: nil, detail: constant(0.8), configuration: configuration)
            XCTAssertEqual(Self.sample(noFeatures, extent.origin), 0.6, accuracy: 0.0001)
        }.value
    }
}
#endif
