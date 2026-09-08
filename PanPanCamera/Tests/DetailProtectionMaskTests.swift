#if DEBUG
import CoreImage
import Foundation
import XCTest
@testable import PanPanCamera

final class DetailProtectionMaskTests: XCTestCase {
    func testHighGradientAndThinLineHaveMoreProtectionThanFlatArea() async throws {
        let input = try SkinRetouchTestImage.make { x, _ in
            let value: UInt8 = x == 104 ? 20 : (x < 128 ? 140 : 220)
            return [value, value, value, 255]
        }
        let region = try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
        try await Task.detached {
            let source = CIImage(cgImage: input.cgImage).transformed(by: CGAffineTransform(translationX: 11, y: -7))
            let scale = try XCTUnwrap(SkinRetouchScale(regions: [region], in: source.extent))
            let generator = DetailProtectionMaskGenerator()
            let protection = try generator.makeMask(source: source, scale: scale)
            XCTAssertEqual(protection.extent, source.extent)
            let pixels = ProcessingTestPixels.floats(protection, bounds: source.extent)
            for i in stride(from: 0, to: pixels.count, by: 4) {
                XCTAssertTrue(pixels[i].isFinite && pixels[i] >= 0 && pixels[i] <= 1)
                XCTAssertEqual(pixels[i], pixels[i + 1], accuracy: 0.0001)
                XCTAssertEqual(pixels[i], pixels[i + 2], accuracy: 0.0001)
                XCTAssertEqual(pixels[i + 3], 1, accuracy: 0.0001)
            }
            func sample(_ mask: CIImage, _ x: CGFloat) -> Float {
                ProcessingTestPixels.floats(mask, bounds: CGRect(x: x + 11, y: 120 - 7, width: 1, height: 1))[0]
            }
            XCTAssertGreaterThan(sample(protection, 127), sample(protection, 80) + 0.2)
            XCTAssertGreaterThan(sample(protection, 104), sample(protection, 80) + 0.2)
            let face = try XCTUnwrap(SoftFaceMaskGenerator().makeMask(regions: [region], in: source.extent))
            let effective = try generator.effectiveMask(faceMask: face, protection: protection, configuration: .naturalDefault)
            XCTAssertLessThan(sample(effective, 127), sample(effective, 80))
            XCTAssertEqual(sample(effective, 5), 0, accuracy: 0.00001)
            XCTAssertLessThan(sample(effective, 45), sample(effective, 80), "Feather lowers coverage")
            let weights = ProcessingTestPixels.floats(effective, bounds: source.extent)
            for i in stride(from: 0, to: weights.count, by: 4) {
                for c in 0..<3 {
                    XCTAssertTrue(weights[i + c].isFinite && weights[i + c] >= 0 && weights[i + c] <= 0.25001)
                }
                XCTAssertEqual(weights[i + 3], 1, accuracy: 0.0001)
            }
            let noProtection = try generator.effectiveMask(faceMask: face, protection: protection,
                configuration: SkinRetouchConfiguration(edgeProtectionStrength: 0))
            XCTAssertEqual(sample(noProtection, 127), 0.25, accuracy: 0.0001)
        }.value
    }
}
#endif
