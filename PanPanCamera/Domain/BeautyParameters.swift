enum SkinTool: String, CaseIterable, Identifiable, Sendable {
    case auto, smooth, brighten, tone, blemish, darkCircles
    var id: Self { self }
}

enum FaceTool: String, CaseIterable, Identifiable, Sendable {
    case auto, slim, width, chin, forehead, cheekbones
    case eyes, eyeSpacing, eyeHeight, noseWidth, noseLength, mouthShape, mouthWidth
    var id: Self { self }
}

/// User-facing values. `auto` is a category-wide batch control; selecting a
/// concrete tool never changes any other stored value.
struct BeautyParameters: Equatable, Sendable {
    static let range: ClosedRange<Double> = 0...100
    static let defaultValue: Double = 50

    private var skin: [SkinTool: Double] = [:]
    private var face: [FaceTool: Double] = [:]
    private var makeup: [MakeupTool: Double] = [:]
    private var filters: [FilterPreset: Double] = [:]
    private(set) var selectedSkin: SkinTool = .auto
    private(set) var selectedFace: FaceTool = .auto
    private(set) var selectedMakeup: MakeupTool = .lip
    private(set) var selectedFilter: FilterPreset = .original

    func value(for tool: SkinTool) -> Double { skin[tool, default: Self.defaultValue] }
    func value(for tool: FaceTool) -> Double { face[tool, default: Self.defaultValue] }
    func value(for tool: MakeupTool) -> Double { makeup[tool, default: Self.defaultValue] }
    func value(for preset: FilterPreset) -> Double {
        preset == .original ? 0 : filters[preset, default: Self.defaultValue]
    }

    mutating func select(_ tool: SkinTool) { selectedSkin = tool }
    mutating func select(_ tool: FaceTool) { selectedFace = tool }
    mutating func select(_ tool: MakeupTool) { selectedMakeup = tool }
    mutating func select(_ preset: FilterPreset) { selectedFilter = preset }

    mutating func setValue(_ value: Double, for tool: MakeupTool) {
        guard value.isFinite else { return }
        makeup[tool] = Self.clamp(value)
    }

    mutating func setValue(_ value: Double, for preset: FilterPreset) {
        guard value.isFinite, preset != .original else { return }
        filters[preset] = Self.clamp(value)
    }

    mutating func setValue(_ value: Double, for tool: SkinTool) {
        guard value.isFinite else { return }
        let value = Self.clamp(value)
        skin[tool] = value
        if tool == .auto {
            for child in SkinTool.allCases where child != .auto { skin[child] = value }
        }
    }

