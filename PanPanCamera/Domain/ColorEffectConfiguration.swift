/// Independent normalized controls: skin/reshape batch sliders never scale color effects.
struct MakeupConfiguration: Equatable, Sendable {
    let lip: Double
    let blush: Double
    let eye: Double
    let brow: Double

    init(lip: Double = 0, blush: Double = 0, eye: Double = 0, brow: Double = 0) {
        self.lip = Self.unit(lip)
        self.blush = Self.unit(blush)
        self.eye = Self.unit(eye)
        self.brow = Self.unit(brow)
    }

    static let disabled = Self()
    var isBypassed: Bool { lip == 0 && blush == 0 && eye == 0 && brow == 0 }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}

struct FilterConfiguration: Equatable, Sendable {
    let preset: FilterPreset
    let intensity: Double

    init(preset: FilterPreset = .original, intensity: Double = 0) {
        self.preset = preset
        self.intensity = preset != .original && intensity.isFinite ? min(1, max(0, intensity)) : 0
    }

    static let original = Self()
    var isBypassed: Bool { preset == .original || intensity == 0 }
}
