import Foundation

/// One result of history, keyed by ephemeral identity. Ambiguous overlaps start
/// new tracks rather than mixing two people's masks or landmarks by array index.
struct FaceAnalysisSmoother {
    private var previous: FaceAnalysisResult?

    mutating func reset() { previous = nil }

    mutating func update(_ result: FaceAnalysisResult) -> FaceAnalysisResult {
        defer { if result.outcome != .analyzed { previous = nil } }
        guard result.outcome == .analyzed else { return result }
        guard let old = previous, old.orientation == result.orientation,
              old.mirrored == result.mirrored, old.imageSize == result.imageSize,
              result.timestamp >= old.timestamp, result.timestamp - old.timestamp < 0.5
        else { previous = result; return result }

        let candidates = result.faces.map { face in
            old.faces.filter { Self.overlap(face.boundingBox, $0.boundingBox) > 0.35 }
        }
        let alpha = CGFloat(1 - exp(-max(0.001, result.timestamp - old.timestamp) / 0.075))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * alpha }
        let faces = result.faces.enumerated().map { index, face -> AnalyzedFace in
            guard candidates[index].count == 1, let prior = candidates[index].first,
                  candidates.filter({ $0.contains { $0.trackingID == prior.trackingID } }).count == 1
            else { return face }
            let a = prior.boundingBox, b = face.boundingBox
            let box = CGRect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY),
                width: mix(a.width, b.width), height: mix(a.height, b.height))
            let align = FaceAnalysisTransform(a: box.width / b.width, d: box.height / b.height,
                tx: box.minX - b.minX * box.width / b.width,
                ty: box.minY - b.minY * box.height / b.height)
            var landmarks = face.landmarks.map(align.point)
            if prior.landmarks.topologyID == face.landmarks.topologyID,
               prior.landmarks.points.count == face.landmarks.points.count {
                func blend(_ old: [CGPoint], _ new: [CGPoint]) -> [CGPoint] {
                    guard old.count == new.count else { return new }
                    return zip(old, new).map { CGPoint(x: mix($0.x, $1.x), y: mix($0.y, $1.y)) }
                }
                var regions: [FacialLandmarkRegion: [CGPoint]] = [:]
                for (name, points) in face.landmarks.regions {
                    regions[name] = blend(prior.landmarks[name] ?? [], points)
                }
                landmarks = DenseFaceLandmarks(topologyID: face.landmarks.topologyID,
                    points: blend(prior.landmarks.points, face.landmarks.points), regions: regions)
            }
            // Smooth the crop transform with the face. Blend probabilities only
            // within the same track/grid; current protected labels veto history.
            var masks = face.semanticMasks?.transformed(by: align)
            if let current = masks, let history = prior.semanticMasks {
                var planes = current.planes
                for (name, plane) in current.planes {
                    guard let p = history.planes[name], p.width == plane.width, p.height == plane.height else { continue }
                    let values = zip(p.values, plane.values).map { old, new -> Float in
                        let smoothed = old + (new - old) * Float(alpha)
                        if name == .skin { return min(new, smoothed) }
                        if FaceSemanticClass.protected.contains(name) { return max(new, smoothed) }
                        return smoothed
                    }
                    planes[name] = try? FaceSemanticPlane(width: plane.width, height: plane.height,
                        values: values, transform: plane.transform)
                }
                masks = try? FaceSemanticMasks(confidence: current.confidence, planes: planes)
            }
            return AnalyzedFace(trackingID: prior.trackingID, boundingBox: box,
                confidence: face.confidence, landmarks: landmarks, semanticMasks: masks)
        }
        let smoothed = result.replacing(faces: faces)
        previous = smoothed
        return smoothed
    }

    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let area = intersection.width * intersection.height
        return area / max(1e-9, a.width * a.height + b.width * b.height - area)
    }
}
