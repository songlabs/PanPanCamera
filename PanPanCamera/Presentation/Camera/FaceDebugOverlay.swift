import AVFoundation
import UIKit

/// Temporary always-on diagnostic overlay for the current TestFlight investigation.
/// It consumes renderer-space production geometry and never performs Vision itself.
@MainActor
final class FaceGeometryDebugOverlay {
    static var isEnabled: Bool { FaceGeometryDebugMode.isEnabled }

    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private let container = CALayer()
    private let boxes = CAShapeLayer()
    private let contourLines = CAShapeLayer()
    private let contourPoints = CAShapeLayer()
    private let radii = CAShapeLayer()
    private let centers = CAShapeLayer()
    private let vectors = CAShapeLayer()
    private let text = CATextLayer()
    private var snapshot: FaceGeometryDebugSnapshot?

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        container.zPosition = 1_000
        container.masksToBounds = true

        configure(boxes, stroke: .systemGreen, fill: .clear, lineWidth: 2)
        configure(contourLines, stroke: .systemYellow, fill: .clear, lineWidth: 1)
        configure(contourPoints, stroke: .clear, fill: .systemYellow, lineWidth: 0)
        configure(radii, stroke: .systemCyan, fill: .clear, lineWidth: 1.5)
        radii.lineDashPattern = [6, 4]
        configure(centers, stroke: .systemPink, fill: .clear, lineWidth: 2)
        configure(vectors, stroke: .systemOrange, fill: .clear, lineWidth: 2.5)

        text.contentsScale = UIScreen.main.scale
        text.backgroundColor = UIColor.black.withAlphaComponent(0.64).cgColor
        text.cornerRadius = 6
        text.foregroundColor = UIColor.white.cgColor
        text.fontSize = 10
        text.isWrapped = true
        text.alignmentMode = .left

