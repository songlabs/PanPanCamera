#if DEBUG
import AVFoundation
import UIKit

/// Development-only launch argument. No settings, overlays or face drawing ship in Release.
@MainActor
final class FaceDebugOverlay {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-PanPanFaceDebugOverlay")
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private let boxes = CAShapeLayer()
    private let points = CAShapeLayer()
    private var frame: FaceDetectionFrame?

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        boxes.strokeColor = UIColor.systemGreen.cgColor
        boxes.fillColor = UIColor.clear.cgColor
        boxes.lineWidth = 2
        points.fillColor = UIColor.systemYellow.cgColor
        previewLayer.addSublayer(boxes)
        previewLayer.addSublayer(points)
    }

    func update(_ frame: FaceDetectionFrame?, deviceID: String?) {
        self.frame = frame
        redraw(deviceID: deviceID)
    }

    func redraw(deviceID: String?) {
        let boxPath = UIBezierPath()
        let pointPath = UIBezierPath()
        if let previewLayer, let frame, frame.deviceID == deviceID {
            let convert: (CGPoint) -> CGPoint = { previewLayer.layerPointConverted(fromCaptureDevicePoint: $0) }
            for face in frame.faces {
                let corners = FaceCoordinates.previewCorners(face.boundingBox, orientation: frame.orientation,
                                                             convert: convert)
                if let first = corners.first {
                    boxPath.move(to: first)
                    corners.dropFirst().forEach { boxPath.addLine(to: $0) }
                    boxPath.close()
                }
                for landmark in face.landmarks.values.joined() {
                    let point = FaceCoordinates.previewPoint(landmark, orientation: frame.orientation, convert: convert)
                    pointPath.append(UIBezierPath(ovalIn: CGRect(x: point.x - 1.5, y: point.y - 1.5,
                                                                width: 3, height: 3)))
                }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [boxes, points] {
            shape.frame = previewLayer?.bounds ?? .zero
            shape.masksToBounds = true
        }
        boxes.path = boxPath.cgPath
        points.path = pointPath.cgPath
        CATransaction.commit()
    }
}
#endif
