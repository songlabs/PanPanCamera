import CoreImage
import Foundation

/// A single color recipe shared by Preview and Capture. These are conservative
/// product bounds, not a claim of photographic calibration or device acceptance.
/// Identity controls are saturation/contrast 1 and brightness 0. The maximum
/// departures are 4% for color/contrast, 2% linear brightness, and 3% channel gain.
struct FilterEffectRecipe: Equatable, Sendable {
    enum Bounds {
        static let colorContrastDelta = 0.04
        static let brightnessLift = 0.02
        static let temperatureGainDelta = 0.03
    }

    let saturation: Double
    let brightness: Double
    let contrast: Double
    let temperature: Double

    static func recipe(for preset: FilterPreset) -> Self {
        switch preset {
        case .original:
            return Self(saturation: 1, brightness: 0, contrast: 1, temperature: 0)
        case .natural:
            // Half the color/contrast allowance and a quarter of the light lift.
            return Self(saturation: 1 + Bounds.colorContrastDelta / 2,
                        brightness: Bounds.brightnessLift / 4,
                        contrast: 1 + Bounds.colorContrastDelta / 2, temperature: 0)
        case .clear:
            // Lift the image while slightly easing contrast and strong chroma.
            return Self(saturation: 1 - Bounds.colorContrastDelta,
                        brightness: Bounds.brightnessLift,
                        contrast: 1 - Bounds.colorContrastDelta / 2, temperature: 0)
        case .warm:
            return Self(saturation: 1, brightness: 0, contrast: 1, temperature: 1)
        case .cool:
            return Self(saturation: 1, brightness: 0, contrast: 1, temperature: -1)
        }
    }

    var channelGains: (red: Double, green: Double, blue: Double) {
        let delta = temperature * Bounds.temperatureGainDelta
        let luma = SkinRetouchConfiguration.TonePolicy.self
        // Equal/opposite red-blue gains keep black neutral. Compensate green
        // using the existing linear-sRGB luminance policy so a neutral patch's
        // luminance stays fixed; no yellow/blue additive offset lifts shadows.
        let greenCompensation = delta * (luma.luminanceRed - luma.luminanceBlue) / luma.luminanceGreen
        return (1 + delta, 1 - greenCompensation, 1 - delta)
    }
}

/// Global, face-independent, pointwise adjustment: no image readback, spatial
/// blur, new context, detector, or mutable filter shared across concurrent jobs.
struct FilterProcessingStep: Sendable {
    enum Failure: Error { case invalidExtent }

    func makeOutput(source: CIImage, configuration: FilterConfiguration) throws -> CIImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        // Preserve the input object/pixels exactly, without a color-space roundtrip.
        guard !configuration.isBypassed else { return nil }
        guard !source.extent.isEmpty, !source.extent.isInfinite, !source.extent.isNull else {
            throw Failure.invalidExtent
        }

        let recipe = FilterEffectRecipe.recipe(for: configuration.preset)
        var adjusted = source
        if recipe.saturation != 1 || recipe.brightness != 0 || recipe.contrast != 1 {
            adjusted = try CoreImageRendering.filter("CIColorControls", parameters: [
                kCIInputImageKey: adjusted,
                kCIInputSaturationKey: recipe.saturation,
                kCIInputBrightnessKey: recipe.brightness,
                kCIInputContrastKey: recipe.contrast
            ], in: source.extent)
        }
        if recipe.temperature != 0 {
            let gains = recipe.channelGains
            adjusted = try CoreImageRendering.filter("CIColorMatrix", parameters: [
                kCIInputImageKey: adjusted,
                "inputRVector": CIVector(x: CGFloat(gains.red), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(gains.green), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(gains.blue), w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ], in: source.extent)
        }
        guard configuration.intensity < 1 else { return adjusted }
        // Construct the weight in working space, avoiding an sRGB 0.5 color
        // becoming a ~0.214 linear mask. Both color branches retain source alpha.
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: source.extent)
        let mask = try CoreImageRendering.grayMask(white, scale: configuration.intensity)
        return try CoreImageRendering.blend(adjusted, over: source, mask: mask)
    }
}
