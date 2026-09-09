/// Called once per photo on the existing pipeline worker, with the same oriented
/// image used for face detection. Results may be missing, partial or reordered;
/// each result carries its own FaceRegion. Failure means no additional protection.
/// Implementations need no camera or preview state. The image is not retained.
protocol FaceLandmarkDetecting<Image>: Sendable {
    associatedtype Image: Sendable
    func detectLandmarks(in image: Image, regions: [FaceRegion]) throws -> [FacialLandmarks]
}
