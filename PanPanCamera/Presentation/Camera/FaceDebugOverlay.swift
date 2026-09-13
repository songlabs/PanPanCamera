import AVFoundation
import UIKit

/// Display-only, opt-in debug geometry. Skin overlays are composited by the
/// same preview transform as Beauty; no images or point data are written out.
@MainActor
final class FaceAnalysisDebugOverlay {
    static var isEnabled: Bool { FaceAnalysisDebugMode.isEnabled }
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private let container = CALayer()
    private let boxes = CAShapeLayer()
    private let points = CAShapeLayer()
    private let rois = CAShapeLayer()
    private var snapshot: FaceAnalysisDebugSnapshot?

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        container.zPosition = 1_000
        container.masksToBounds = true
        boxes.strokeColor = UIColor.systemGreen.cgColor
        boxes.fillColor = UIColor.clear.cgColor
        boxes.lineWidth = 1.5
        rois.strokeColor = UIColor.systemCyan.cgColor
        rois.fillColor = UIColor.clear.cgColor
        rois.lineWidth = 1
        points.fillColor = UIColor.systemYellow.cgColor
        container.addSublayer(boxes)
        container.addSublayer(points)
        container.addSublayer(rois)
        previewLayer.addSublayer(container)
    }

    func update(_ snapshot: FaceAnalysisDebugSnapshot?) {
        self.snapshot = snapshot
        redraw()
    }

    func redraw() {
        guard let previewLayer else { return }
        let bounds = previewLayer.bounds
        let boxPath = UIBezierPath(), pointPath = UIBezierPath(), roiPath = UIBezierPath()
        func display(_ p: CGPoint) -> CGPoint {
            CGPoint(x: bounds.minX + p.x * bounds.width, y: bounds.minY + (1 - p.y) * bounds.height)
        }
        if FaceAnalysisDebugMode.boxes {
            for box in snapshot?.boxes ?? [] {
                let corners = FaceAnalysisCoordinates.corners(box).map(display)
                if let first = corners.first {
                    boxPath.move(to: first)
                    corners.dropFirst().forEach { boxPath.addLine(to: $0) }
                    boxPath.close()
                }
            }
        }
        if FaceAnalysisDebugMode.roi {
            for roi in snapshot?.rois ?? [] {
                let corners = FaceAnalysisCoordinates.corners(roi).map(display)
                if let first = corners.first {
                    roiPath.move(to: first)
                    corners.dropFirst().forEach { roiPath.addLine(to: $0) }
                    roiPath.close()
                }
            }
        }
        if FaceAnalysisDebugMode.landmarks {
            for point in (snapshot?.points ?? []).map(display) {
                pointPath.append(UIBezierPath(ovalIn: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        boxes.frame = container.bounds
        points.frame = container.bounds
        rois.frame = container.bounds
        rois.path = roiPath.cgPath
        boxes.path = boxPath.cgPath
        points.path = pointPath.cgPath
        CATransaction.commit()
    }
}
