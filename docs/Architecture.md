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
      │           └─ VisionFaceDetector → FaceDetectionDelivery → latest FaceDetectionFrame
      └─ CameraToolState (panel/category/preset selection, fixed timer/ratio state)
```

## Camera ownership and threading

The app owns CameraService through `@StateObject`; recreating CameraView or its preview does not create a new session. The service lazily owns one CameraSession. Only the preview adapter can obtain its session reference and latest-only Beauty frame store; views do not start, stop, or configure the graph. CameraService owns the shared user parameters, while CameraSession and Rendering own immutable snapshots and pixel work.

CameraService is the current application/state boundary inside the Camera directory. Camera exposes state, events, semantic failures and capture data; it does not reference Presentation, L10n or SwiftUI UI types. `Domain/CameraFailure` has only the existing capture/switch failure cases. Presentation maps them to unchanged localization keys. Domain remains independent of Apple UI and camera frameworks.

CameraSession serializes configuration, input replacement and rollback, start/stop, capture submission, result publication, and notification recovery on `camera.panpan.session`. Vision remains on `camera.panpan.faces`; Beauty preview rendering uses `camera.panpan.beauty-preview`; high-resolution processing, encoding and thumbnail decoding use the independent serial `camera.panpan.photo-processing` worker. Its asynchronous PhotoKit completion advances the FIFO without blocking the camera queue or main actor. Blocking AVFoundation calls never run in SwiftUI actions. Events are dispatched in queue order to the main actor.

Vision runs synchronously on the separate serial `camera.panpan.faces` queue. Video buffers remain unrotated/unmirrored; the capture rotation coordinator supplies Vision's EXIF quarter turn. A lock-protected per-generation mailbox throttles admission, rejects obsolete results and bounds main-queue notifications to one. CameraService publishes only the latest result. See [FaceDetection.md](FaceDetection.md) for the coordinate contract, lifecycle and validation limits.

The main-thread UIView owns preview-layer geometry, preview mirroring, and a rotation coordinator. The original preview layer remains underneath as both the zero-strength path and render-failure fallback. A bounded 1280-pixel-long-edge Metal surface presents Core Image output only while an implemented Beauty effect is active and a face is available. It uses the same aspect-fill crop and explicit orientation/front-mirror policy. Face Correction consumes image-space landmarks, selects the largest/nearest-center face, and applies one feathered displacement map. Preview caches its map; each final capture builds a job-local map at native oriented resolution. One retained camera frame, one cached Preview map and one in-flight command buffer bound preview backlog. Photos preserve the native sensor frame, so some edges outside the full-screen preview can appear in the result. These policies need the device checks in `DeviceValidation.md`.

During the current TestFlight diagnosis, `FaceGeometryDebugMode.isEnabled` keeps one overlay visible without a Settings control. It receives the fitted face box, accepted contour and exact small-face warps from the production renderer operation; it neither runs Vision nor calls the older preview-layer projection helper. Setting that single internal flag to `false` disables the diagnostic frame handoff and drawing for a future App Store release.

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

The delegate returns original photo data. The shutter command snapshots the current `BeautyConfiguration`; an independent FIFO job owns the input while the final worker performs Vision and native-resolution Core Image processing before ImageIO encoding. With all photo effects bypassed, or no detected face and no active global filter, PhotoOutput data remains byte-for-byte unchanged. Filter-only captures skip Vision; global filters still process scenes without faces. The silent fallback continues to take the latest native VideoDataOutput pixel buffer and never uses a view screenshot or upscale. ImageIO creates a maximum-2048-pixel display image off-main. The existing add-only Photos flow saves final Data before updating `capturedPhoto` and the album thumbnail. Tapping that thumbnail explicitly presents a separate result snapshot; saves never automatically pause the camera. At most three accepted jobs, including the active processing/save, can be pending. Overflow is rejected before acquisition with the existing failure feedback. See [PhotoCapturePerformance.md](PhotoCapturePerformance.md) for timing diagnostics, FIFO/failure tests, backlog policy and outstanding device acceptance. There is no main-thread photo decoding, photo upload, face persistence, or network processing.

## Beauty processing boundary

Skin and face values start at 50, clamp to 0–100, and reject non-finite inputs. Each Auto control batch-writes its category's concrete values; a later concrete adjustment remains independent and does not change Auto or its siblings. `BeautyConfiguration` multiplies each normalized concrete value by its category's normalized Auto value for processing. A zero Auto value therefore bypasses its processing branch. Smoothing uses the existing texture reconstruction plus landmark/edge protection, brightening is a bounded local face-mask lift, tone uses the existing neutral luminance-consistency pass, and Preview Face Correction uses contour/eyebrow-driven local displacement.

The existing local blemish and under-eye skin stages remain unchanged. Separate eye/nose/mouth geometry controls remain parameter-only, and Face Correction is not applied to captured photos. Makeup and filters now share the immutable BeautyConfiguration and both native capture paths. Preview composes skin -> makeup -> face geometry -> filter; final capture composes skin -> makeup -> filter. Makeup reuses the existing Vision observations and temporal smoothing policy with a separate all-feature history; multi-face observations do not blend identities. There is no semantic skin segmentation or stable multi-person tracker. See [MakeupAndFilters.md](MakeupAndFilters.md) for algorithms, state semantics and acceptance limits.

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

Presentation owns Views and localization. Application coordinates camera activity and processing state. Camera owns acquisition and capture-graph control. FaceTracking consumes unrotated buffers with explicit orientation and produces face/landmark results. Domain maps parameter snapshots. Rendering owns the shared Core Image skin and face effects, final encoder, and minimal Metal presentation bridge.

The implemented skin and five Face Correction values map from 0–100 to normalized 0–1 engine inputs. UI selection itself never changes a value, and capture holds a value snapshot; the snapshot's Face Correction fields are deliberately ignored by final-photo geometry. Stable face tracking remains future work.

The scope guard permits Vision only in FaceTracking, video data acquisition only in Camera, Core Image only in Rendering, and Metal only in the Core Image preview presentation bridge. Core ML, network clients, movie recording and external dependencies remain rejected.

## Localization boundary

`L10n` defines 94 stable UI keys. Presentation uses `Text(L10n...)` or localized labels derived from model enums. `AppLanguage` supplies System Default plus the five compiled languages; `AppStorage` persists the stable raw value and the App root injects either its Locale or `autoupdatingCurrent` into SwiftUI. Domain types do not depend on SwiftUI or localized strings. `Localizable.xcstrings` and `InfoPlist.xcstrings` each supply Japanese, Simplified Chinese, Traditional Chinese, English, and Korean. Japanese is the development/source language. Catalog entries are manually managed; automatic Swift string extraction is disabled to avoid replacing stable keys with implementation strings. Numerical slider text uses locale-aware number formatting. New UI copy must add an L10n case and all five translations.

## Apple API references

- [AVCam: Building a camera app](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app) — separation of capture work and UI, capture graph, camera switching and photo delegate lifetime. The current sample targets a newer iOS version; this project uses only its own iOS 17-compatible implementation.
- [AVCaptureDevice.RotationCoordinator](https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator) — separate preview/capture rotation angles.
- [AVCapturePhotoSettings.flashMode](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/flashmode) — use supported output modes for each capture; temporary hardware availability can change.
- [Localizing with a string catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog) — Apple String Catalog resources.
