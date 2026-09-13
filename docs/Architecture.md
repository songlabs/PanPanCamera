# Architecture and ownership

```text
PanPanCameraApp (@StateObject CameraService, one app lifetime)
  └─ CameraView
      ├─ CameraPreview → AVCaptureVideoPreviewLayer fallback + Core Image/Metal Beauty surface
      │   └─ production renderer geometry snapshot → temporary Face Geometry Debug Overlay
      ├─ CameraService (@MainActor, permission + camera state + BeautyParameters)
      │   └─ CameraSession (one serial queue, one AVCaptureSession)
      │       ├─ AVCaptureDeviceInput (one front OR rear camera)
      │       ├─ AVCapturePhotoOutput → release capture slot → PhotoProcessingQueue
      │       │   └─ FinalBeautyProcessor → CapturedPhoto → PhotoKit → saved thumbnail
      │       └─ AVCaptureVideoDataOutput → CameraFaceFrameProcessor
      │           ├─ latest native SilentFrame
      │           ├─ latest-only BeautyPreviewFrameStore → BeautyPreviewRenderer
      │           └─ FaceAnalysisScheduler → FaceAnalysisEngine → latest FaceAnalysisResult
      └─ CameraToolState (panel/category/preset selection, fixed timer/ratio state)
```

## Camera ownership and threading

The app owns CameraService through `@StateObject`; recreating CameraView or its preview does not create a new session. The service lazily owns one CameraSession. Only the preview adapter can obtain its session reference and latest-only Beauty frame store; views do not start, stop, or configure the graph. CameraService owns the shared user parameters, while CameraSession and Rendering own immutable snapshots and pixel work.

CameraService is the current application/state boundary inside the Camera directory. Camera exposes state, events, semantic failures and capture data; it does not reference Presentation, L10n or SwiftUI UI types. `Domain/CameraFailure` has only the existing capture/switch failure cases. Presentation maps them to unchanged localization keys. Domain remains independent of Apple UI and camera frameworks.

CameraSession serializes configuration, input replacement and rollback, start/stop, capture submission, result publication, and notification recovery on `camera.panpan.session`. Local FaceAnalysis runs independently on `camera.panpan.face-analysis`; Beauty preview rendering uses `camera.panpan.beauty-preview`; high-resolution processing, encoding and thumbnail decoding use the independent serial `camera.panpan.photo-processing` worker. Its asynchronous PhotoKit completion advances the FIFO without blocking the camera queue or main actor. Blocking AVFoundation calls never run in SwiftUI actions. Events are dispatched in queue order to the main actor.

FaceAnalysis runs on a dedicated serial worker, with latest-only admission independent of camera frame delivery. Core ML model adapters, topology, semantic masks and temporary identity tracking live in FaceAnalysis. Models are currently unavailable: no licensed, converted asset bundle is selected. Face effects bypass; filters and native capture still work.

Preview applies one shared coordinate map to image-space dense points and semantic rasters. Both final sources normalize orientation/mirror before fresh analysis, then call the same BeautyProcessor. All accepted faces can participate. Diagnostic boxes/landmarks/skin/hair/parsing overlays are off by default and disabled in Release. See [FaceAnalysisArchitecture.md](FaceAnalysisArchitecture.md) for the complete coordinate, license, scheduling, fallback and acceptance contract.

## Permission and lifecycle

Camera permission and add-only Photo Library permission are requested by their existing flows; Beauty adds no permission. Denied and restricted camera states have separate explanations; denied access offers the system Settings link. A return to the foreground rereads permission.

`scenePhase` and result visibility drive activation. Inactive/background scenes and the result cover stop the session. Returning to the camera restarts the existing session. Session interruptions show an explanation and interruption-ended notifications resume only when the app still wants the camera. Media-services reset attempts to restart the existing session; other runtime errors expose a retry action. A runtime error clears an in-flight capture and ignores a later result for that obsolete capture ID.

Camera switching disables competing shutter/switch actions, checks the other device exists, and uses begin/commit configuration. Actual position changes only after a new input is added. A failed switch restores the previous input; an exceptional failed rollback exposes a retryable failed state. There is no optimistic fake hardware toggle.

## Behavior test boundaries

