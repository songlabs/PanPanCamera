#if DEBUG
import CoreImage
import Foundation
import XCTest
@testable import PanPanCamera

/// Synthetic Apple pixel acceptance. These fixtures are not real-face evidence.
final class FacialFeatureProcessingTests: XCTestCase {
    private final class CallCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func record() { lock.lock(); defer { lock.unlock() }; count += 1 }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    private struct FailingProvider: FaceLandmarkDetecting {
        enum Failure: Error { case unavailable }
        let calls: CallCount
        func detectLandmarks(in image: ProcessingImage, regions: [FaceRegion]) throws -> [FacialLandmarks] {
            calls.record()
            throw Failure.unavailable
        }
    }

    private func fullFace() throws -> FaceRegion {
        try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func process(_ image: ProcessingImage, regions: [FaceRegion],
                         provider: (any FaceLandmarkDetecting<ProcessingImage>)?,
                         configuration: SkinRetouchConfiguration = .naturalDefault) async throws -> ProcessingImage {
        let pipeline = ImageProcessingPipeline<ProcessingImage>(detector: MockFaceDetector(regions: regions),
            steps: [TexturePreservingSkinSmoothingStep(configuration: configuration, landmarkDetector: provider)])
        return try await pipeline.process(image).image
    }

    func testZeroIntensityWithLandmarksReturnsExactInputWithoutCallingProvider() async throws {
        let input = try SkinRetouchTestImage.texture(), region = try fullFace()
        let calls = CallCount()
        for provider: any FaceLandmarkDetecting<ProcessingImage> in [
            MockFaceLandmarkDetector<ProcessingImage>(), FailingProvider(calls: calls)
        ] {
            let output = try await process(input, regions: [region], provider: provider,
                configuration: .naturalDefault.withIntensity(.original))
            XCTAssertTrue(output.cgImage === input.cgImage)
        }
        XCTAssertEqual(calls.value, 0)
    }

    func testEmptyFacesBypassLandmarkProvider() async throws {
        let input = try SkinRetouchTestImage.texture(), calls = CallCount()
        let result = try await process(input, regions: [], provider: FailingProvider(calls: calls))
        XCTAssertTrue(result.cgImage === input.cgImage)
        XCTAssertEqual(calls.value, 0)
    }

    func testMissingEmptyInvalidAndFailedLandmarksMatchEdgeOnlyFallbackAndStillSmooth() async throws {
        let input = try SkinRetouchTestImage.texture(), region = try fullFace()
        let configuration = SkinRetouchConfiguration.naturalDefault.withIntensity(try SkinRetouchIntensity(1))
        let baseline = try await process(input, regions: [region], provider: nil, configuration: configuration)
        let calls = CallCount()
        let invalid = FacialLandmarks(region: region, features: [.leftEye: [.zero, CGPoint(x: CGFloat.infinity, y: 0), CGPoint(x: 0, y: 1)]])
        for provider: any FaceLandmarkDetecting<ProcessingImage> in [
            MockFaceLandmarkDetector<ProcessingImage>(landmarks: []),
            MockFaceLandmarkDetector<ProcessingImage>(landmarks: [FacialLandmarks(region: region, features: [:])]),
            MockFaceLandmarkDetector<ProcessingImage>(landmarks: [invalid]), FailingProvider(calls: calls)
        ] {
            let output = try await process(input, regions: [region], provider: provider, configuration: configuration)
            XCTAssertEqual(ProcessingTestPixels.rgba(output), ProcessingTestPixels.rgba(baseline))
        }
        XCTAssertEqual(calls.value, 1)
        let patch = CGRect(x: 72, y: 112, width: 22, height: 32)
        XCTAssertLessThan(SkinRetouchTestImage.variance(SkinRetouchTestImage.values(baseline, in: patch)),
                          SkinRetouchTestImage.variance(SkinRetouchTestImage.values(input, in: patch)))
    }

    func testProviderIsCalledOncePerPhotoAndPartialMultiFaceLandmarksKeepOtherFaceProcessing() async throws {
        let input = try SkinRetouchTestImage.texture()
        let a = try FaceRegion(boundingBox: CGRect(x: 0.05, y: 0.25, width: 0.3, height: 0.5))
        let b = try FaceRegion(boundingBox: CGRect(x: 0.65, y: 0.25, width: 0.3, height: 0.5))
        let partial = try MockFaceLandmarkDetector<ProcessingImage>().detectLandmarks(in: input, regions: [b])
        let provider = MockFaceLandmarkDetector<ProcessingImage>(landmarks: partial)
        let configuration = SkinRetouchConfiguration.naturalDefault.withIntensity(try SkinRetouchIntensity(1))
        let output = try await process(input, regions: [a, b], provider: provider, configuration: configuration)
        let reverse = try await process(input, regions: [b, a, b], provider: provider, configuration: configuration)
        let baseline = try await process(input, regions: [a, b], provider: nil, configuration: configuration)
        XCTAssertEqual(ProcessingTestPixels.rgba(output), ProcessingTestPixels.rgba(reverse))
        let patch = CGRect(x: 42, y: 112, width: 20, height: 32)
        XCTAssertEqual(SkinRetouchTestImage.values(output, in: patch), SkinRetouchTestImage.values(baseline, in: patch))
        XCTAssertLessThan(SkinRetouchTestImage.variance(SkinRetouchTestImage.values(output, in: patch)),
                          SkinRetouchTestImage.variance(SkinRetouchTestImage.values(input, in: patch)))
        let calls = CallCount()
        _ = try await process(input, regions: [a, b], provider: FailingProvider(calls: calls))
        XCTAssertEqual(calls.value, 1, "Detection is per photo, not per feature/face")
    }

    func testSyntheticEyesBrowsAndLipTextureChangeLessThanNoisySkinWithAndWithoutEdges() async throws {
        let input = try SkinRetouchTestImage.make { x, y in
            var seed = UInt32(x + y * 256 + 1) &* 747796405 &+ 2891336453
            seed = ((seed >> ((seed >> 28) + 4)) ^ seed) &* 277803737
            let gray = UInt8(150 + Int(((seed >> 22) ^ seed) % 21) - 10)
            return [gray, gray, gray, 255]
        }
        let region = try fullFace()
        let landmarks = try MockFaceLandmarkDetector<ProcessingImage>().detectLandmarks(in: input, regions: [region])
        try await Task.detached {
            let noise = CIImage(cgImage: input.cgImage)
            let eyePatches = [CGRect(x: 70, y: 162, width: 12, height: 3), CGRect(x: 174, y: 162, width: 12, height: 3)]
            let browPatches = [CGRect(x: 64, y: 199, width: 12, height: 3), CGRect(x: 180, y: 199, width: 12, height: 3)]
            let lip = CGRect(x: 118, y: 72, width: 20, height: 10)
            let dark = try CoreImageRendering.filter("CIColorMatrix", parameters: [
                kCIInputImageKey: noise,
                "inputBiasVector": CIVector(x: -0.15, y: -0.15, z: -0.15, w: 0)
            ], in: noise.extent)
            let red = try CoreImageRendering.filter("CIColorMatrix", parameters: [
                kCIInputImageKey: noise,
                "inputBiasVector": CIVector(x: 0.1, y: -0.12, z: -0.10, w: 0)
            ], in: noise.extent)
            var source = red.cropped(to: lip).composited(over: noise)
            for patch in eyePatches + browPatches { source = dark.cropped(to: patch).composited(over: source) }
            let skin = CGRect(x: 59, y: 108, width: 24, height: 24)
            func values(_ image: CIImage, _ rect: CGRect) -> [Double] {
                ProcessingTestPixels.floats(image, bounds: rect).enumerated().compactMap { i, value in
                    i % 4 == 3 ? nil : Double(value)
                }
            }
            func delta(_ output: CIImage, _ rect: CGRect) -> Double {
                SkinRetouchTestImage.mean(zip(values(output, rect), values(source, rect)).map { abs($0 - $1) })
            }
            // Edge strength 0 isolates the semantic contribution. Strength 1 tests
            // the actual two-layer combination; all frequency parameters stay default.
            for edgeStrength in [0.0, 1.0] {
                let configuration = try SkinRetouchConfiguration(intensity: SkinRetouchIntensity(1), edgeProtectionStrength: edgeStrength)
                let step = TexturePreservingSkinSmoothingStep(configuration: configuration)
                let output = try XCTUnwrap(step.makeOutput(source: source, regions: [region], landmarks: landmarks))
                let baseline = try XCTUnwrap(step.makeOutput(source: source, regions: [region]))
                let skinDelta = delta(output, skin)
                XCTAssertGreaterThan(skinDelta, 0.000001, "Skin must still receive smoothing")
                XCTAssertLessThan(SkinRetouchTestImage.variance(values(output, skin)), SkinRetouchTestImage.variance(values(source, skin)))
                for patch in eyePatches + browPatches + [lip] {
                    XCTAssertLessThan(delta(output, patch), skinDelta * 0.35, "Features must retain texture and color")
                    if edgeStrength == 0 {
                        XCTAssertLessThan(delta(output, patch), delta(baseline, patch) * 0.35,
                                          "Semantic protection must add value beyond the old path")
                    }
                }
            }
        }.value
    }
}
#endif
