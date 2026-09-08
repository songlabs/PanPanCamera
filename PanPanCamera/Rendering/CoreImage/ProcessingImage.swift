import CoreImage

/// An immutable, fully rendered CGImage with pixels already in display orientation.
/// No mutable pixel storage is exposed. CIImage graphs/buffers stay inside each job.
struct ProcessingImage: @unchecked Sendable {
    let cgImage: CGImage
}
