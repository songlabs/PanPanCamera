import CoreImage
import CoreVideo
import Foundation
import StoreKit

struct BeautyPreviewFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let orientation: FaceImageOrientation
    let mirrored: Bool
    let analysis: FaceAnalysisResult?
    let configuration: BeautyConfiguration
}

enum FaceAnalysisDebugMode {
    /// Session-only override shared with the video queue; never saved in defaults.
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var available: Bool
        private var manual = false
        init(available: Bool) { self.available = available }
        func snapshot() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return available && manual
        }
        var isAvailable: Bool {
            lock.lock(); defer { lock.unlock() }
            return available
        }
        func setEnabled(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            manual = available && value
        }
        func setAvailable(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            available = value
            if !value { manual = false }
        }
    }
    private static var isDevelopmentBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
    private static let state = State(available: isDevelopmentBuild)
    static var isAvailable: Bool { state.isAvailable }
    static func setEnabled(_ value: Bool) { state.setEnabled(value) }
    static var boxes: Bool { isEnabled }
    static var landmarks: Bool { isEnabled }
    static var skin: Bool { isEnabled }
    static var roi: Bool { isEnabled }
    static var isEnabled: Bool { state.snapshot() }

    static func permitsGuides(isDebugBuild: Bool, environment: AppStore.Environment?) -> Bool {
        isDebugBuild || environment == .sandbox
    }

    /// Called by Settings only, never by frame processing. Missing/unverified
    /// transactions fail closed; the next Settings presentation can retry.
    static func resolveAvailability() async -> Bool {
        if isDevelopmentBuild { return true }
        let available: Bool
        do {
            let result = try await AppTransaction.shared
            if case .verified(let transaction) = result {
                available = permitsGuides(isDebugBuild: false, environment: transaction.environment)
            } else {
                available = false
            }
        } catch {
            available = false
        }
        state.setAvailable(available)
        return available
    }
}

struct FaceAnalysisDebugSnapshot: @unchecked Sendable {
    let extent: CGRect
    let boxes: [CGRect]
    let rois: [CGRect]
    let points: [CGPoint]
    var contours: [[CGPoint]] = []
    var geometry: FaceCorrectionGeometryResult = .empty
    var eyes: [FaceCorrectionGeometry.EyeAdjustment] = []
    var skinImage: CGImage? = nil
    var configuration: BeautyConfiguration = .disabled
    var captureOrientation: FaceImageOrientation = .up
    var displayOrientation: FaceImageOrientation = .up
    var displayRotationAngle: CGFloat = 0
    var mirrored: Bool = false
}

struct BeautyPreviewProcessingResult {
    let image: CIImage?
    let analysisDebug: FaceAnalysisDebugSnapshot?
}