- `CameraPermissionProvider` injects only authorization reads and the async request; its system implementation still calls AVCaptureDevice. CameraService tests suspend the request, change activity, resume authorization and inspect session commands.
- `CameraSessionControlling` is the small command surface consumed by CameraService. Production still lazily constructs CameraSession; tests record commands and deliver events through the same main-queue FIFO closure. They never obtain a preview session or mock the whole capture framework.
- `CameraInputReplacement.perform` executes the production begin/remove/can-add/add/rollback/commit transaction. Tests drive successful replacement, restored old input and an unconfigured result. CameraSession maps the unconfigured result to a stopped, failed session.
- `PhotoCaptureRegistry` is accessed only on the session queue. It owns processors, invalidates the active ID on runtime errors, removes every completed ID and permits only the current ID to publish. Processor tests feed the same processing/final transitions used by the AVFoundation delegate, assert weak-reference release and check a reset followed by capture B and a late callback from A.
- `CameraSessionLifecycle.recover` applies current running intent to reset/error commands. Tests check restart only while wanted; CameraService tests separately check that a late running event cannot overwrite inactive state.

These tests exercise production coordination, not hardware. Real notification delivery, input availability, camera rotation, flash, background/lock timing and media-services recovery remain in DeviceValidation.md. No test-only DEBUG behavior was added to the camera layer.

## Photo and memory boundary

Each PhotoOutput shutter press creates AVCapturePhotoSettings, rechecks the live output's supported flash modes/device flash availability, applies capture rotation/mirroring, and calls `capturePhoto(with:delegate:)`. There is at most one active acquisition. Delegates remain retained by capture ID through the final AV callback, even when a runtime error has invalidated a capture; an obsolete callback cannot complete a newer one. That callback releases the registry slot and `isCapturing` before final processing. Silent Frame acquisition completes when its native buffer is taken, without retaining a registry sentinel. Tool-sheet buttons are disabled only during acquisition/switching.

The delegate returns original photo data. The shutter command snapshots the current `BeautyConfiguration`; an independent FIFO job owns the input while the final worker performs fresh local FaceAnalysis and native-resolution Core Image processing before ImageIO encoding. With all photo effects bypassed, or no detected face and no active global filter, PhotoOutput data remains byte-for-byte unchanged. Filter-only captures skip face analysis; global filters still process scenes without faces. The silent fallback continues to take the latest native VideoDataOutput pixel buffer and never uses a view screenshot or upscale. ImageIO creates a maximum-2048-pixel display image off-main. The existing add-only Photos flow saves final Data before updating `capturedPhoto` and the album thumbnail. Tapping that thumbnail explicitly presents a separate result snapshot; saves never automatically pause the camera. At most three accepted jobs, including the active processing/save, can be pending. Overflow is rejected before acquisition with the existing failure feedback. See [PhotoCapturePerformance.md](PhotoCapturePerformance.md) for timing diagnostics, FIFO/failure tests, backlog policy and outstanding device acceptance. There is no main-thread photo decoding, photo upload, face persistence, or network processing.

## Beauty processing boundary

The existing 0–100 / Auto parameter semantics and shutter-time configuration snapshots remain. BeautyEngine owns one product order: Skin -> Makeup -> Face Shape -> Filter, shared by Preview and final photos. Semantic parsing is the only skin foundation. All Skin stages reuse it, with detail/edge protection; missing parsing never substitutes a face box. Dense typed landmarks drive Makeup and Shape. Separate eye/nose/mouth Shape controls remain parameter-only.

FaceAnalysis owns local Core ML adaptation and tracking; Camera owns acquisition; Rendering owns shared pixel/Metal primitives; Presentation owns UI. Domain parameter types remain pure Swift. Scope checks forbid production Vision and networking, confine Core ML to FaceAnalysis, and retain a single AVCaptureSession. No model binary has been approved/bundled; actual face effects remain unavailable until asset integration and Apple/device validation described in [FaceAnalysisArchitecture.md](FaceAnalysisArchitecture.md).

## Localization boundary

`L10n` defines 94 stable UI keys. Presentation uses `Text(L10n...)` or localized labels derived from model enums. `AppLanguage` supplies System Default plus the five compiled languages; `AppStorage` persists the stable raw value and the App root injects either its Locale or `autoupdatingCurrent` into SwiftUI. Domain types do not depend on SwiftUI or localized strings. `Localizable.xcstrings` and `InfoPlist.xcstrings` each supply Japanese, Simplified Chinese, Traditional Chinese, English, and Korean. Japanese is the development/source language. Catalog entries are manually managed; automatic Swift string extraction is disabled to avoid replacing stable keys with implementation strings. Numerical slider text uses locale-aware number formatting. New UI copy must add an L10n case and all five translations.

## Apple API references

- [AVCam: Building a camera app](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app) — separation of capture work and UI, capture graph, camera switching and photo delegate lifetime. The current sample targets a newer iOS version; this project uses only its own iOS 17-compatible implementation.
- [AVCaptureDevice.RotationCoordinator](https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator) — separate preview/capture rotation angles.
- [AVCapturePhotoSettings.flashMode](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/flashmode) — use supported output modes for each capture; temporary hardware availability can change.
- [Localizing with a string catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog) — Apple String Catalog resources.
