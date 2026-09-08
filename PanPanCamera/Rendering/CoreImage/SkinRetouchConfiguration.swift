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
    enum ValidationError: Error { case detailRetention, noiseReductionStrength, edgeProtectionStrength }

    let intensity: SkinRetouchIntensity
    let detailRetention: Double
    let noiseReductionStrength: Double
    let edgeProtectionStrength: Double

    init(intensity: SkinRetouchIntensity = .natural, detailRetention: Double = 0.9,
         noiseReductionStrength: Double = 0.015, edgeProtectionStrength: Double = 1) throws {
        guard detailRetention.isFinite, (0...1).contains(detailRetention) else {
            throw ValidationError.detailRetention
        }
        guard noiseReductionStrength.isFinite, (0...Policy.maximumNoiseLevel).contains(noiseReductionStrength) else {
            throw ValidationError.noiseReductionStrength
        }
        guard edgeProtectionStrength.isFinite, (0...1).contains(edgeProtectionStrength) else {
            throw ValidationError.edgeProtectionStrength
        }
        self.intensity = intensity
        self.detailRetention = detailRetention
        self.noiseReductionStrength = noiseReductionStrength
        self.edgeProtectionStrength = edgeProtectionStrength
    }

    // Engineering starting point only; has not passed real-photo visual acceptance.
    static let naturalDefault = try! Self()

    func withIntensity(_ intensity: SkinRetouchIntensity) -> Self {
        // All other stored values have already passed the throwing initializer.
        try! Self(intensity: intensity, detailRetention: detailRetention,
                  noiseReductionStrength: noiseReductionStrength, edgeProtectionStrength: edgeProtectionStrength)
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
        static let edgeGain = 4.0
        static let maximumChannelChange = 0.02
        static let opaqueThreshold = 0.9999
    }
}

/// A single decomposition for the union of all faces. The smallest usable face
/// determines scale: larger faces receive conservative treatment in a mixed-size
/// group, while a large face cannot over-smooth a small one. Order/duplicates do not
/// change scale, and subpixel boxes are ignored exactly as in SoftFaceMaskGenerator.
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