    mutating func setValue(_ value: Double, for tool: FaceTool) {
        guard value.isFinite else { return }
        let value = Self.clamp(value)
        face[tool] = value
        if tool == .auto {
            for child in FaceTool.allCases where child != .auto { face[child] = value }
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    var processingConfiguration: BeautyConfiguration {
        BeautyConfiguration(
            enabled: true,
            overallStrength: value(for: SkinTool.auto) / Self.range.upperBound,
            smoothingStrength: value(for: SkinTool.smooth) / Self.range.upperBound,
            brighteningStrength: value(for: SkinTool.brighten) / Self.range.upperBound,
            toneStrength: value(for: SkinTool.tone) / Self.range.upperBound,
            blemishStrength: value(for: SkinTool.blemish) / Self.range.upperBound,
            darkCirclesStrength: value(for: SkinTool.darkCircles) / Self.range.upperBound,
            faceOverallStrength: value(for: FaceTool.auto) / Self.range.upperBound,
            faceSlimStrength: value(for: FaceTool.slim) / Self.range.upperBound,
            faceWidthStrength: value(for: FaceTool.width) / Self.range.upperBound,
            chinStrength: value(for: FaceTool.chin) / Self.range.upperBound,
            foreheadStrength: value(for: FaceTool.forehead) / Self.range.upperBound,
            cheekbonesStrength: value(for: FaceTool.cheekbones) / Self.range.upperBound,
            makeup: MakeupConfiguration(
                lip: value(for: MakeupTool.lip) / Self.range.upperBound,
                blush: value(for: MakeupTool.blush) / Self.range.upperBound,
                eye: value(for: MakeupTool.eye) / Self.range.upperBound,
                brow: value(for: MakeupTool.brow) / Self.range.upperBound),
            filter: FilterConfiguration(preset: selectedFilter,
                intensity: value(for: selectedFilter) / Self.range.upperBound)
        )
    }
}

/// Immutable renderer input. Preview and final capture share skin, makeup and filter semantics,
/// while Face Correction is consumed only by Preview. Shutter capture still keeps
/// one value snapshot rather than UI state.
/// Eye, nose and mouth controls remain absent until reliable
/// local processors for those controls exist. Face geometry is Preview-only.
struct BeautyConfiguration: Equatable, Sendable {
    let enabled: Bool
    let overallStrength: Double
    let smoothingStrength: Double
    let brighteningStrength: Double
    let toneStrength: Double
    let blemishStrength: Double
    let darkCirclesStrength: Double
    let faceOverallStrength: Double
    let faceSlimStrength: Double
    let faceWidthStrength: Double
    let chinStrength: Double
    let foreheadStrength: Double
    let cheekbonesStrength: Double
    let makeup: MakeupConfiguration
    let filter: FilterConfiguration

    init(enabled: Bool = false, overallStrength: Double = 0,
          smoothingStrength: Double = 0, brighteningStrength: Double = 0,
          toneStrength: Double = 0, blemishStrength: Double = 0,
          darkCirclesStrength: Double = 0, faceOverallStrength: Double = 0,
          faceSlimStrength: Double = 0, faceWidthStrength: Double = 0,
          chinStrength: Double = 0, foreheadStrength: Double = 0,
          cheekbonesStrength: Double = 0, makeup: MakeupConfiguration = .disabled,
          filter: FilterConfiguration = .original) {
        self.enabled = enabled
        self.overallStrength = Self.unit(overallStrength)
        self.smoothingStrength = Self.unit(smoothingStrength)
        self.brighteningStrength = Self.unit(brighteningStrength)
        self.toneStrength = Self.unit(toneStrength)
        self.blemishStrength = Self.unit(blemishStrength)
        self.darkCirclesStrength = Self.unit(darkCirclesStrength)
        self.faceOverallStrength = Self.unit(faceOverallStrength)
        self.faceSlimStrength = Self.unit(faceSlimStrength)
        self.faceWidthStrength = Self.unit(faceWidthStrength)
        self.chinStrength = Self.unit(chinStrength)
        self.foreheadStrength = Self.unit(foreheadStrength)
        self.cheekbonesStrength = Self.unit(cheekbonesStrength)
        self.makeup = makeup
        self.filter = filter
    }

    static let disabled = Self()

    var effectiveSmoothing: Double { overallStrength * smoothingStrength }
    var effectiveBrightening: Double { overallStrength * brighteningStrength }
    var effectiveTone: Double { overallStrength * toneStrength }
    var effectiveBlemish: Double { overallStrength * blemishStrength }
    var effectiveDarkCircles: Double { overallStrength * darkCirclesStrength }
    var effectiveFaceSlim: Double { faceOverallStrength * faceSlimStrength }
    var effectiveFaceWidth: Double { faceOverallStrength * faceWidthStrength }
    var effectiveChin: Double { faceOverallStrength * chinStrength }
    var effectiveForehead: Double { faceOverallStrength * foreheadStrength }
    var effectiveCheekbones: Double { faceOverallStrength * cheekbonesStrength }

    var isSkinBypassed: Bool {
        !enabled ||
            (effectiveSmoothing == 0 && effectiveBrightening == 0 && effectiveTone == 0 &&
                effectiveBlemish == 0 && effectiveDarkCircles == 0)
    }

    var isPhotoBypassed: Bool {
        !enabled || (isSkinBypassed && makeup.isBypassed && filter.isBypassed)
    }

    var requiresFaceDetection: Bool {
        enabled && (!isSkinBypassed || !makeup.isBypassed)
    }

    var isFaceCorrectionBypassed: Bool {
        !enabled ||
            (effectiveFaceSlim == 0 && effectiveFaceWidth == 0 && effectiveChin == 0 &&
                effectiveForehead == 0 && effectiveCheekbones == 0)
    }

    var isBypassed: Bool {
        isPhotoBypassed && isFaceCorrectionBypassed
    }

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
