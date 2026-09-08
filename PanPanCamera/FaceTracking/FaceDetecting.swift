/// Image must already be display-oriented, including EXIF mirroring. Implementations
/// return normalized bottom-left rectangles relative to that exact image.
/// The pipeline calls detection synchronously on its worker queue, never on main.
/// The image parameter lets the same coordination run with native images and host
/// test fixtures; neither the protocol nor the pipeline imports Vision.
protocol FaceDetecting<Image>: Sendable {
    associatedtype Image: Sendable
    func detectFaces(in image: Image) throws -> FaceDetectionResult
}
