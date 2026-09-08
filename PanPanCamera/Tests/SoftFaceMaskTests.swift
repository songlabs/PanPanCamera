#if DEBUG
import CoreImage
import Foundation
import XCTest
@testable import PanPanCamera

/// Synthetic Apple-framework fixtures. Host syntax/static checks cannot run these.
enum ProcessingTestPixels {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func image(width: Int = 100, height: Int = 100, alpha: UInt8 = 255) throws -> ProcessingImage {
        let value = min(UInt8(100), alpha)
        let bytes = Array(repeating: [value, value, value, alpha], count: width * height).flatMap { $0 }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cg = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return ProcessingImage(cgImage: cg)
    }

    static func rgba(_ image: ProcessingImage, at point: CGPoint? = nil) -> [UInt8] {
        let bounds = point.map { CGRect(x: $0.x, y: $0.y, width: 1, height: 1) }
            ?? CGRect(x: 0, y: 0, width: CGFloat(image.cgImage.width), height: CGFloat(image.cgImage.height))
        var pixels = [UInt8](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        pixels.withUnsafeMutableBytes {
            context.render(CIImage(cgImage: image.cgImage), toBitmap: $0.baseAddress!,
                           rowBytes: Int(bounds.width) * 4, bounds: bounds, format: .RGBA8, colorSpace: colorSpace)
        }
        return pixels
    }

    static func floats(_ image: CIImage, bounds: CGRect) -> [Float] {
        var pixels = [Float](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        pixels.withUnsafeMutableBytes {
            // No color conversion: check actual grayscale mask weights, including
            // out-of-range/NaN values that an RGBA8 render would silently clamp.
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(bounds.width) * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: nil)
        }
        return pixels
    }
}

final class SoftFaceMaskTests: XCTestCase {
    private let extent = CGRect(x: 0, y: 0, width: 100, height: 100)
    private let box = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)

    private struct Samples: Sendable {
        let extent: CGRect
        let pixels: [Float]
        let points: [[Float]]
    }

    private func mask(boxes: [CGRect], extent: CGRect? = nil, points: [CGPoint] = []) async throws -> Samples? {
        let regions = try boxes.map { try FaceRegion(boundingBox: $0) }
        let bounds = extent ?? self.extent
        return try await Task.detached { () throws -> Samples? in
            guard let mask = try SoftFaceMaskGenerator().makeMask(regions: regions, in: bounds) else { return nil }
            return Samples(extent: mask.extent, pixels: ProcessingTestPixels.floats(mask, bounds: bounds),
                           points: points.map {
                ProcessingTestPixels.floats(mask, bounds: CGRect(x: $0.x, y: $0.y, width: 1, height: 1))
            })
        }.value
    }

