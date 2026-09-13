import Foundation

/// Camera pixels are sampled in linear sRGB, then converted to display-referred
/// YCbCr. The center is this face's chroma, never a target complexion or RGB range.
struct AdaptiveSkinColor: Sendable {
    struct Sample: Sendable {
        let y: Double
        let cb: Double
        let cr: Double

        init(linearRGB: [Double]) {
            func encoded(_ value: Double) -> Double {
                let v = max(0, value)
                return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
            }
            self.init(sRGB: linearRGB.map(encoded))
        }

        init(sRGB: [Double]) {
            let r = sRGB[0], g = sRGB[1], b = sRGB[2]
            y = 0.299 * r + 0.587 * g + 0.114 * b
            cb = (b - y) * 0.564
            cr = (r - y) * 0.713
        }
    }

    let centerY: Double
    let centerCb: Double
    let centerCr: Double
    let radiusCb: Double
    let radiusCr: Double
    let confidence: Double

    init?(samples: [Sample]) {
        let valid = samples.filter {
            $0.y.isFinite && $0.cb.isFinite && $0.cr.isFinite && $0.y > 0.025 && $0.y < 0.98
        }
        guard valid.count >= 20 else { return nil }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let y = median(valid.map(\.y)), cb = median(valid.map(\.cb)), cr = median(valid.map(\.cr))
        let cbSpread = median(valid.map { abs($0.cb - cb) })
        let crSpread = median(valid.map { abs($0.cr - cr) })
        // Unreliable/glare/monochrome samples fail closed instead of filling the ROI.
        guard hypot(cb, cr) > 0.018, cbSpread < 0.045, crSpread < 0.045 else { return nil }
        let inliers = valid.filter {
            abs($0.cb - cb) < max(0.022, cbSpread * 3) &&
            abs($0.cr - cr) < max(0.022, crSpread * 3) &&
            $0.y > y * 0.55 && $0.y < min(0.98, y + 0.25)
        }
        let ratio = Double(inliers.count) / Double(samples.count)
        guard ratio >= 0.60 else { return nil }
        centerY = median(inliers.map(\.y))
        centerCb = median(inliers.map(\.cb))
        centerCr = median(inliers.map(\.cr))
        radiusCb = min(0.065, max(0.025, cbSpread * 3.5))
        radiusCr = min(0.065, max(0.025, crSpread * 3.5))
        confidence = min(1, ratio / 0.85)
    }

    func weight(_ sample: Sample) -> Double {
        guard sample.y.isFinite, sample.cb.isFinite, sample.cr.isFinite else { return 0 }
        let cb = (sample.cb - centerCb) / radiusCb
        let cr = (sample.cr - centerCr) / radiusCr
        let chroma = 1 - Self.ramp(0.65, 1.6, hypot(cb, cr))
        // Relative exposure guard excludes deep hair/shadow and clipped highlights,
        // while chroma tolerates a brighter forehead and darker cheeks.
        let exposure = Self.ramp(centerY * 0.30, centerY * 0.55, sample.y) *
            (1 - Self.ramp(min(0.94, centerY + 0.28), 0.99, sample.y))
        return chroma * exposure * confidence
    }

    private static func ramp(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let t = min(1, max(0, (value - low) / max(1e-6, high - low)))
        return t * t * (3 - 2 * t)
    }
}

/// Candidate search geometry only. No consumer may use this rectangle as skin.
struct SkinFaceROI: Equatable, Sendable {
    let bounds: CGRect
    let sampleCenters: [CGPoint]
    let sampleSide: CGFloat

    init?(face: AnalyzedFace) {
        let box = face.boundingBox
        guard face.confidence >= 0.5, box.width > 0, box.height > 0,
              [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite) else { return nil }
        func center(_ name: FacialLandmarkRegion) -> CGPoint? {
            let points = face.landmarks[name] ?? []
            guard !points.isEmpty, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                           y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        }
        guard let a = center(.leftEye), let b = center(.rightEye),
              let mouth = center(.outerLips), let browA = center(.leftEyebrow),
              let browB = center(.rightEyebrow) else { return nil }
        let eyeMid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let browMid = CGPoint(x: (browA.x + browB.x) / 2, y: (browA.y + browB.y) / 2)
        let distance = hypot(eyeMid.x - mouth.x, eyeMid.y - mouth.y)
        guard distance > box.height * 0.12 else { return nil }
        let up = CGPoint(x: (eyeMid.x - mouth.x) / distance, y: (eyeMid.y - mouth.y) / distance)
        let eyeSpan = hypot(a.x - b.x, a.y - b.y)
        guard eyeSpan > box.width * 0.15 else { return nil }
        let foreheadDistance = max(eyeSpan * 0.90, distance * 0.85)
        let forehead = CGPoint(x: browMid.x + up.x * foreheadDistance,
                               y: browMid.y + up.y * foreheadDistance)
        let halfWidth = box.width * 0.58
        let candidates = FaceAnalysisCoordinates.corners(box) + [
            CGPoint(x: forehead.x - up.y * halfWidth, y: forehead.y + up.x * halfWidth),
            CGPoint(x: forehead.x + up.y * halfWidth, y: forehead.y - up.x * halfWidth)
        ]
        bounds = FaceAnalysisCoordinates.bounds(candidates).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !bounds.isEmpty, !bounds.isNull else { return nil }
        // Below each eye, outward from the nose and above the lips. A third patch
        // is on the upper bridge, avoiding nostrils. No box-only sampling fallback.
        sampleCenters = [a, b].map { eye in
            CGPoint(x: eye.x - up.x * distance * 0.48 + (eye.x - eyeMid.x) * 0.12,
                    y: eye.y - up.y * distance * 0.48 + (eye.y - eyeMid.y) * 0.12)
        } + [CGPoint(x: eyeMid.x - up.x * distance * 0.24, y: eyeMid.y - up.y * distance * 0.24)]
        sampleSide = min(box.width, box.height) * 0.07
    }
}
