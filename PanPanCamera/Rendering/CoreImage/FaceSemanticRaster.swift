import CoreImage
import Foundation

/// The sole scalar-raster to render-pixel conversion. Both landmarks and masks
/// receive the same analysis transform before this unit-to-extent projection.
enum FaceSemanticRaster {
    static func image(_ plane: FaceSemanticPlane, in extent: CGRect) throws -> CIImage {
        // CGImage scanlines are top-first. The domain raster is bottom-first;
        // reverse rows explicitly rather than letting tensor/image origins differ.
        var scanlines: [Float] = []
        scanlines.reserveCapacity(plane.values.count)
        for row in (0..<plane.height).reversed() {
            scanlines.append(contentsOf: plane.values[(row * plane.width)..<((row + 1) * plane.width)])
        }
        let data = scanlines.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let bitmap = CGImage(width: plane.width, height: plane.height,
                bitsPerComponent: 32, bitsPerPixel: 32, bytesPerRow: plane.width * MemoryLayout<Float>.size,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [.floatComponents, .byteOrder32Little],
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw CoreImageRendering.Failure.renderFailed }
        // Masks are scalar data; do not apply a grayscale color transfer function.
        let raster = CIImage(cgImage: bitmap, options: [.colorSpace: NSNull()])
        let map = FaceAnalysisTransform(a: 1 / CGFloat(plane.width), d: 1 / CGFloat(plane.height))
            .then(plane.transform).then(.unitToRect(extent))
        let transformed = raster.transformed(by: CGAffineTransform(
            a: map.a, b: map.b, c: map.c, d: map.d, tx: map.tx, ty: map.ty))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        return try CoreImageRendering.grayMask(transformed.composited(over: black).cropped(to: extent), scale: 1)
    }
}
