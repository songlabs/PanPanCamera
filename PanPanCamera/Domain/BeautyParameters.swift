enum SkinTool: String, CaseIterable, Identifiable, Sendable {
    case auto, smooth, brighten, tone, blemish, darkCircles
    var id: Self { self }
}

enum FaceTool: String, CaseIterable, Identifiable, Sendable {
    case auto, slim, width, chin, forehead, cheekbones
    case eyes, eyeSpacing, eyeHeight, noseWidth, noseLength, mouthShape, mouthWidth
    var id: Self { self }
}

/// UI draft values only. No renderer consumes these values in version 0.1.
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
}
