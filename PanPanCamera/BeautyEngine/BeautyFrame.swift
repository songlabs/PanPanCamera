import CoreImage
import CoreVideo
import Foundation

struct BeautyPreviewFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let orientation: FaceImageOrientation
    let mirrored: Bool
    let analysis: FaceAnalysisResult?
    let configuration: BeautyConfiguration
}

enum FaceAnalysisDebugMode {
    /// Session-only override shared with the video queue; never saved in defaults.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var manual: Bool?
        func snapshot() -> Bool? {
            lock.lock(); defer { lock.unlock() }
            return manual
        }
    }
    private static let state = State()
    private static let arguments = Set(ProcessInfo.processInfo.arguments)
    static func setEnabled(_ value: Bool) {
        #if DEBUG
        state.lock.lock(); defer { state.lock.unlock() }
        state.manual = value
        #endif
    }
    static func enabled(_ flag: String) -> Bool {
        #if DEBUG
        state.snapshot() ?? (arguments.contains(flag) || arguments.contains("-PanPanFaceDebugOverlay"))
        #else
        false
        #endif
    }
    static var boxes: Bool { enabled("-PanPanFaceBoxes") }
    static var landmarks: Bool { enabled("-PanPanVisionLandmarks") }
    static var skin: Bool { enabled("-PanPanSkinMask") }
    static var roi: Bool { enabled("-PanPanFaceROI") }
    static var isEnabled: Bool {
        #if DEBUG
        state.snapshot() ?? ["-PanPanFaceDebugOverlay", "-PanPanFaceBoxes", "-PanPanVisionLandmarks",
                             "-PanPanSkinMask", "-PanPanFaceROI"].contains { arguments.contains($0) }
        #else
        false
        #endif
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
