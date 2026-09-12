/// Semantic failures; presentation chooses the localized copy.
enum CameraFailure: Equatable, Sendable {
    case captureFailed
    case processingFailed
    case saveFailed
    case switchFailed
}
