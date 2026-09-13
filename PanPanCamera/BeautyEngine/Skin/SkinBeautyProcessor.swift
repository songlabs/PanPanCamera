import CoreImage
import Foundation

enum BeautyEffectAmplitude {
    static let brightening = 0.06
    static let previewSmoothingDetailRetention = 0.88
    static let finalSmoothingDetailRetention = 0.80
    static let previewToneConsistency = 0.40
    static let finalToneConsistency = 0.50
}

struct SkinBeautyProcessor {
    func process(_ source: CIImage, faces: [AnalyzedFace], foundation result: SkinMaskResult?, configuration: BeautyConfiguration,
                 quality: BeautyProcessingQuality) throws -> CIImage {
        guard !configuration.isSkinBypassed,
              let result
        else { return source }
        let foundation = result.mask
        let supported = faces.filter { result.instances[$0.trackingID] != nil }
        let regions = supported.compactMap {
            try? FaceRegion(boundingBox: $0.boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)))
        }
        var image = source
        func mask(_ strength: Double) throws -> CIImage {
            try CoreImageRendering.grayMask(foundation, scale: strength)
        }
        if configuration.effectiveSmoothing > 0 {
            let config = try skinConfiguration(intensity: configuration.effectiveSmoothing,
                detailRetention: quality == .preview ? BeautyEffectAmplitude.previewSmoothingDetailRetention
                    : BeautyEffectAmplitude.finalSmoothingDetailRetention,
                noiseReduction: quality == .preview ? 0.006 : 0.015)
            image = try TexturePreservingSkinSmoothingStep(configuration: config).makeOutput(
                source: image, regions: regions, effectiveMask: mask(configuration.effectiveSmoothing)) ?? image
        }
        if configuration.effectiveBrightening > 0 {
            let adjusted = try CoreImageRendering.filter("CIColorControls", parameters: [
                kCIInputImageKey: image, kCIInputBrightnessKey: BeautyEffectAmplitude.brightening,
                kCIInputSaturationKey: 1.0, kCIInputContrastKey: 1.0
            ], in: image.extent)
            image = try CoreImageRendering.blend(adjusted, over: image, mask: mask(configuration.effectiveBrightening))
        }
        if configuration.effectiveTone > 0 {
            let config = try skinConfiguration(intensity: configuration.effectiveTone,
                toneStrength: quality == .preview ? BeautyEffectAmplitude.previewToneConsistency
                    : BeautyEffectAmplitude.finalToneConsistency,
                luminanceCorrection: quality == .preview ? 0.004 : 0.006)
            image = try NaturalSkinToneAdjustmentStep(configuration: config).makeOutput(
                source: image, regions: regions, effectiveSkinMask: mask(configuration.effectiveTone)) ?? image
        }
        if configuration.effectiveBlemish > 0 {
            image = try BlemishAttenuationStep().makeOutput(source: image, regions: regions,
                landmarks: supported.map(\.landmarks), effectiveSkinMask: foundation,
                strength: configuration.effectiveBlemish, quality: quality) ?? image
        }
        if configuration.effectiveDarkCircles > 0 {
            // Reuse each face's already-built mask; never reclassify adjusted pixels.
            for face in supported where face.landmarks.isAvailable {
                guard let mask = result.instances[face.trackingID] else { continue }
                image = try DarkCircleCorrectionStep().makeOutput(source: image, regions: regions,
                    landmarks: [face.landmarks], effectiveSkinMask: mask,
                    strength: configuration.effectiveDarkCircles, quality: quality) ?? image
            }
        }
        return image
    }

    private func skinConfiguration(intensity: Double, detailRetention: Double = 0.94,
                                   noiseReduction: Double = 0, toneStrength: Double = 0,
                                   luminanceCorrection: Double = 0) throws -> SkinRetouchConfiguration {
        try SkinRetouchConfiguration(intensity: SkinRetouchIntensity(intensity),
            detailRetention: detailRetention, noiseReductionStrength: noiseReduction,
            edgeProtectionStrength: 1, toneConsistencyStrength: toneStrength,
            maxLuminanceCorrection: luminanceCorrection)
    }
}
