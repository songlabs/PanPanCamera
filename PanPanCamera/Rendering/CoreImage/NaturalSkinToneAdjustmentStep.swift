import CoreImage
import Foundation

/// Bounded low-frequency luminance consistency, with no texture reconstruction,
/// chroma target, exposure bias or geometry operation. Device validation pending.
struct NaturalSkinToneAdjustmentStep: ImageProcessingStep {
    let configuration: SkinRetouchConfiguration
    private let landmarkDetector: (any FaceLandmarkDetecting<ProcessingImage>)?
    // The existing step hosts the shared provider/mask preparation helpers. Reuse
    // those unchanged helpers only; never invoke smoothing from this component.
    private let maskComponents: TexturePreservingSkinSmoothingStep

    init(configuration: SkinRetouchConfiguration = .naturalDefault,
         maskGenerator: any FaceMaskGenerating = SoftFaceMaskGenerator(),
         landmarkDetector: (any FaceLandmarkDetecting<ProcessingImage>)? = nil,
         skinMaskProvider: (any SkinMaskProviding)? = nil) {
        self.configuration = configuration
        self.landmarkDetector = landmarkDetector
        maskComponents = TexturePreservingSkinSmoothingStep(configuration: configuration,
            maskGenerator: maskGenerator, skinMaskProvider: skinMaskProvider)
    }

    func process(_ image: ProcessingImage, regions: [FaceRegion]) throws -> ProcessingImage {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard isEnabled, !regions.isEmpty else { return image }
        let source = CIImage(cgImage: image.cgImage)
        try SkinMaskResult.validate(source.extent)
        guard SkinToneScale(regions: regions, in: source.extent) != nil else { return image }
        // Preserve the established optional-landmark and per-face semantic fallback.
        let landmarks = (try? landmarkDetector?.detectLandmarks(in: image, regions: regions)) ?? []
        let semantics = try maskComponents.skinMasks(in: image, regions: regions, landmarks: landmarks)
        guard let masks = try maskComponents.makeMasks(source: source, regions: regions,
                landmarks: landmarks, skinMasks: semantics),
              let output = try makeOutput(source: source, regions: regions,
                effectiveSkinMask: masks.effectiveSkinMask) else { return image }
        return try CoreImageRendering.render(output, matching: image)
    }

    private var isEnabled: Bool {
        configuration.intensity.value > 0 && configuration.toneConsistencyStrength > 0 &&
            configuration.maxLuminanceCorrection > 0
    }

    /// Receives the existing composer's final mask, INCLUDING total intensity.
    /// Exposed internally for translated-extent and float-precision Apple tests.
    func makeOutput(source: CIImage, regions: [FaceRegion], effectiveSkinMask: CIImage) throws -> CIImage? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard isEnabled, !regions.isEmpty else { return nil }
        let extent = source.extent
        try SkinMaskResult.validate(extent)
        guard effectiveSkinMask.extent == extent else { throw SkinMaskResult.Failure.mismatchedMaskExtent }
        guard let scale = SkinToneScale(regions: regions, in: extent) else { return nil }
        let policy = SkinRetouchConfiguration.TonePolicy.self
        let luminance = try scalar(source, vector: CIVector(x: CGFloat(policy.luminanceRed),
            y: CGFloat(policy.luminanceGreen), z: CGFloat(policy.luminanceBlue), w: 0))
        let opacity = try ramp(alpha(source), from: policy.opaqueThreshold, to: 1)
        // Remove intensity ONLY from statistical support; normalized means must
        // not change their reference when the overall effect strength changes.
        let support = try multiply(CoreImageRendering.grayMask(effectiveSkinMask,
            scale: 1 / max(configuration.intensity.value, policy.minimumArithmeticDivisor)), opacity)
        let alphaMask = try CoreImageRendering.filter("CIMaskToAlpha", parameters: [
            kCIInputImageKey: support
        ], in: extent)
        let weighted = try combine("CISourceInCompositing", luminance, alphaMask)
        let localSamples = try lowPass(weighted, radius: scale.localRadius)
        let referenceSamples = try lowPass(weighted, radius: scale.referenceRadius)
        // Gaussian averages premultiplied (Y*W, W). CIColorMatrix operates on
        // unpremultiplied samples, so forcing alpha=1 gives G(Y*W)/G(W), without
        // a custom division kernel. Insufficient support is suppressed below.
        let local = try scalar(localSamples), reference = try scalar(referenceSamples)
        let supportWeight = try ramp(combine("CIMinimumCompositing",
            alpha(localSamples), alpha(referenceSamples)), from: policy.minimumSupport, to: policy.fullSupport)
        let magnitude = try combine("CIDifferenceBlendMode", reference, local)
        let lightingWeight = try ramp(magnitude, from: policy.lightingDeviation, to: policy.smallDeviation)
        let shadowWeight = try ramp(combine("CIMinimumCompositing", luminance, local),
            from: policy.shadowStop, to: policy.shadowFullWeight)
        let highlightWeight = try ramp(combine("CIMaximumCompositing", luminance, local),
            from: policy.highlightStop, to: policy.highlightFullWeight)

