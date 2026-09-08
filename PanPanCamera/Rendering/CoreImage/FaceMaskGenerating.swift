import CoreImage

/// A job-local, opaque grayscale coverage image: RGB in 0...1, alpha 1, and the
/// exact supplied extent. Black means preserve source; white means full adjustment.
/// Return nil for no usable coverage, without constructing a CI graph for no faces.
/// Implementations run synchronously on the pipeline worker, using the unchanged
/// normalized bottom-left FaceRegion contract. No CIContext or image cache is needed.
protocol FaceMaskGenerating: Sendable {
    func makeMask(regions: [FaceRegion], in extent: CGRect) throws -> CIImage?
}
