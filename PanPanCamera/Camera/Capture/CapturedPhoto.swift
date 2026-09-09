import UIKit
import ImageIO
import Photos

/// Immutable data and an EXIF-oriented, downsampled display image.
/// Created on the session queue; UIKit only reads the image after main-actor delivery.
struct CapturedPhoto: Identifiable, @unchecked Sendable {
    let id = UUID()
    let data: Data
    let preview: UIImage

    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        self.data = data
        preview = UIImage(cgImage: thumbnail)
    }
}

enum PhotoLibrarySaver {
    static func save(_ data: Data) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return true
        } catch {
            return false
        }
    }
}
