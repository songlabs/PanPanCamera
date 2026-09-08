#if DEBUG
import CoreImage
import Foundation
import XCTest
@testable import PanPanCamera

final class NaturalSkinProcessingTests: XCTestCase {
    private let box = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)

    private final class Sentinel: Error, @unchecked Sendable {}
    private struct FailingMask: FaceMaskGenerating {
        let failure: Sentinel
        func makeMask(regions: [FaceRegion], in extent: CGRect) throws -> CIImage? { throw failure }
    }
    private struct EmptyMask: FaceMaskGenerating {
        func makeMask(regions: [FaceRegion], in extent: CGRect) throws -> CIImage? { nil }
    }

    private func process(_ input: ProcessingImage, boxes: [CGRect],
                         step: NaturalSkinProcessingStep = NaturalSkinProcessingStep()) async throws -> ProcessingImage {
        let regions = try boxes.map { try FaceRegion(boundingBox: $0) }
        let pipeline = ImageProcessingPipeline<ProcessingImage>(detector: MockFaceDetector(regions: regions), steps: [step])
        return try await pipeline.process(input).image
    }

    func testNoFacesReturnIdenticalCGImageWithoutInvokingMaskGenerator() async throws {
        let input = try ProcessingTestPixels.image()
        let result = try await process(input, boxes: [], step: NaturalSkinProcessingStep(maskGenerator: FailingMask(failure: Sentinel())))
        XCTAssertTrue(result.cgImage === input.cgImage)
    }

    func testNoUsableCoverageAndTinyFaceReturnIdenticalCGImage() async throws {
        let input = try ProcessingTestPixels.image()
        let empty = try await process(input, boxes: [box], step: NaturalSkinProcessingStep(maskGenerator: EmptyMask()))
        let tiny = try await process(input, boxes: [CGRect(x: 0.2, y: 0.2, width: 0.001, height: 0.001)])
        XCTAssertTrue(empty.cgImage === input.cgImage)
        XCTAssertTrue(tiny.cgImage === input.cgImage)
    }

    func testCenterChangesSlightlyFeatherWeakensAndExteriorStaysUnchanged() async throws {
        let input = try ProcessingTestPixels.image()
        let before = ProcessingTestPixels.rgba(input)
        let output = try await process(input, boxes: [box])
        XCTAssertEqual(output.cgImage.width, input.cgImage.width)
        XCTAssertEqual(output.cgImage.height, input.cgImage.height)
        XCTAssertEqual(ProcessingTestPixels.rgba(input), before, "Input storage was mutated")
        let center = ProcessingTestPixels.rgba(output, at: CGPoint(x: 50, y: 50))
        let feather = ProcessingTestPixels.rgba(output, at: CGPoint(x: 74, y: 50))
        for channel in 0..<3 {
            XCTAssertGreaterThan(center[channel], 100)
            XCTAssertLessThanOrEqual(center[channel], 106, "Experimental adjustment must remain slight")
            XCTAssertGreaterThanOrEqual(feather[channel], 100)
            XCTAssertLessThan(feather[channel], center[channel])
        }
        for point in [CGPoint(x: 10, y: 50), CGPoint(x: 90, y: 50), CGPoint(x: 50, y: 5),
                      CGPoint(x: 50, y: 95), CGPoint(x: 21, y: 11), CGPoint(x: 78, y: 88)] {
            let actual = ProcessingTestPixels.rgba(output, at: point)
            for channel in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(actual[channel]) - 100), 1) }
            XCTAssertEqual(actual[3], 255)
        }
    }

    func testDuplicateAndPartiallyOverlappingFacesNeverEnhanceTwice() async throws {
        let input = try ProcessingTestPixels.image()
        let other = CGRect(x: 0.35, y: 0.1, width: 0.6, height: 0.8)
        let first = try await process(input, boxes: [box])
        let second = try await process(input, boxes: [other])
        let union = try await process(input, boxes: [box, other])
        let duplicate = try await process(input, boxes: [box, box])
        let a = ProcessingTestPixels.rgba(first), b = ProcessingTestPixels.rgba(second)
        let combined = ProcessingTestPixels.rgba(union)
        XCTAssertEqual(a, ProcessingTestPixels.rgba(duplicate))
        for i in combined.indices {
            XCTAssertLessThanOrEqual(abs(Int(combined[i]) - Int(max(a[i], b[i]))), 1)
        }
    }

    func testColoredDetailStaysSharpAndAdjustmentIsSmallAcrossTones() async throws {
        // Adjacent one-pixel stripes make any spatial blur observable. These are
        // numerical color fixtures, not proof of natural appearance on real skin.
        let tones: [[UInt8]] = [[40, 25, 20, 255], [130, 85, 65, 255],
                               [220, 170, 145, 255], [245, 235, 225, 255]]
        let bytes = (0..<10000).flatMap { tones[($0 % 100) % tones.count] }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cg = try XCTUnwrap(CGImage(width: 100, height: 100, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: 400, space: ProcessingTestPixels.colorSpace,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = ProcessingImage(cgImage: cg)
        let output = try await process(input, boxes: [box])
        for x in 44..<56 {
            let point = CGPoint(x: CGFloat(x), y: 50)
            let before = ProcessingTestPixels.rgba(input, at: point)
            let after = ProcessingTestPixels.rgba(output, at: point)
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(Int(after[channel]) - Int(before[channel])), 16,
                                        "Mild tone adjustment must not mix neighboring stripe colors")
            }
            XCTAssertEqual(after[3], 255)
        }
    }

    func testDisjointFacesBothChangeAndGapIsPreserved() async throws {
        let input = try ProcessingTestPixels.image()
        let result = try await process(input, boxes: [CGRect(x: 0.05, y: 0.3, width: 0.3, height: 0.4),
                                                     CGRect(x: 0.65, y: 0.3, width: 0.3, height: 0.4)])
        XCTAssertGreaterThan(ProcessingTestPixels.rgba(result, at: CGPoint(x: 20, y: 50))[0], 100)
        XCTAssertGreaterThan(ProcessingTestPixels.rgba(result, at: CGPoint(x: 80, y: 50))[0], 100)
        XCTAssertLessThanOrEqual(abs(Int(ProcessingTestPixels.rgba(result, at: CGPoint(x: 50, y: 50))[0]) - 100), 1)
    }

    func testAllFourEdgesAndOnePixelFaceHaveNoBlackBordersOrAlphaChanges() async throws {
        let input = try ProcessingTestPixels.image()
        for edge in [CGRect(x: 0, y: 0.3, width: 0.3, height: 0.4),
                     CGRect(x: 0.7, y: 0.3, width: 0.3, height: 0.4),
                     CGRect(x: 0.3, y: 0, width: 0.3, height: 0.4),
                     CGRect(x: 0.3, y: 0.6, width: 0.3, height: 0.4),
                     CGRect(x: 0, y: 0, width: 0.01, height: 0.01)] {
            let result = try await process(input, boxes: [edge])
            XCTAssertEqual(result.cgImage.width, 100)
            XCTAssertEqual(result.cgImage.height, 100)
            let pixels = ProcessingTestPixels.rgba(result)
            for i in stride(from: 0, to: pixels.count, by: 4) {
                for channel in 0..<3 { XCTAssertTrue((99...106).contains(Int(pixels[i + channel]))) }
                XCTAssertEqual(pixels[i + 3], 255)
            }
        }
    }

    func testTranslucentAndTransparentInputsPreserveAlphaEverywhere() async throws {
        for alpha in [UInt8(0), 1, 128, 180, 255] {
            let input = try ProcessingTestPixels.image(alpha: alpha)
            let output = try await process(input, boxes: [box, box])
            let pixels = ProcessingTestPixels.rgba(output)
            for i in stride(from: 0, to: pixels.count, by: 4) {
                XCTAssertEqual(pixels[i + 3], alpha)
                for channel in 0..<3 { XCTAssertLessThanOrEqual(pixels[i + channel], alpha) }
            }
        }
    }

    func testMaskErrorPropagatesUnchangedAndPipelineReleasesAdmission() async throws {
        let failure = Sentinel()
        let input = try ProcessingTestPixels.image()
        let regions = [try FaceRegion(boundingBox: box)]
        let pipeline = ImageProcessingPipeline<ProcessingImage>(detector: MockFaceDetector(regions: regions),
            steps: [NaturalSkinProcessingStep(maskGenerator: FailingMask(failure: failure))])
        for _ in 0..<2 {
            do {
                _ = try await pipeline.process(input)
                XCTFail("Expected original mask error")
            } catch { XCTAssertTrue((error as? Sentinel) === failure, "Must not swallow the error or retain busy state") }
        }
        XCTAssertEqual(ProcessingTestPixels.rgba(input, at: CGPoint(x: 50, y: 50)), [100, 100, 100, 255])
    }
}
#endif
