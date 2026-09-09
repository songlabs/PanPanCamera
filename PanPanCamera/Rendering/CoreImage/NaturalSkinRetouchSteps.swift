/// The single composition entry for Natural Skin Retouch. The existing pipeline
/// owns loading, detection, execution order, worker, admission and error propagation.
/// No second executor, task, queue or mutable job state is introduced here.
enum NaturalSkinRetouchSteps {
    enum Components: Sendable { case textureOnly, toneOnly, combined }

    static func make(configuration: SkinRetouchConfiguration = .naturalDefault,
                     components: Components = .combined,
                     maskGenerator: any FaceMaskGenerating = SoftFaceMaskGenerator(),
                     landmarkDetector: (any FaceLandmarkDetecting<ProcessingImage>)? = nil,
                     skinMaskProvider: (any SkinMaskProviding)? = nil) -> [any ImageProcessingStep<ProcessingImage>] {
        guard configuration.intensity.value > 0 else { return [] }
        var steps: [any ImageProcessingStep<ProcessingImage>] = []
        if components != .toneOnly {
            steps.append(TexturePreservingSkinSmoothingStep(configuration: configuration,
                maskGenerator: maskGenerator, landmarkDetector: landmarkDetector, skinMaskProvider: skinMaskProvider))
        }
        if components != .textureOnly, configuration.toneConsistencyStrength > 0,
           configuration.maxLuminanceCorrection > 0 {
            steps.append(NaturalSkinToneAdjustmentStep(configuration: configuration,
                maskGenerator: maskGenerator, landmarkDetector: landmarkDetector, skinMaskProvider: skinMaskProvider))
        }
        return steps
    }
}
