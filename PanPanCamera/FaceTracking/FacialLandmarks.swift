import Foundation

/// Shared semantic names only. Preview retains its existing image-coordinate data;
/// innerLips/noseCrest/faceContour remain for that existing consumer, not retouch v1.
enum FacialLandmarkRegion: CaseIterable, Hashable, Sendable {
    case leftEye, rightEye, leftEyebrow, rightEyebrow
    case nose, noseCrest, outerLips, innerLips, faceContour

    static let protectedFeatures: [Self] = [.leftEye, .rightEye, .leftEyebrow, .rightEyebrow, .outerLips, .nose]
    var isProtectionPolygon: Bool { self == .leftEye || self == .rightEye || self == .outerLips }
}

/// Single-photo data: every point is FaceRegion-local normalized [0,1], origin
/// bottom-left. The image AND region are already display-oriented/mirrored by the
/// loader. No EXIF or preview transform applies here. Left/right name the provider's
/// features; the mask treats both equally and never mirrors or swaps coordinates.
/// Binding region and points in one value avoids array-order matching/tracking IDs.
struct FacialLandmarks: Equatable, Sendable {
    let region: FaceRegion
    let features: [FacialLandmarkRegion: [CGPoint]]

    /// Discard an invalid feature as a whole; keep the other valid features/face.
    /// Polygons omit a repeated closing point. Brows/nose are open polylines.
    init(region: FaceRegion, features: [FacialLandmarkRegion: [CGPoint]]) {
        self.region = region
        self.features = features.filter { name, points in
            FacialLandmarkRegion.protectedFeatures.contains(name) && Self.isValid(points, polygon: name.isProtectionPolygon)
        }
    }

    func imagePoints(for feature: FacialLandmarkRegion, in extent: CGRect) -> [CGPoint] {
        let rect = region.imageRect(in: extent)
        guard !rect.isNull else { return [] }
        return (features[feature] ?? []).map {
            CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height)
        }
    }

    private static func isValid(_ points: [CGPoint], polygon: Bool) -> Bool {
        guard points.count >= (polygon ? 3 : 2), points.allSatisfy({
            $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
        }) else { return false }
        // Repeated vertices create zero-length edges or self-touching paths.
        for i in points.indices {
            for j in points.indices where j > i {
                if points[i] == points[j] { return false }
            }
        }
        guard polygon else { return true }
        let count = points.count
        let area = points.indices.reduce(CGFloat.zero) { sum, i in
            let a = points[i], b = points[(i + 1) % count]
            return sum + a.x * b.y - b.x * a.y
        }
        guard abs(area) > 1e-10 else { return false }
        for i in points.indices {
            for j in points.indices where j > i {
                if j == i + 1 || (i == 0 && j == count - 1) { continue }
                if intersects(points[i], points[(i + 1) % count], points[j], points[(j + 1) % count]) {
                    return false
                }
            }
        }
        return true
    }

    private static func intersects(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        func onSegment(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Bool {
            r.x >= min(p.x, q.x) && r.x <= max(p.x, q.x) && r.y >= min(p.y, q.y) && r.y <= max(p.y, q.y)
        }
        let abC = cross(a, b, c), abD = cross(a, b, d), cdA = cross(c, d, a), cdB = cross(c, d, b)
        if (abC == 0 && onSegment(a, b, c)) || (abD == 0 && onSegment(a, b, d)) ||
            (cdA == 0 && onSegment(c, d, a)) || (cdB == 0 && onSegment(c, d, b)) { return true }
        return ((abC > 0 && abD < 0) || (abC < 0 && abD > 0)) &&
            ((cdA > 0 && cdB < 0) || (cdA < 0 && cdB > 0))
    }
}