        // Signed deviation lives around 0.5. All averages stay within 0...1 for
        // SDR samples: no absolute difference or subtract blend is used as a sign.
        // E = 0.5 + 0.5*(reference-local); C = clamp(0.2*(reference-local), +/-cap).
        let neutral = try affine(luminance, scale: 0, bias: 0.5)
        let encodedDeviation = try CoreImageRendering.blend(reference,
            over: affine(local, scale: -1, bias: 1), mask: neutral)
        let suppression = policy.maximumDeviationSuppression
        let correction = try clamp(affine(encodedDeviation, scale: 2 * suppression,
            bias: 0.5 - suppression), minimum: 0.5 - configuration.maxLuminanceCorrection,
            maximum: 0.5 + configuration.maxLuminanceCorrection)

        // Ensure a neutral RGB delta cannot clip a single channel and shift chroma.
        // Out-of-SDR/gamut pixels receive weight zero; this is not HDR tone mapping.
        let minimum = try CoreImageRendering.filter("CIMinimumComponent", parameters: [kCIInputImageKey: source], in: extent)
        let maximum = try CoreImageRendering.filter("CIMaximumComponent", parameters: [kCIInputImageKey: source], in: extent)
        let headroom = try combine("CIMinimumCompositing", scalar(minimum), affine(scalar(maximum), scale: -1, bias: 1))
        let gamutWeight = try CoreImageRendering.grayMask(headroom,
            scale: 1 / max(configuration.maxLuminanceCorrection, policy.minimumArithmeticDivisor))
        let bounded = try CoreImageRendering.blend(correction, over: neutral, mask: gamutWeight)
        // 2*(0.5*O + 0.5*(0.5+C)) - 0.5 = O+C. The original pixel, including
        // its high-frequency residual, is retained; neither low-pass is the photo.
        let opaqueSource = try affine(source, scale: 1)
        let candidateRGB = try affine(CoreImageRendering.blend(opaqueSource,
            over: bounded, mask: neutral), scale: 2, bias: -0.5)
        let candidate = try combine("CISourceInCompositing", candidateRGB, source)
        var weight = try CoreImageRendering.grayMask(effectiveSkinMask, scale: configuration.toneConsistencyStrength)
        for protection in [opacity, supportWeight, lightingWeight, shadowWeight, highlightWeight, gamutWeight] {
            weight = try multiply(weight, protection)
        }
        // Exactly one final photo blend for the union of all faces. Candidate and
        // source have the same original alpha; translucency is also gated out.
        return try CoreImageRendering.blend(candidate, over: source, mask: weight)
    }

    private func lowPass(_ image: CIImage, radius: Double) throws -> CIImage {
        try CoreImageRendering.filter("CIGaussianBlur", parameters: [
            kCIInputImageKey: image.clampedToExtent(), kCIInputRadiusKey: radius
        ], in: image.extent)
    }

    private func combine(_ name: String, _ a: CIImage, _ b: CIImage) throws -> CIImage {
        try CoreImageRendering.filter(name, parameters: [
            kCIInputImageKey: a, kCIInputBackgroundImageKey: b
        ], in: a.extent)
    }

    private func multiply(_ a: CIImage, _ b: CIImage) throws -> CIImage {
        try combine("CIMultiplyCompositing", a, b)
    }

    private func scalar(_ image: CIImage, vector: CIVector = CIVector(x: 1, y: 0, z: 0, w: 0)) throws -> CIImage {
        try CoreImageRendering.filter("CIColorMatrix", parameters: [
            kCIInputImageKey: image, "inputRVector": vector, "inputGVector": vector, "inputBVector": vector,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ], in: image.extent)
    }

    private func alpha(_ image: CIImage) throws -> CIImage {
        try scalar(image, vector: CIVector(x: 0, y: 0, z: 0, w: 1))
    }

    /// Opaque RGB arithmetic. Bias is an encoding offset, never a photo tone lift.
    private func affine(_ image: CIImage, scale: Double, bias: Double = 0) throws -> CIImage {
        try CoreImageRendering.filter("CIColorMatrix", parameters: [
            kCIInputImageKey: image,
            "inputRVector": CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(scale), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scale), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: CGFloat(bias), y: CGFloat(bias), z: CGFloat(bias), w: 1)
        ], in: image.extent)
    }

    private func ramp(_ image: CIImage, from start: Double, to end: Double) throws -> CIImage {
        try CoreImageRendering.grayMask(image, scale: 1 / (end - start), bias: -start / (end - start))
    }

    private func clamp(_ image: CIImage, minimum: Double, maximum: Double) throws -> CIImage {
        try CoreImageRendering.filter("CIColorClamp", parameters: [
            kCIInputImageKey: image,
            "inputMinComponents": CIVector(x: CGFloat(minimum), y: CGFloat(minimum), z: CGFloat(minimum), w: 1),
            "inputMaxComponents": CIVector(x: CGFloat(maximum), y: CGFloat(maximum), z: CGFloat(maximum), w: 1)
        ], in: image.extent)
    }
}
