#if DEBUG
import CoreImage
import Foundation
import XCTest
@testable import PanPanCamera

final class NaturalSkinRetouchStepsTests: XCTestCase {
    private func run(_ input: ProcessingImage, steps: [any ImageProcessingStep<ProcessingImage>],
                     regions: [FaceRegion]? = nil) async throws -> ProcessingImage {
        let pipeline = try ImageProcessingPipeline<ProcessingImage>(
            detector: MockFaceDetector(regions: regions ?? [SkinToneTestPixels.face()]), steps: steps)
        return try await pipeline.process(input).image
    }

    func testTextureOnlyMatchesIndependentTextureStep() async throws {
        let input = try SkinRetouchTestImage.texture()
        let actual = try await run(input, steps: NaturalSkinRetouchSteps.make(components: .textureOnly))
        let expected = try await run(input, steps: [TexturePreservingSkinSmoothingStep()])
        XCTAssertEqual(ProcessingTestPixels.rgba(actual), ProcessingTestPixels.rgba(expected))
    }

    func testToneOnlyMatchesIndependentToneStep() async throws {
        let input = try SkinRetouchTestImage.texture()
        let actual = try await run(input, steps: NaturalSkinRetouchSteps.make(components: .toneOnly))
        let expected = try await run(input, steps: [NaturalSkinToneAdjustmentStep()])
        XCTAssertEqual(ProcessingTestPixels.rgba(actual), ProcessingTestPixels.rgba(expected))
    }

    func testCombinedMatchesExplicitTextureThenToneWithSharedConfiguration() async throws {
        let input = try SkinRetouchTestImage.texture()
        let config = try SkinToneTestPixels.configuration()
        let provider = MockSkinMaskProvider()
        let actual = try await run(input, steps: NaturalSkinRetouchSteps.make(configuration: config,
            landmarkDetector: MockFaceLandmarkDetector<ProcessingImage>(), skinMaskProvider: provider))
        let expected = try await run(input, steps: [
            TexturePreservingSkinSmoothingStep(configuration: config,
                landmarkDetector: MockFaceLandmarkDetector<ProcessingImage>(), skinMaskProvider: provider),
            NaturalSkinToneAdjustmentStep(configuration: config,
                landmarkDetector: MockFaceLandmarkDetector<ProcessingImage>(), skinMaskProvider: provider)
        ])
        XCTAssertEqual(ProcessingTestPixels.rgba(actual), ProcessingTestPixels.rgba(expected))
    }

    func testFactoryHasFixedStepOrderAndOmitsDisabledTone() throws {
        let steps = NaturalSkinRetouchSteps.make()
        XCTAssertEqual(steps.count, 2)
        XCTAssertTrue(steps.first is TexturePreservingSkinSmoothingStep)
        XCTAssertTrue(steps.last is NaturalSkinToneAdjustmentStep)
        let texture = NaturalSkinRetouchSteps.make(components: .textureOnly)
        let tone = NaturalSkinRetouchSteps.make(components: .toneOnly)
        XCTAssertEqual(texture.count, 1)
        XCTAssertEqual(tone.count, 1)
        XCTAssertTrue(texture.first is TexturePreservingSkinSmoothingStep)
        XCTAssertTrue(tone.first is NaturalSkinToneAdjustmentStep)
        let config = try SkinRetouchConfiguration(toneConsistencyStrength: 0)
        XCTAssertEqual(NaturalSkinRetouchSteps.make(configuration: config).count, 1)
        XCTAssertTrue(NaturalSkinRetouchSteps.make(configuration: config, components: .toneOnly).isEmpty)
    }

    func testOriginalProcessingErrorsPropagateAndPipelineAdmissionRecovers() async throws {
        let input = try SkinRetouchTestImage.texture(), failure = SkinToneTestPixels.Failure()
        for components: NaturalSkinRetouchSteps.Components in [.textureOnly, .toneOnly, .combined] {
            let pipeline = try ImageProcessingPipeline<ProcessingImage>(
                detector: MockFaceDetector(regions: [SkinToneTestPixels.face()]),
                steps: NaturalSkinRetouchSteps.make(components: components,
                    maskGenerator: SkinToneTestPixels.FailingMask(failure: failure)))
            for _ in 0..<2 {
                do { _ = try await pipeline.process(input); XCTFail("Expected original processing error") }
                catch { XCTAssertTrue((error as? SkinToneTestPixels.Failure) === failure) }
            }
        }
    }

    func testZeroIntensityOmitsAllComponentsAndPreservesOriginalCGImage() async throws {
        let input = try SkinRetouchTestImage.texture()
        for components: NaturalSkinRetouchSteps.Components in [.textureOnly, .toneOnly, .combined] {
            let steps = NaturalSkinRetouchSteps.make(configuration: .original, components: components,
                maskGenerator: SkinToneTestPixels.FailingMask(failure: .init()))
            XCTAssertTrue(steps.isEmpty)
            let output = try await run(input, steps: steps)
            XCTAssertTrue(output.cgImage === input.cgImage)
        }
    }

    func testNoFacesBypassBothComponentsBeforeAnyMaskWork() async throws {
        let input = try SkinRetouchTestImage.texture()
        let output = try await run(input, steps: NaturalSkinRetouchSteps.make(
            maskGenerator: SkinToneTestPixels.FailingMask(failure: .init())), regions: [])
        XCTAssertTrue(output.cgImage === input.cgImage)
    }
}
#endif
