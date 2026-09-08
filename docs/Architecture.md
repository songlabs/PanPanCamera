# Architecture and ownership

```text
PanPanCameraApp (@StateObject CameraService, one app lifetime)
  └─ CameraView
      ├─ CameraPreview → AVCaptureVideoPreviewLayer
      ├─ CameraService (@MainActor, permission + published camera state)
      │   └─ CameraSession (one serial queue, one AVCaptureSession)
      │       ├─ AVCaptureDeviceInput (one front OR rear camera)
      │       ├─ AVCapturePhotoOutput
      │       ├─ PhotoCaptureProcessor → CapturedPhoto
      │       └─ AVCaptureVideoDataOutput → CameraFaceFrameProcessor
      │           └─ VisionFaceDetector → FaceDetectionDelivery → latest FaceDetectionFrame
      ├─ BeautyState → BeautyParameters (pure Swift value type)
      └─ CameraToolState (panel/category/preset selection, fixed timer/ratio state)
```

## Camera ownership and threading

The app owns CameraService through `@StateObject`; recreating CameraView or its preview does not create a new session. The service lazily owns one CameraSession. Only the preview adapter can obtain its session reference, for connection to a preview layer; views do not start, stop, or configure the graph. The service has no beauty state or renderer.

CameraService is the current application/state boundary inside the Camera directory. Camera exposes state, events, semantic failures and capture data; it does not reference Presentation, L10n or SwiftUI UI types. `Domain/CameraFailure` has only the existing capture/switch failure cases. Presentation maps them to unchanged localization keys. Domain remains independent of Apple UI and camera frameworks.

CameraSession serializes configuration, input replacement and rollback, start/stop, capture submission, photo-result downsampling, and notification recovery on `camera.panpan.session`. Blocking AVFoundation calls never run in SwiftUI actions. Events are dispatched in queue order to the main actor. `@unchecked Sendable` on this owner documents queue isolation, not permission for unsynchronized access to its mutable fields.

Vision runs synchronously on the separate serial `camera.panpan.faces` queue. Video buffers remain unrotated/unmirrored; the capture rotation coordinator supplies Vision's EXIF quarter turn. A lock-protected per-generation mailbox throttles admission, rejects obsolete results and bounds main-queue notifications to one. CameraService publishes only the latest result. See [FaceDetection.md](FaceDetection.md) for the coordinate contract, lifecycle and validation limits.

The main-thread UIView owns preview-layer geometry, preview mirroring, and a rotation coordinator. Photo output has its own rotation coordinator on the session side. Both use the current camera device; neither maps interface-orientation numbers to sensor angles by hand. The preview uses aspect fill. Photos preserve the native sensor frame, so some edges outside the full-screen preview can appear in the result. Front preview and front photos are mirrored consistently; rear photos are unmirrored. UI orientation is portrait in 0.1; captured image orientation follows physical camera rotation. These policies need the device checks in `DeviceValidation.md`.

## Permission and lifecycle

Only camera permission is requested. Denied and restricted states have separate explanations; denied access offers the system Settings link. A return to the foreground rereads permission. A request-in-flight guard avoids duplicate prompts; after awaiting the system, the service rechecks whether the app still wants the camera active.

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

Each shutter press creates AVCapturePhotoSettings, rechecks the live output's supported flash modes/device flash availability, applies capture rotation/mirroring, and calls `capturePhoto(with:delegate:)`. There is at most one active capture. Delegates remain retained by capture ID through final completion, even when a runtime error has invalidated a capture; an obsolete result cannot replace a newer one. Tool-sheet buttons are disabled during capture/switching to prevent competing result and panel presentations.

The delegate returns original photo data. On the session queue, ImageIO creates a maximum-2048-pixel display image with EXIF transformation applied. CapturedPhoto contains original Data plus an immutable UIImage for presentation; its unchecked sendability is limited to that immutable handoff. There is no preview screenshot capture, main-thread photo decoding, photo upload, file persistence, or library write. Closing the result clears the sheet item and releases the capture when SwiftUI finishes dismissal.

## UI-only editing boundary

Skin and face values start at 50, clamp to 0–100, reject non-finite inputs, and are independent per tool and category. Selection and panel close/reopen preserve values within the current CameraView lifetime. App relaunch resets them. Auto is just another independent draft value in 0.1. Filter and makeup selections are also drafts; Vision detection does not apply effects.

The BeautyEngine and Rendering directories contain documentation only. FaceTracking now has a minimal detection-frame contract; an effect/rendering contract remains future work. Camera control, effect parameters, and rendering ownership stay separate.

## Detection module and next-stage plan

```text
Presentation
    ↓
Application / State
    ↓
Camera + FaceTracking + BeautyEngine
    ↓
Rendering

FaceTracking/                 detection and landmarks implemented
├── VisionFaceDetector        all faces and optional landmarks in one request
├── FaceDetectionFrame        latest image-relative result, no tracking IDs
├── FaceCoordinates           explicit unrotated capture-device mapping
└── FaceDetectionDelivery     throttling and invalidatable result mailbox

FaceTracker                   future work, not implemented
```

Presentation owns Views and localization. Application coordinates camera activity and processing state. Camera owns acquisition and capture-graph control. FaceTracking consumes unrotated buffers with explicit orientation and produces face/landmark results. BeautyEngine will interpret parameter snapshots and tracking inputs. Rendering will own image/GPU rendering, including a future BeautyRenderer and MetalPipeline. Domain holds UI-independent value contracts. Do not introduce Camera → Presentation, FaceTracking → SwiftUI or BeautyEngine → SwiftUI dependencies.

The UI's independent 0–100 values can later map to normalized 0.0–1.0 engine inputs; UI selection and the default value of 50 do not define an algorithm's neutral value. Detection and landmarks precede future stable face tracking, a BeautyEngine input model and Metal rendering.

The scope guard in `scripts/check_project.py` permits Vision only in FaceTracking and video data acquisition only in Camera. Metal, CoreML, CoreImage, photo-library access, network clients, movie recording and external dependencies remain rejected.

## Localization boundary

`L10n` defines 85 stable UI keys. Presentation uses `Text(L10n...)` or localized labels derived from model enums. Domain types do not depend on SwiftUI or localized strings. `Localizable.xcstrings` and `InfoPlist.xcstrings` each supply Japanese, Simplified Chinese, Traditional Chinese, English, and Korean. Japanese is the development/source language. Catalog entries are manually managed; automatic Swift string extraction is disabled to avoid replacing stable keys with implementation strings. Numerical slider text uses locale-aware number formatting. New UI copy must add an L10n case and all five translations.

## Apple API references

- [AVCam: Building a camera app](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app) — separation of capture work and UI, capture graph, camera switching and photo delegate lifetime. The current sample targets a newer iOS version; this project uses only its own iOS 17-compatible implementation.
- [AVCaptureDevice.RotationCoordinator](https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator) — separate preview/capture rotation angles.
- [AVCapturePhotoSettings.flashMode](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/flashmode) — use supported output modes for each capture; temporary hardware availability can change.
- [Localizing with a string catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog) — Apple String Catalog resources.
