import Foundation

/// Clockwise compensation for an unrotated, unmirrored camera buffer.
/// Use the device's RotationCoordinator capture angle, never UI/device enum raw values.
enum FaceImageOrientation: Int, CaseIterable, Sendable {
    case up = 0, right = 90, down = 180, left = 270

    init?(captureAngle: CGFloat) {
        guard captureAngle.isFinite else { return nil }
        let normalized = (captureAngle.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        // EXIF supports quarter turns. Remaining horizon tilt is handled by the preview layer.
        let quarter = Int((normalized / 90).rounded()) % 4
        self = [.up, .right, .down, .left][quarter]
    }
}

enum FaceCoordinates {
    /// Vision lower-left oriented image -> unrotated capture-device top-left [0, 1].
    static func captureDevicePoint(_ point: CGPoint, orientation: FaceImageOrientation) -> CGPoint {
        let upright = CGPoint(x: point.x, y: 1 - point.y)
        switch orientation {
        case .up: return upright
        case .right: return CGPoint(x: upright.y, y: 1 - upright.x)
        case .down: return CGPoint(x: 1 - upright.x, y: 1 - upright.y)
        case .left: return CGPoint(x: 1 - upright.y, y: upright.x)
        }
    }

    /// Unrotated capture-device top-left -> Vision-style bottom-left coordinates
    /// for another oriented image. This is the inverse of captureDevicePoint.
    static func imagePoint(_ point: CGPoint, orientation: FaceImageOrientation) -> CGPoint {
        switch orientation {
        case .up: return CGPoint(x: point.x, y: 1 - point.y)
        case .right: return CGPoint(x: 1 - point.y, y: 1 - point.x)
        case .down: return CGPoint(x: 1 - point.x, y: point.y)
        case .left: return CGPoint(x: point.y, y: point.x)
        }
    }

    static func reorient(_ point: CGPoint, from source: FaceImageOrientation,
                         to destination: FaceImageOrientation, mirrored: Bool) -> CGPoint {
        var result = imagePoint(captureDevicePoint(point, orientation: source),
                                orientation: destination)
        if mirrored { result.x = 1 - result.x }
        return result
    }

    static func imageLandmarks(_ points: [CGPoint]?, boundingBox: CGRect) -> [CGPoint]? {
        guard let points, !points.isEmpty else { return nil }
        return points.map {
            CGPoint(x: boundingBox.minX + $0.x * boundingBox.width,
                    y: boundingBox.minY + $0.y * boundingBox.height)
        }
    }

    /// The supplied conversion is AVCaptureVideoPreviewLayer.layerPointConverted.
    /// It owns mirroring, rotation, view size and videoGravity. Do not mirror a second time.
    static func previewPoint(_ point: CGPoint, orientation: FaceImageOrientation,
                             convert: (CGPoint) -> CGPoint) -> CGPoint {
        convert(captureDevicePoint(point, orientation: orientation))
    }

    /// Transform every corner, also preserving a tilted preview's box outline.
    static func previewCorners(_ box: CGRect, orientation: FaceImageOrientation,
                               convert: (CGPoint) -> CGPoint) -> [CGPoint] {
        [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
         CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            .map { previewPoint($0, orientation: orientation, convert: convert) }
    }
}
