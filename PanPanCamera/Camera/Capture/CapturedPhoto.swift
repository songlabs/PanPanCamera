import UIKit
import ImageIO
import Photos

/// Immutable data and an EXIF-oriented, downsampled display image.
/// Created on the photo worker; UIKit only reads the image after main-actor delivery.
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
    static func save(_ data: Data, diagnostics: PhotoCaptureDiagnostics = .disabled,
                     requestAuthorization: () async -> PHAuthorizationStatus = {
                         await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                     }, saveAuthorizedPhoto: (Data, PhotoCaptureDiagnostics) async -> Bool = performChanges) async -> Bool {
        diagnostics.mark("authorization_start")
        let status = await requestAuthorization()
        diagnostics.mark("authorization_end")
        guard status == .authorized || status == .limited else {
            diagnostics.mark("authorization_failed")
            return false
        }
        return await saveAuthorizedPhoto(data, diagnostics)
    }

    private static func performChanges(_ data: Data, diagnostics: PhotoCaptureDiagnostics) async -> Bool {
        return await withCheckedContinuation { continuation in
            diagnostics.mark("performChanges_start")
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            } completionHandler: { saved, _ in
                diagnostics.mark("photokit_completion_callback")
                continuation.resume(returning: saved)
            }
        }
    }
}
