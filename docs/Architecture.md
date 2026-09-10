# Architecture and ownership

```text
PanPanCameraApp (@StateObject CameraService, one app lifetime)
  └─ CameraView
      ├─ CameraPreview → AVCaptureVideoPreviewLayer fallback + Core Image/Metal Beauty surface
      ├─ CameraService (@MainActor, permission + camera state + BeautyParameters)
      │   └─ CameraSession (one serial queue, one AVCaptureSession)
      │       ├─ AVCaptureDeviceInput (one front OR rear camera)
      │       ├─ AVCapturePhotoOutput → FinalBeautyProcessor → CapturedPhoto
      │       └─ AVCaptureVideoDataOutput → CameraFaceFrameProcessor
      │           ├─ latest native SilentFrame
      │           ├─ latest-only BeautyPreviewFrameStore → BeautyPreviewRenderer
      │           └─ VisionFaceDetector → FaceDetectionDelivery → latest FaceDetectionFrame
      └─ CameraToolState (panel/category/preset selection, fixed timer/ratio state)
```

## Camera ownership and threading

The app owns CameraService through `@StateObject`; recreating CameraView or its preview does not create a new session. The service lazily owns one CameraSession. Only the preview adapter can obtain its session reference and latest-only Beauty frame store; views do not start, stop, or configure the graph. CameraService owns the shared user parameters, while CameraSession and Rendering own immutable snapshots and pixel work.

CameraService is the current application/state boundary inside the Camera directory. Camera exposes state, events, semantic failures and capture data; it does not reference Presentation, L10n or SwiftUI UI types. `Domain/CameraFailure` has only the existing capture/switch failure cases. Presentation maps them to unchanged localization keys. Domain remains independent of Apple UI and camera frameworks.

CameraSession serializes configuration, input replacement and rollback, start/stop, capture submission, result publication, and notification recovery on `camera.panpan.session`. Vision remains on `camera.panpan.faces`; Beauty preview rendering uses `camera.panpan.beauty-preview`; high-resolution processing and JPEG encoding use `camera.panpan.silent-encoding`. Blocking AVFoundation calls never run in SwiftUI actions. Events are dispatched in queue order to the main actor.

Vision runs synchronously on the separate serial `camera.panpan.faces` queue. Video buffers remain unrotated/unmirrored; the capture rotation coordinator supplies Vision's EXIF quarter turn. A lock-protected per-generation mailbox throttles admission, rejects obsolete results and bounds main-queue notifications to one. CameraService publishes only the latest result. See [FaceDetection.md](FaceDetection.md) for the coordinate contract, lifecycle and validation limits.

The main-thread UIView owns preview-layer geometry, preview mirroring, and a rotation coordinator. The original preview layer remains underneath as both the zero-strength path and render-failure fallback. A bounded 1280-pixel-long-edge Metal surface presents Core Image output only while an implemented Beauty effect is active and a face is available. It uses the same aspect-fill crop and explicit orientation/front-mirror policy. One retained camera frame and one in-flight command buffer bound preview backlog. Photo output has its own rotation coordinator on the session side. Photos preserve the native sensor frame, so some edges outside the full-screen preview can appear in the result. These policies need the device checks in `DeviceValidation.md`.

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

Each shutter press creates AVCapturePhotoSettings, rechecks the live output's supported flash modes/device flash availability, applies capture rotation/mirroring, and calls `capturePhoto(with:delegate:)`. There is at most one active capture. Delegates remain retained by capture ID through final completion, even when a runtime error has invalidated a capture; an obsolete result cannot replace a newer one. Tool-sheet buttons are disabled during capture/switching to prevent competing result and panel presentations.

The delegate returns original photo data. The shutter command snapshots the current `BeautyConfiguration`; the final worker performs Vision and native-resolution Core Image processing before ImageIO encoding. With Beauty bypassed or no detected face, PhotoOutput data remains byte-for-byte unchanged. The silent fallback continues to take the latest native VideoDataOutput pixel buffer and never uses a view screenshot or upscale. ImageIO then creates a maximum-2048-pixel display image, and the existing add-only Photos flow saves the final Data before presenting CapturedPhoto. There is no main-thread photo decoding, photo upload, face persistence, or network processing.

## Beauty processing boundary

Skin and face values start at 50, clamp to 0–100, reject non-finite inputs, and are independent per tool and category. Skin Auto is the overall strength. `BeautyConfiguration` maps overall, smoothing, brightening and tone to normalized immutable values shared by preview and final processing. Zero overall or no implemented effect is an exact bypass. Smoothing uses the existing texture reconstruction plus landmark/edge protection, brightening is a bounded local face-mask lift, and tone uses the existing neutral luminance-consistency pass.

There is still no reliable blemish, dark-circle or face-warp implementation; those controls remain parameter-only and the panel says so. Filter and makeup selections also remain drafts. There is no stable cross-frame face tracker or semantic skin segmentation; preview reuses the bounded latest Vision observation, and final capture runs the same detector contract on its own source image.

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

Presentation owns Views and localization. Application coordinates camera activity and processing state. Camera owns acquisition and capture-graph control. FaceTracking consumes unrotated buffers with explicit orientation and produces face/landmark results. Domain maps parameter snapshots. Rendering owns the shared Core Image effect definition, final encoder, and minimal Metal presentation bridge.

The implemented skin values map from 0–100 to normalized 0–1 engine inputs. UI selection itself never changes a value, and capture holds a value snapshot. Stable face tracking remains future work.

The scope guard permits Vision only in FaceTracking, video data acquisition only in Camera, Core Image only in Rendering, and Metal only in the Core Image preview presentation bridge. Core ML, network clients, movie recording and external dependencies remain rejected.

## Localization boundary

`L10n` defines 94 stable UI keys. Presentation uses `Text(L10n...)` or localized labels derived from model enums. `AppLanguage` supplies System Default plus the five compiled languages; `AppStorage` persists the stable raw value and the App root injects either its Locale or `autoupdatingCurrent` into SwiftUI. Domain types do not depend on SwiftUI or localized strings. `Localizable.xcstrings` and `InfoPlist.xcstrings` each supply Japanese, Simplified Chinese, Traditional Chinese, English, and Korean. Japanese is the development/source language. Catalog entries are manually managed; automatic Swift string extraction is disabled to avoid replacing stable keys with implementation strings. Numerical slider text uses locale-aware number formatting. New UI copy must add an L10n case and all five translations.

## Apple API references

- [AVCam: Building a camera app](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app) — separation of capture work and UI, capture graph, camera switching and photo delegate lifetime. The current sample targets a newer iOS version; this project uses only its own iOS 17-compatible implementation.
- [AVCaptureDevice.RotationCoordinator](https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator) — separate preview/capture rotation angles.
- [AVCapturePhotoSettings.flashMode](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/flashmode) — use supported output modes for each capture; temporary hardware availability can change.
- [Localizing with a string catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog) — Apple String Catalog resources.
