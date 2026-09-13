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
    static func enabled(_ flag: String) -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(flag)
        #else
        false
        #endif
    }
    static var boxes: Bool { enabled("-PanPanFaceBoxes") }
    static var landmarks: Bool { enabled("-PanPanVisionLandmarks") }
    static var skin: Bool { enabled("-PanPanSkinMask") }
    static var roi: Bool { enabled("-PanPanFaceROI") }
    static var isEnabled: Bool { boxes || landmarks || skin || roi }
}

struct FaceAnalysisDebugSnapshot: Equatable, Sendable {
    let extent: CGRect
    let boxes: [CGRect]
    let rois: [CGRect]
    let points: [CGPoint]
}

struct BeautyPreviewProcessingResult {
    let image: CIImage?
    let analysisDebug: FaceAnalysisDebugSnapshot?
}
