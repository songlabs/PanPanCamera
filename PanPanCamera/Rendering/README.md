# Rendering — reserved, not implemented

Version 0.1 displays a live `AVCaptureVideoPreviewLayer` and captures with `AVCapturePhotoOutput`. It has no video-data output, pixel-processing pipeline, Core Image filter, Metal shader, or Core ML model.

`CoreImage/` and `Metal/` reserve separate renderer locations for later development. Keep future frame ownership, render scheduling, and engine contracts outside SwiftUI and outside permission/session control. Introduce them only with an actual local processing feature and device performance evidence.