    private func assertValid(_ samples: Samples, expectedExtent: CGRect,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(samples.extent, expectedExtent, file: file, line: line)
        XCTAssertTrue(samples.pixels.allSatisfy { $0.isFinite && $0 >= -0.0001 && $0 <= 1.0001 }, file: file, line: line)
        for i in stride(from: 0, to: samples.pixels.count, by: 4) {
            XCTAssertEqual(samples.pixels[i], samples.pixels[i + 1], accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(samples.pixels[i], samples.pixels[i + 2], accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(samples.pixels[i + 3], 1, accuracy: 0.0001, file: file, line: line)
        }
    }

    func testSingleFaceHasWhiteCenterFeatherAndBlackExteriorAndCorners() async throws {
        let result = try await mask(boxes: [box], points: [
            CGPoint(x: 50, y: 50), CGPoint(x: 71, y: 50), CGPoint(x: 78, y: 50),
            CGPoint(x: 10, y: 50), CGPoint(x: 21, y: 11), CGPoint(x: 78, y: 88)
        ])
        let samples = try XCTUnwrap(result)
        assertValid(samples, expectedExtent: extent)
        XCTAssertGreaterThan(samples.points[0][0], 0.95)
        XCTAssertGreaterThan(samples.points[1][0], 0.1)
        XCTAssertLessThan(samples.points[1][0], 0.85)
        for point in samples.points.dropFirst(2) { XCTAssertLessThan(point[0], 0.001) }
    }

    func testFeatherChangesGraduallyInsteadOfAtAHardBoundary() async throws {
        let result = try await mask(boxes: [box], points: (65...78).map { CGPoint(x: CGFloat($0), y: 50) })
        let values = try XCTUnwrap(result).points.map { $0[0] }
        XCTAssertGreaterThan(values.filter { $0 > 0.05 && $0 < 0.95 }.count, 5)
        for (inner, outer) in zip(values, values.dropFirst()) {
            XCTAssertGreaterThanOrEqual(inner + 0.0001, outer)
            XCTAssertLessThan(abs(inner - outer), 0.2)
        }
    }

    func testNoFacesAndSubpixelBoxesReturnNil() async throws {
        let empty = try await mask(boxes: [])
        XCTAssertNil(empty)
        for size in [0.001, 0.000000001, Double.leastNonzeroMagnitude] {
            let tiny = try await mask(boxes: [CGRect(x: 0, y: 0, width: size, height: size)])
            XCTAssertNil(tiny)
        }
    }

    func testOnePixelFaceRemainsFiniteWithoutExpandingExtent() async throws {
        let result = try await mask(boxes: [CGRect(x: 0.495, y: 0.495, width: 0.01, height: 0.01)])
        assertValid(try XCTUnwrap(result), expectedExtent: extent)
    }

    func testEachImageEdgeAndNonzeroOriginKeepCorrectCoordinates() async throws {
        let shifted = CGRect(x: 10, y: 20, width: 100, height: 100)
        for edgeBox in [CGRect(x: 0, y: 0.3, width: 0.3, height: 0.4),
                        CGRect(x: 0.7, y: 0.3, width: 0.3, height: 0.4),
                        CGRect(x: 0.3, y: 0, width: 0.3, height: 0.4),
                        CGRect(x: 0.3, y: 0.6, width: 0.3, height: 0.4)] {
            let center = CGPoint(x: shifted.minX + edgeBox.midX * 100, y: shifted.minY + edgeBox.midY * 100)
            let result = try await mask(boxes: [edgeBox], extent: shifted, points: [center])
            let samples = try XCTUnwrap(result)
            assertValid(samples, expectedExtent: shifted)
            XCTAssertGreaterThan(samples.points[0][0], 0.95)
        }
    }

    func testWideBoxStillProducesPortraitEllipse() async throws {
        let result = try await mask(boxes: [CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.4)], points: [
            CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 64), CGPoint(x: 64, y: 50)
        ])
        let points = try XCTUnwrap(result).points
        XCTAssertGreaterThan(points[0][0], 0.95)
        XCTAssertGreaterThan(points[1][0], points[2][0] + 0.2)
    }

    func testDisjointFacesKeepBothCentersAndBlackGap() async throws {
        let result = try await mask(boxes: [CGRect(x: 0.05, y: 0.3, width: 0.3, height: 0.4),
                                            CGRect(x: 0.65, y: 0.3, width: 0.3, height: 0.4)], points: [
            CGPoint(x: 20, y: 50), CGPoint(x: 80, y: 50), CGPoint(x: 50, y: 50)
        ])
        let samples = try XCTUnwrap(result)
        assertValid(samples, expectedExtent: extent)
        XCTAssertGreaterThan(samples.points[0][0], 0.95)
        XCTAssertGreaterThan(samples.points[1][0], 0.95)
        XCTAssertLessThan(samples.points[2][0], 0.001)
    }

    func testOverlapUsesMaximumIncludingFeatherAndDuplicateIsIdempotent() async throws {
        let other = CGRect(x: 0.35, y: 0.1, width: 0.6, height: 0.8)
        let firstResult = try await mask(boxes: [box])
        let secondResult = try await mask(boxes: [other])
        let unionResult = try await mask(boxes: [box, other])
        let reversedResult = try await mask(boxes: [other, box])
        let duplicateResult = try await mask(boxes: [box, box])
        let first = try XCTUnwrap(firstResult), second = try XCTUnwrap(secondResult)
        let union = try XCTUnwrap(unionResult), reversed = try XCTUnwrap(reversedResult)
        let duplicate = try XCTUnwrap(duplicateResult)
        assertValid(union, expectedExtent: extent)
        for i in first.pixels.indices {
            XCTAssertEqual(union.pixels[i], max(first.pixels[i], second.pixels[i]), accuracy: 0.0001)
            XCTAssertEqual(union.pixels[i], reversed.pixels[i], accuracy: 0.0001)
            XCTAssertEqual(first.pixels[i], duplicate.pixels[i], accuracy: 0.0001)
        }
    }

    func testInvalidExtentsThrowBeforeCoreImageOperations() async throws {
        for invalid in [CGRect.zero, CGRect.null, CGRect.infinite,
                        CGRect(x: 0, y: 0, width: CGFloat.nan, height: 10)] {
            do {
                _ = try await mask(boxes: [box], extent: invalid)
                XCTFail("Expected invalid extent failure")
            } catch { XCTAssertTrue(error is SoftFaceMaskGenerator.Failure) }
        }
    }
}
#endif
