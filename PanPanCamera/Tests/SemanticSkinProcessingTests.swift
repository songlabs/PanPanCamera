#if DEBUG
import CoreImage
import Foundation
import XCTest
@testable import PanPanCamera

final class SemanticSkinProcessingTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(FaceRegion, FaceRegion?)] = []
        func record(_ region: FaceRegion, _ landmarks: FacialLandmarks?) {
            lock.lock(); defer { lock.unlock() }; stored.append((region, landmarks?.region))
        }
        var values: [(FaceRegion, FaceRegion?)] { lock.lock(); defer { lock.unlock() }; return stored }
    }
    private final class Failure: Error, @unchecked Sendable {}
    private struct Probe: SkinMaskProviding {
        let calls: Calls
        var failure: Failure? = nil
        var wrongRegion: FaceRegion? = nil
        func skinMask(in image: ProcessingImage, region: FaceRegion, landmarks: FacialLandmarks?) throws -> SkinMaskResult {
            calls.record(region, landmarks)
            if let failure { throw failure }
            if let wrongRegion {
                let extent = CGRect(x: 0, y: 0, width: CGFloat(image.cgImage.width), height: CGFloat(image.cgImage.height))
                return try SkinMaskResult(region: wrongRegion, mask: SemanticMaskTestPixels.constant(0, in: extent), in: extent)
            }
            return .unavailable(for: region)
        }
    }
    private func process(_ image: ProcessingImage, regions: [FaceRegion], provider: (any SkinMaskProviding)?,
                         configuration: SkinRetouchConfiguration = .naturalDefault) async throws -> ProcessingImage {
        let pipeline = ImageProcessingPipeline<ProcessingImage>(detector: MockFaceDetector(regions: regions), steps: [
            TexturePreservingSkinSmoothingStep(configuration: configuration,
                landmarkDetector: MockFaceLandmarkDetector<ProcessingImage>(), skinMaskProvider: provider)
        ])
        return try await pipeline.process(image).image
    }

    func testZeroIntensityAndEmptyFacesReturnExactInputWithoutCallingSemanticProvider() async throws {
        let input = try SkinRetouchTestImage.texture(), region = try SemanticMaskTestPixels.fullFace(), calls = Calls()
        let provider = Probe(calls: calls, failure: Failure())
        let zero = try await process(input, regions: [region], provider: provider, configuration: .naturalDefault.withIntensity(.original))
        let empty = try await process(input, regions: [], provider: provider)
        XCTAssertTrue(zero.cgImage === input.cgImage)
        XCTAssertTrue(empty.cgImage === input.cgImage)
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testUnavailableProviderMatchesNoProviderAndStillSmoothsUnprotectedSkin() async throws {
        let input = try SkinRetouchTestImage.texture(), region = try SemanticMaskTestPixels.fullFace()
        let configuration = SkinRetouchConfiguration.naturalDefault.withIntensity(try SkinRetouchIntensity(1))
        let baseline = try await process(input, regions: [region], provider: nil, configuration: configuration)
        let result = try await process(input, regions: [region],
            provider: MockSkinMaskProvider(configuration: .init(mode: .unavailable)), configuration: configuration)
        XCTAssertEqual(ProcessingTestPixels.rgba(result), ProcessingTestPixels.rgba(baseline))
        let patch = CGRect(x: 60, y: 106, width: 24, height: 24)
        XCTAssertLessThan(SkinRetouchTestImage.variance(SkinRetouchTestImage.values(result, in: patch)),
                          SkinRetouchTestImage.variance(SkinRetouchTestImage.values(input, in: patch)))
    }

    func testProviderReceivesMatchingLandmarksOncePerUniqueFaceWithPartialReorderedResults() async throws {
        let input = try SkinRetouchTestImage.texture(), calls = Calls()
        let a = try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 0.4, height: 1))
        let b = try FaceRegion(boundingBox: CGRect(x: 0.6, y: 0, width: 0.4, height: 1))
        let landmarks = try MockFaceLandmarkDetector<ProcessingImage>().detectLandmarks(in: input, regions: [b])
        let pipeline = ImageProcessingPipeline<ProcessingImage>(detector: MockFaceDetector(regions: [a, b, a]), steps: [
            TexturePreservingSkinSmoothingStep(landmarkDetector: MockFaceLandmarkDetector<ProcessingImage>(landmarks: landmarks),
                skinMaskProvider: Probe(calls: calls))
        ])
        _ = try await pipeline.process(input)
        XCTAssertEqual(calls.values.count, 2)
        XCTAssertEqual(calls.values[0].0, a)
        XCTAssertNil(calls.values[0].1)
        XCTAssertEqual(calls.values[1].0, b)
        XCTAssertEqual(calls.values[1].1, b)
    }

    func testMislabeledProviderResultCannotBlockAnotherFace() async throws {
        let input = try SkinRetouchTestImage.texture()
        let a = try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 0.4, height: 1))
        let b = try FaceRegion(boundingBox: CGRect(x: 0.6, y: 0, width: 0.4, height: 1))
        let baseline = try await process(input, regions: [a], provider: nil)
        let result = try await process(input, regions: [a], provider: Probe(calls: Calls(), wrongRegion: b))
        XCTAssertEqual(ProcessingTestPixels.rgba(result), ProcessingTestPixels.rgba(baseline))
    }

    func testActualSemanticProcessingErrorPropagatesAndPipelineAdmissionRecovers() async throws {
        let input = try SkinRetouchTestImage.texture(), region = try SemanticMaskTestPixels.fullFace(), failure = Failure()
        let calls = Calls()
        let pipeline = ImageProcessingPipeline<ProcessingImage>(detector: MockFaceDetector(regions: [region]), steps: [
            TexturePreservingSkinSmoothingStep(skinMaskProvider: Probe(calls: calls, failure: failure))
        ])
        for _ in 0..<2 {
            do { _ = try await pipeline.process(input); XCTFail("Processing failure must propagate") }
            catch { XCTAssertTrue((error as? Failure) === failure) }
        }
        XCTAssertEqual(calls.values.count, 2, "The second job was admitted after the first failed")
    }

    func testSemanticMaskUsesSameNonzeroExtentForActualReconstructionAndPreservesAlpha() async throws {
        let input = try SkinRetouchTestImage.texture(), region = try SemanticMaskTestPixels.fullFace()
        try await Task.detached {
            let source = CIImage(cgImage: input.cgImage).transformed(by: CGAffineTransform(translationX: 13, y: -7))
            let provider = MockSkinMaskProvider(configuration: try .init(mode: .hairExclusion))
            let semantic = try provider.makeMask(region: region, in: source.extent)
            let step = TexturePreservingSkinSmoothingStep()
            let output = try XCTUnwrap(step.makeOutput(source: source, regions: [region], skinMasks: [semantic]))
            XCTAssertEqual(output.extent, source.extent)
            let hair = CGRect(x: 13 + 116, y: -7 + 203, width: 10, height: 8)
            let originalHair = ProcessingTestPixels.floats(source, bounds: hair), outputHair = ProcessingTestPixels.floats(output, bounds: hair)
            for i in originalHair.indices { XCTAssertEqual(originalHair[i], outputHair[i], accuracy: 0.0001) }
        }.value
        for alpha: UInt8 in [0, 64, 128, 255] {
            let transparent = try ProcessingTestPixels.image(alpha: alpha)
            let output = try await process(transparent, regions: [region], provider: MockSkinMaskProvider())
            let pixels = ProcessingTestPixels.rgba(output)
            XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == alpha })
        }
    }
}
#endif
