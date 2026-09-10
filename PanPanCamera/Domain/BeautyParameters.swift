enum SkinTool: String, CaseIterable, Identifiable, Sendable {
    case auto, smooth, brighten, tone, blemish, darkCircles
    var id: Self { self }
}

enum FaceTool: String, CaseIterable, Identifiable, Sendable {
    case auto, slim, width, chin, forehead, cheekbones
    case eyes, eyeSpacing, eyeHeight, noseWidth, noseLength, mouthShape, mouthWidth
    var id: Self { self }
}

/// User-facing values. `auto` is the overall strength used by the processing
/// configuration; selecting a tool never changes its stored value.
struct BeautyParameters: Equatable, Sendable {
    static let range: ClosedRange<Double> = 0...100
    static let defaultValue: Double = 50

    private var skin: [SkinTool: Double] = [:]
    private var face: [FaceTool: Double] = [:]
    private(set) var selectedSkin: SkinTool = .auto
    private(set) var selectedFace: FaceTool = .auto

    func value(for tool: SkinTool) -> Double { skin[tool, default: Self.defaultValue] }
    func value(for tool: FaceTool) -> Double { face[tool, default: Self.defaultValue] }

    mutating func select(_ tool: SkinTool) { selectedSkin = tool }
    mutating func select(_ tool: FaceTool) { selectedFace = tool }

    mutating func setValue(_ value: Double, for tool: SkinTool) {
        guard value.isFinite else { return }
        skin[tool] = Self.clamp(value)
    }

    mutating func setValue(_ value: Double, for tool: FaceTool) {
        guard value.isFinite else { return }
        face[tool] = Self.clamp(value)
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
            faceOverallStrength: value(for: FaceTool.auto) / Self.range.upperBound,
            faceSlimStrength: value(for: FaceTool.slim) / Self.range.upperBound,
            faceWidthStrength: value(for: FaceTool.width) / Self.range.upperBound,
            chinStrength: value(for: FaceTool.chin) / Self.range.upperBound,
            foreheadStrength: value(for: FaceTool.forehead) / Self.range.upperBound,
            cheekbonesStrength: value(for: FaceTool.cheekbones) / Self.range.upperBound
        )
    }
}

/// Immutable renderer input. Preview and final capture share the skin semantics,
/// while Face Correction is consumed only by Preview. Shutter capture still keeps
/// one value snapshot rather than UI state.
/// Blemish, dark-circle, eye, nose and mouth controls remain absent until reliable
/// local processors for those controls exist. Face geometry is Preview-only.
struct BeautyConfiguration: Equatable, Sendable {
    let enabled: Bool
    let overallStrength: Double
    let smoothingStrength: Double
    let brighteningStrength: Double
    let toneStrength: Double
    let faceOverallStrength: Double
    let faceSlimStrength: Double
    let faceWidthStrength: Double
    let chinStrength: Double
    let foreheadStrength: Double
    let cheekbonesStrength: Double

    init(enabled: Bool = false, overallStrength: Double = 0,
          smoothingStrength: Double = 0, brighteningStrength: Double = 0,
          toneStrength: Double = 0, faceOverallStrength: Double = 0,
          faceSlimStrength: Double = 0, faceWidthStrength: Double = 0,
          chinStrength: Double = 0, foreheadStrength: Double = 0,
          cheekbonesStrength: Double = 0) {
        self.enabled = enabled
        self.overallStrength = Self.unit(overallStrength)
        self.smoothingStrength = Self.unit(smoothingStrength)
        self.brighteningStrength = Self.unit(brighteningStrength)
        self.toneStrength = Self.unit(toneStrength)
        self.faceOverallStrength = Self.unit(faceOverallStrength)
        self.faceSlimStrength = Self.unit(faceSlimStrength)
        self.faceWidthStrength = Self.unit(faceWidthStrength)
        self.chinStrength = Self.unit(chinStrength)
        self.foreheadStrength = Self.unit(foreheadStrength)
        self.cheekbonesStrength = Self.unit(cheekbonesStrength)
    }

    static let disabled = Self()

    var effectiveSmoothing: Double { overallStrength * smoothingStrength }
    var effectiveBrightening: Double { overallStrength * brighteningStrength }
    var effectiveTone: Double { overallStrength * toneStrength }
    var effectiveFaceSlim: Double { faceOverallStrength * faceSlimStrength }
    var effectiveFaceWidth: Double { faceOverallStrength * faceWidthStrength }
    var effectiveChin: Double { faceOverallStrength * chinStrength }
    var effectiveForehead: Double { faceOverallStrength * foreheadStrength }
    var effectiveCheekbones: Double { faceOverallStrength * cheekbonesStrength }

    var isPhotoBypassed: Bool {
        !enabled || overallStrength == 0 ||
            (effectiveSmoothing == 0 && effectiveBrightening == 0 && effectiveTone == 0)
    }

    var isFaceCorrectionBypassed: Bool {
        !enabled || faceOverallStrength == 0 ||
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
