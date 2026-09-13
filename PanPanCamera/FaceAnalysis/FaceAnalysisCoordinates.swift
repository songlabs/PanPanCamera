import Foundation

/// Small framework-independent affine map. Composition means apply self, then next.
struct FaceAnalysisTransform: Equatable, Sendable {
    var a: CGFloat = 1, b: CGFloat = 0, c: CGFloat = 0, d: CGFloat = 1
    var tx: CGFloat = 0, ty: CGFloat = 0
    static let identity = Self()

    func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty)
    }

    func then(_ n: Self) -> Self {
        Self(a: n.a * a + n.c * b, b: n.b * a + n.d * b,
             c: n.a * c + n.c * d, d: n.b * c + n.d * d,
             tx: n.a * tx + n.c * ty + n.tx, ty: n.b * tx + n.d * ty + n.ty)
    }

    var isValid: Bool {
        [a, b, c, d, tx, ty].allSatisfy(\.isFinite) && abs(a * d - b * c) > 1e-12
    }

    static func unitToRect(_ rect: CGRect) -> Self {
        Self(a: rect.width, d: rect.height, tx: rect.minX, ty: rect.minY)
    }
}

enum FaceAnalysisCoordinates {
    static func isUnitPoint(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && (0...1).contains(point.x) && (0...1).contains(point.y)
    }

    static func isUnitBox(_ box: CGRect) -> Bool {
        box.width > 0 && box.height > 0 && isUnitPoint(box.origin) &&
            isUnitPoint(CGPoint(x: box.maxX, y: box.maxY))
    }

    static func bounds(_ points: [CGPoint]) -> CGRect {
        guard let x = points.map(\.x).min(), let y = points.map(\.y).min(),
              let maxX = points.map(\.x).max(), let maxY = points.map(\.y).max() else { return .null }
        return CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
    }

    static func corners(_ rect: CGRect) -> [CGPoint] {
        [rect.origin, CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    static func reorientation(from source: FaceImageOrientation, sourceMirrored: Bool,
                              to destination: FaceImageOrientation, mirrored: Bool) -> FaceAnalysisTransform {
        func convert(_ p: CGPoint) -> CGPoint {
            let unmirrored = CGPoint(x: sourceMirrored ? 1 - p.x : p.x, y: p.y)
            return FaceCoordinates.reorient(unmirrored, from: source, to: destination, mirrored: mirrored)
        }
        let zero = convert(.zero), x = convert(CGPoint(x: 1, y: 0)), y = convert(CGPoint(x: 0, y: 1))
        return FaceAnalysisTransform(a: x.x - zero.x, b: x.y - zero.y,
            c: y.x - zero.x, d: y.y - zero.y, tx: zero.x, ty: zero.y)
    }

    static func map(_ faces: [AnalyzedFace], by transform: FaceAnalysisTransform) -> [AnalyzedFace] {
        faces.map { face in
            AnalyzedFace(trackingID: face.trackingID,
                boundingBox: bounds(corners(face.boundingBox).map(transform.point)),
                confidence: face.confidence, landmarks: face.landmarks.map(transform.point),
                semanticMasks: face.semanticMasks?.transformed(by: transform))
        }
    }
}
