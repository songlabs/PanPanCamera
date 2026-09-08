# Architecture and ownership

```text
PanPanCameraApp (@StateObject CameraService, one app lifetime)
  └─ CameraView
      ├─ CameraPreview → AVCaptureVideoPreviewLayer
      ├─ CameraService (@MainActor, permission + published camera state)
      │   └─ CameraSession (one serial queue, one AVCaptureSession)
      │       ├─ AVCaptureDeviceInput (one front OR rear camera)
      │       ├─ AVCapturePhotoOutput
      │       └─ PhotoCaptureProcessor → CapturedPhoto
      ├─ BeautyState → BeautyParameters (pure Swift value type)
      └─ CameraToolState (panel/category/preset selection, fixed timer/ratio state)
```

## Camera ownership and threading

The app owns CameraService through `@StateObject`; recreating CameraView or its preview does not create a new session. The service lazily owns one CameraSession. Only the preview adapter can obtain its session reference, for connection to a preview layer; views do not start, stop, or configure the graph. The service has no beauty state or renderer.

CameraSession serializes configuration, input replacement and rollback, start/stop, capture submission, photo-result downsampling, and notification recovery on `camera.panpan.session`. Blocking AVFoundation calls never run in SwiftUI actions. Events are dispatched in queue order to the main actor. `@unchecked Sendable` on this owner documents queue isolation, not permission for unsynchronized access to its mutable fields.

The main-thread UIView owns preview-layer geometry, preview mirroring, and a rotation coordinator. Photo output has its own rotation coordinator on the session side. Both use the current camera device; neither maps interface-orientation numbers to sensor angles by hand. The preview uses aspect fill. Photos preserve the native sensor frame, so some edges outside the full-screen preview can appear in the result. Front preview and front photos are mirrored consistently; rear photos are unmirrored. UI orientation is portrait in 0.1; captured image orientation follows physical camera rotation. These policies need the device checks in `DeviceValidation.md`.

## Permission and lifecycle

Only camera permission is requested. Denied and restricted states have separate explanations; denied access offers the system Settings link. A return to the foreground rereads permission. A request-in-flight guard avoids duplicate prompts; after awaiting the system, the service rechecks whether the app still wants the camera active.

`scenePhase` and result visibility drive activation. Inactive/background scenes and the result cover stop the session. Returning to the camera restarts the existing session. Session interruptions show an explanation and interruption-ended notifications resume only when the app still wants the camera. Media-services reset attempts to restart the existing session; other runtime errors expose a retry action. A runtime error clears an in-flight capture and ignores a later result for that obsolete capture ID.

Camera switching disables competing shutter/switch actions, checks the other device exists, and uses begin/commit configuration. Actual position changes only after a new input is added. A failed switch restores the previous input; an exceptional failed rollback exposes a retryable failed state. There is no optimistic fake hardware toggle.

## Photo and memory boundary

Each shutter press creates AVCapturePhotoSettings, rechecks the live output's supported flash modes/device flash availability, applies capture rotation/mirroring, and calls `capturePhoto(with:delegate:)`. There is at most one active capture. Delegates remain retained by capture ID through final completion, even when a runtime error has invalidated a capture; an obsolete result cannot replace a newer one. Tool-sheet buttons are disabled during capture/switching to prevent competing result and panel presentations.

The delegate returns original photo data. On the session queue, ImageIO creates a maximum-2048-pixel display image with EXIF transformation applied. CapturedPhoto contains original Data plus an immutable UIImage for presentation; its unchecked sendability is limited to that immutable handoff. There is no preview screenshot capture, main-thread photo decoding, photo upload, file persistence, or library write. Closing the result clears the sheet item and releases the capture when SwiftUI finishes dismissal.

## UI-only editing boundary

Skin and face values start at 50, clamp to 0–100, reject non-finite inputs, and are independent per tool and category. Selection and panel close/reopen preserve values within the current CameraView lifetime. App relaunch resets them. Auto is just another independent draft value in 0.1. Filter and makeup selections are also drafts; no image-processing dependency imports exist.

The BeautyEngine and Rendering directories contain documentation only. Add a real frame/engine contract with the first processing feature, while keeping camera control, effect parameters, and rendering ownership separate. Future plans are not implemented APIs.

## Localization boundary

`L10n` defines 85 stable UI keys. Presentation uses `Text(L10n...)` or localized labels derived from model enums. Domain types do not depend on SwiftUI or localized strings. `Localizable.xcstrings` and `InfoPlist.xcstrings` each supply Japanese, Simplified Chinese, Traditional Chinese, English, and Korean. Japanese is the development/source language. Catalog entries are manually managed; automatic Swift string extraction is disabled to avoid replacing stable keys with implementation strings. Numerical slider text uses locale-aware number formatting. New UI copy must add an L10n case and all five translations.

## Apple API references

- [AVCam: Building a camera app](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app) — separation of capture work and UI, capture graph, camera switching and photo delegate lifetime. The current sample targets a newer iOS version; this project uses only its own iOS 17-compatible implementation.
- [AVCaptureDevice.RotationCoordinator](https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator) — separate preview/capture rotation angles.
- [AVCapturePhotoSettings.flashMode](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/flashmode) — use supported output modes for each capture; temporary hardware availability can change.
- [Localizing with a string catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog) — Apple String Catalog resources.