        [boxes, contourLines, contourPoints, radii, centers, vectors, text]
            .forEach { container.addSublayer($0) }
        previewLayer.addSublayer(container)
        redraw()
    }

    func update(_ snapshot: FaceGeometryDebugSnapshot?) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
        redraw()
    }

    func redraw() {
        guard let previewLayer else { return }
        let bounds = previewLayer.bounds
        let boxPath = UIBezierPath()
        let contourLinePath = UIBezierPath()
        let contourPointPath = UIBezierPath()
        let radiusPath = UIBezierPath()
        let centerPath = UIBezierPath()
        let vectorPath = UIBezierPath()

        if let snapshot, isUsable(snapshot.extent), !bounds.isEmpty {
            if let faceBox = snapshot.faceBox {
                let corners = [
                    CGPoint(x: faceBox.minX, y: faceBox.minY),
                    CGPoint(x: faceBox.maxX, y: faceBox.minY),
                    CGPoint(x: faceBox.maxX, y: faceBox.maxY),
                    CGPoint(x: faceBox.minX, y: faceBox.maxY)
                ].map { displayPoint($0, from: snapshot.extent, in: bounds) }
                if let first = corners.first {
                    boxPath.move(to: first)
                    corners.dropFirst().forEach { boxPath.addLine(to: $0) }
                    boxPath.close()
                }
            }

            let displayedContour = snapshot.contour.map {
                displayPoint($0, from: snapshot.extent, in: bounds)
            }
            if let first = displayedContour.first {
                contourLinePath.move(to: first)
                displayedContour.dropFirst().forEach { contourLinePath.addLine(to: $0) }
            }
            for point in displayedContour {
                contourPointPath.append(UIBezierPath(ovalIn: CGRect(
                    x: point.x - 2, y: point.y - 2, width: 4, height: 4
                )))
            }

            for warp in snapshot.smallFaceWarps {
                let center = displayPoint(warp.center, from: snapshot.extent, in: bounds)
                let radiusX = warp.radius / snapshot.extent.width * bounds.width
                let radiusY = warp.radius / snapshot.extent.height * bounds.height
                radiusPath.append(UIBezierPath(ovalIn: CGRect(
                    x: center.x - radiusX, y: center.y - radiusY,
                    width: radiusX * 2, height: radiusY * 2
                )))
                centerPath.append(UIBezierPath(ovalIn: CGRect(
                    x: center.x - 5, y: center.y - 5, width: 10, height: 10
                )))
                centerPath.move(to: CGPoint(x: center.x - 8, y: center.y))
                centerPath.addLine(to: CGPoint(x: center.x + 8, y: center.y))
                centerPath.move(to: CGPoint(x: center.x, y: center.y - 8))
                centerPath.addLine(to: CGPoint(x: center.x, y: center.y + 8))

                let target = displayPoint(
                    CGPoint(x: warp.center.x + warp.visibleOffset.dx,
                            y: warp.center.y + warp.visibleOffset.dy),
                    from: snapshot.extent, in: bounds
                )
                if hypot(target.x - center.x, target.y - center.y) >= 0.5 {
                    appendArrow(from: center, to: target, path: vectorPath)
                }
            }
            text.string = diagnosticText(snapshot)
        } else {
            text.string = nil
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        for shape in [boxes, contourLines, contourPoints, radii, centers, vectors] {
            shape.frame = container.bounds
        }
        boxes.path = boxPath.cgPath
        contourLines.path = contourLinePath.cgPath
        contourPoints.path = contourPointPath.cgPath
        radii.path = radiusPath.cgPath
        centers.path = centerPath.cgPath
        vectors.path = vectorPath.cgPath
        let textWidth = min(280, max(0, bounds.width - 16))
        text.frame = CGRect(x: 8, y: 64, width: textWidth, height: 148)
        CATransaction.commit()
    }

    private func configure(_ layer: CAShapeLayer, stroke: UIColor, fill: UIColor,
                           lineWidth: CGFloat) {
        layer.strokeColor = stroke.cgColor
        layer.fillColor = fill.cgColor
        layer.lineWidth = lineWidth
        layer.lineJoin = .round
        layer.lineCap = .round
    }

    private func displayPoint(_ point: CGPoint, from extent: CGRect, in bounds: CGRect) -> CGPoint {
        let x = (point.x - extent.minX) / extent.width * bounds.width
        let y = (point.y - extent.minY) / extent.height * bounds.height
        return CGPoint(x: x, y: bounds.height - y)
    }

    private func appendArrow(from start: CGPoint, to end: CGPoint, path: UIBezierPath) {
        path.move(to: start)
        path.addLine(to: end)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = 7
        for offset in [-CGFloat.pi * 0.82, CGFloat.pi * 0.82] {
            path.move(to: end)
            path.addLine(to: CGPoint(x: end.x + cos(angle + offset) * arrowLength,
                                     y: end.y + sin(angle + offset) * arrowLength))
        }
    }

    private func diagnosticText(_ snapshot: FaceGeometryDebugSnapshot) -> String {
        let left = snapshot.smallFaceWarps.first { $0.kind == .slimLeft }?.visibleOffset.dx ?? 0
        let right = snapshot.smallFaceWarps.first { $0.kind == .slimRight }?.visibleOffset.dx ?? 0
        let faceWidth = snapshot.faceBox?.width ?? 0
        return String(format: """
        Face: %@
        smallFace UI: %.0f
        normalized: %.2f
        Auto: %.2f
        effective: %.2f
        faceWidth: %.1f px
        left displacement: %.1f px
        right displacement: %.1f px
        orientation: %@ -> %@ / %.1f deg
        mirrored: %@
        landmarkCount: %d
        """, snapshot.faceDetected ? "detected" : "none",
        snapshot.smallFaceUI, snapshot.normalizedSmallFace, snapshot.auto,
        snapshot.effectiveSmallFace, faceWidth, left, right,
        orientationName(snapshot.captureOrientation), orientationName(snapshot.displayOrientation),
        snapshot.displayRotationAngle, snapshot.mirrored ? "true" : "false",
        snapshot.contour.count)
    }

    private func orientationName(_ orientation: FaceImageOrientation) -> String {
        switch orientation {
        case .up: "up"
        case .right: "right"
        case .down: "down"
        case .left: "left"
        }
    }

    private func isUsable(_ extent: CGRect) -> Bool {
        extent.width.isFinite && extent.height.isFinite && extent.width > 0 && extent.height > 0
    }
}
