import Foundation

/// Reject invalid values at construction; zero is an exact bypass, one is the
/// bounded v1 algorithm's maximum, not an unlimited smoothing setting.
struct SkinRetouchIntensity: Equatable, Sendable {
    enum ValidationError: Error { case outOfRange }
    let value: Double

    init(_ value: Double) throws {
        guard value.isFinite, (0...1).contains(value) else { throw ValidationError.outOfRange }
        self.value = value
    }

    private init(validated value: Double) { self.value = value }
    static let original = Self(validated: 0)
    static let natural = Self(validated: 0.25)
    static let stronger = Self(validated: 0.5)
}

struct SkinRetouchConfiguration: Equatable, Sendable {
    enum ValidationError: Error {
        case detailRetention, noiseReductionStrength, edgeProtectionStrength
        case toneConsistencyStrength, maxLuminanceCorrection
    }

    let intensity: SkinRetouchIntensity
    let detailRetention: Double
    let noiseReductionStrength: Double
    let edgeProtectionStrength: Double
    let toneConsistencyStrength: Double
    /// Absolute linear working-space luminance delta, before mask/strength attenuation.
    let maxLuminanceCorrection: Double

    init(intensity: SkinRetouchIntensity = .natural, detailRetention: Double = 0.9,
         noiseReductionStrength: Double = 0.015, edgeProtectionStrength: Double = 1,
         toneConsistencyStrength: Double = 0.25, maxLuminanceCorrection: Double = 0.006) throws {
        guard detailRetention.isFinite, (0...1).contains(detailRetention) else {
            throw ValidationError.detailRetention
        }
        guard noiseReductionStrength.isFinite, (0...Policy.maximumNoiseLevel).contains(noiseReductionStrength) else {
            throw ValidationError.noiseReductionStrength
        }
        guard edgeProtectionStrength.isFinite, (0...1).contains(edgeProtectionStrength) else {
            throw ValidationError.edgeProtectionStrength
        }
        guard toneConsistencyStrength.isFinite, (0...1).contains(toneConsistencyStrength) else {
            throw ValidationError.toneConsistencyStrength
        }
        guard maxLuminanceCorrection.isFinite,
              (0...TonePolicy.maximumLuminanceCorrection).contains(maxLuminanceCorrection) else {
            throw ValidationError.maxLuminanceCorrection
        }
        self.intensity = intensity
        self.detailRetention = detailRetention
        self.noiseReductionStrength = noiseReductionStrength
        self.edgeProtectionStrength = edgeProtectionStrength
        self.toneConsistencyStrength = toneConsistencyStrength
        self.maxLuminanceCorrection = maxLuminanceCorrection
    }

    // Engineering starting point only; has not passed real-photo visual acceptance.
    static let naturalDefault = try! Self()
    static let original = naturalDefault.withIntensity(.original)
    #if DEBUG
    static let strongerDebug = naturalDefault.withIntensity(.stronger)
    #endif

    func withIntensity(_ intensity: SkinRetouchIntensity) -> Self {
        // All other stored values have already passed the throwing initializer.
        try! Self(intensity: intensity, detailRetention: detailRetention,
                  noiseReductionStrength: noiseReductionStrength, edgeProtectionStrength: edgeProtectionStrength,
                  toneConsistencyStrength: toneConsistencyStrength, maxLuminanceCorrection: maxLuminanceCorrection)
    }

    /// Linear sRGB luminance policy. No fixed skin color or chroma target.
    enum TonePolicy {
        static let luminanceRed = 0.2126
        static let luminanceGreen = 0.7152
        static let luminanceBlue = 0.0722
        static let radiusFraction = 0.025
        static let minimumRadius = 4.0
        static let maximumRadius = 32.0
        static let referenceMultiplier = 3.0
        static let maximumDeviationSuppression = 0.2
        static let maximumLuminanceCorrection = 0.012
        static let smallDeviation = 0.015
        static let lightingDeviation = 0.06
        static let shadowStop = 0.015
        static let shadowFullWeight = 0.06
        static let highlightFullWeight = 0.65
        static let highlightStop = 0.9
        static let minimumSupport = 0.05
        static let fullSupport = 0.25
        static let opaqueThreshold = 0.9999
        static let minimumArithmeticDivisor = 0.000001
    }

    /// Fixed v1 safety/scale policy, not a collection of unused future tuning knobs.
    enum Policy {
        static let maximumNoiseLevel = 0.03
        static let noiseSharpness = 0.0
        static let radiusFraction = 0.003
        static let minimumRadius = 0.6
        static let maximumRadius = 3.0
        static let largeScaleMultiplier = 3.0
        static let midFrequencyAttenuation = 0.5
        static let edgeIntensity = 1.0
        // CIEdges peaks below one for narrow synthetic lines and small spots.
        // Saturate those confirmed detail boundaries while leaving low-level
        // skin texture near zero for the later user-strength multiplication.
        static let edgeGain = 8.0
        static let maximumChannelChange = 0.02
        static let opaqueThreshold = 0.9999
    }
}

/// One low-frequency scale for the union, independently of face order/duplicates.
/// This is separate from the existing texture frequency policy.
struct SkinToneScale: Equatable, Sendable {
    let localRadius: Double
    var referenceRadius: Double { localRadius * SkinRetouchConfiguration.TonePolicy.referenceMultiplier }

    init?(regions: [FaceRegion], in extent: CGRect) {
        let sides = regions.compactMap { region -> Double? in
            let rect = region.imageRect(in: extent)
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
            return Double(min(rect.width, rect.height))
        }
        guard let side = sides.min() else { return nil }
        let policy = SkinRetouchConfiguration.TonePolicy.self
        localRadius = min(policy.maximumRadius, max(policy.minimumRadius, side * policy.radiusFraction))
    }
}

/// A single decomposition for the union of all faces. The smallest usable face
/// determines scale: larger faces receive conservative treatment in a mixed-size
/// group, while a large face cannot over-smooth a small one. Order/duplicates do not
/// change scale, and subpixel boxes are ignored exactly as in the rendering scale policy.
struct SkinRetouchScale: Equatable, Sendable {
    let smallRadius: Double
    var largeRadius: Double { smallRadius * SkinRetouchConfiguration.Policy.largeScaleMultiplier }

    init?(regions: [FaceRegion], in extent: CGRect) {
        let shortSides = regions.compactMap { region -> Double? in
            let rect = region.imageRect(in: extent)
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
            return Double(min(rect.width, rect.height))
        }
        guard let shortSide = shortSides.min() else { return nil }
        let policy = SkinRetouchConfiguration.Policy.self
        smallRadius = min(policy.maximumRadius, max(policy.minimumRadius, shortSide * policy.radiusFraction))
    }
}
