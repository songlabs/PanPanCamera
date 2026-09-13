# Vision face detection

> Historical implementation/performance record. The analysis and Beauty architecture below was superseded on 2026-09-13 by [FaceAnalysisArchitecture.md](FaceAnalysisArchitecture.md). Prior Vision/model/geometry descriptions and measurements do not describe the new pipeline. Custom models have been removed; current Apple/device acceptance remains pending.


## Repository investigation

The implementation began from a clean `main` checkout at `483fa1a`. There was one
`AVCaptureSession`, a `.photo` preset, a direct aspect-fill `AVCaptureVideoPreviewLayer`,
and an `AVCapturePhotoOutput`. There was no video data output, Vision import, processor
or rendering implementation. BeautyEngine and Rendering were documentation placeholders.

CameraService is the main-actor state/permission boundary. CameraSession owns graph
mutations, capture and lifecycle recovery on `camera.panpan.session`. CameraView's
scene activity and captured-photo cover drive start/stop. Switching already has an
input replacement/rollback transaction. Preview owns a device RotationCoordinator;
photo capture owns another coordinator. Both front preview and front photos explicitly
mirror. Info.plist permits portrait UI only; physical photo/preview compensation can rotate.

Existing XCTest covered permission, session commands, rollback, photo delegate lifetime,
state, localization and UI draft values. Screenshot mode is a Debug-only synthetic
background, not camera evidence. The scope checker prohibited Vision/video data output;
it now admits only these necessary additions in their respective modules.

## Data and API

`VNDetectFaceLandmarksRequest` locates all faces and their landmarks in a single request.
No `inputFaceObservations` filter or primary-face selection is set. One request is reused
on the serial video queue; each accepted pixel buffer gets a short-lived
`VNImageRequestHandler`. There is no image copy, UIImage conversion, tracking history,
third-party SDK, custom model, effect rendering, file storage or network upload.

CameraService's `faceDetection` is the latest `FaceDetectionFrame`, or nil when cleared.
Each face has a Vision normalized bounding box, confidence and a dictionary of available
landmark regions. Supported regions are leftEye, rightEye, leftEyebrow, rightEyebrow, nose, noseCrest, outerLips,
innerLips and faceContour. Missing or empty regions are omitted. All landmark points
are converted from face-relative into image-relative normalized coordinates.

Frame metadata consists of the EXIF quarter turn, source device ID, actual buffer size,
sample presentation timestamp and outcome. The timestamp is media time, not a wall-clock
date or a tracking ID. There are no stable face IDs. The array may contain zero, one or
many faces; its order carries no tracking or beauty-selection policy.

Successful no-face frames have `faces = []` and outcome `detected`. A Vision failure or
missing pixel buffer publishes an empty frame with `visionFailed`/`missingPixelBuffer`.
The next eligible frame retries without stopping preview or turning a Vision error into
a photo-capture error. If the video output/raw connection is unsupported,
`isFaceDetectionAvailable` is false and preview/photo capture remain usable.

## Frame acquisition and performance

The session adds one optional `AVCaptureVideoDataOutput`. The same callback stores at
most one native silent-capture frame and at most one Beauty preview frame; it is never
a view screenshot. Automatic buffer
dimensions request AVFoundation's preview-sized output instead of full photo resolution.
The output prefers a supported native bi-planar YUV format, disables analysis stabilization,
and sets `alwaysDiscardsLateVideoFrames = true`. It does not alter the photo preset,
camera frame rate, photo rotation, photo mirroring or original capture delegate path.

`camera.panpan.faces` is a serial utility queue separate from both main and session queues.
Vision performs synchronously inside an autorelease pool on that queue. Late frames are
discarded by AVFoundation; frames delivered during the detection cooldown are skipped.
No asynchronous per-frame tasks or application buffer arrays are created.

`FaceDetectionDelivery` guards admission with a short NSLock; the lock is never held
while Vision runs or while invoking a consumer. A generation allows at most 8 starts/sec.
After a request it waits at least 50 ms and at least the request's own elapsed duration,
as well as respecting the 125 ms start interval. Slow requests therefore reduce cadence.
The first frame after a generation change may start immediately. Across all generations,
the shared serial queue and detector allow only one request at a time.

Admission also remains closed until main consumes the single pending result. A stalled
main thread cannot accumulate result callbacks from a running generation. Only small
value results cross to main. Silent and Beauty stores each replace one retained pixel
buffer; the Beauty renderer additionally admits one command buffer and drops superseded
frames. This bounds application backlog. Actual capture-pool pressure,
Vision latency, Preview FPS, CPU, memory and thermal behavior still require device profiling;
the design does not establish a measured FPS or CPU target.

## Coordinate contract

1. The video output connection explicitly has rotation angle 0 and mirroring false,
   for front and rear cameras. Its buffer is the unrotated camera image.
2. The current device's RotationCoordinator capture compensation is rounded to the nearest
   EXIF quarter turn: 0/up, 90/right, 180/down, 270/left. Angles wrap at 360, including negative
   equivalents. Non-finite/missing orientation skips analysis and clears results until available.
   CameraPosition and UIDeviceOrientation raw values are never substituted for sensor angles.
3. Vision reports boxes and image-relative points in its oriented, unmirrored image,
   with origin at bottom-left. Given a Vision point `(x,y)`, the inverse orientation plus
   origin conversion yields unrotated capture-device coordinates as follows:

   | Vision orientation | Capture-device point (top-left origin) |
   | --- | --- |
   | up | `(x, 1-y)` |
   | right | `(1-y, 1-x)` |
   | down | `(1-x, y)` |
   | left | `(y, x)` |

4. The raw detection contract can be projected through
   `layerPointConverted(fromCaptureDevicePoint:)`, whose preview connection/layer owns
   rotation, mirror, geometry and aspect-fill cropping. Production Beauty does not mix
   that projection with its Metal surface: it applies the display quarter-turn and any
   residual horizon rotation to both CIImage and faces, mirrors both once for the front
   camera, then applies the same centered aspect-fill affine transform and target crop.
   `FaceCorrectionGeometry` therefore receives normalized faces already fitted to the
   final Metal drawable.
5. The active Face Geometry Debug Overlay consumes the renderer's final pixel-space
   `FaceGeometryDebugSnapshot`. Its only display conversion scales drawable pixels to
   the Preview layer bounds and flips bottom-left Core Image Y to top-left UIKit Y. Safe
   area, screen size, `layerPointConverted` and a second mirror do not enter that step.
6. PhotoOutput passes the encoded CGImage and its EXIF orientation to Vision, then applies
   the same orientation to `CIImage`; Vision's normalized oriented coordinates therefore
   map directly into that extent. Silent capture detects in capture orientation, applies
   `reorientedFaces(... mirrored:)`, and uses the matching mirrored EXIF orientation for
   `CIImage`, so its final faces and pixels also share one coordinate space.

The capture and preview coordinator angles may differ because preview includes view
orientation. Conversion returns to unrotated camera space before applying the actual
preview transform, so their angles are not assumed equal. EXIF quantization leaves at
most 45 degrees of tilt in the Vision image; the remaining tilt does not alter the inverse
coordinate contract. Recognition during motion/tilt requires hardware validation.

Portrait-only interface configuration is unchanged. Both physical landscape directions
still need testing on both cameras. If UI landscape support is added later, the preview
layer's actual geometry must be exercised again; this change does not enable it.

## Lifecycle and development overlay

Each activation, input replacement or change of EXIF quarter turn uses an immutable
frame delegate context. Old mailboxes are invalidated before replacing/removing delegates.
Already queued old buffers cannot publish into the new context. Already queued result
notifications yield nil after invalidation. The single shared video queue also prevents
an old finishing request and a new camera request from executing concurrently.

Explicit stop/background/result presentation, interruption, runtime error and observed
session stop invalidate detection and remove the sample delegate. An already executing
synchronous Vision call may finish; its result is discarded and no subsequent work is
admitted. Detection resumes only while authorized, wanted, running and uninterrupted.
The main actor additionally clears/rejects results during inactivity, switching and
non-running status. Output setup failure preserves the original camera path.

For the current device/TestFlight investigation, `FaceGeometryDebugMode.isEnabled` is
`true`, so no launch argument or hidden Settings page is required. Green is the fitted
primary face box, yellow is the contour accepted by `FaceCorrectionGeometry`, cyan is
the exact small-face radius, pink marks its centers, and orange arrows show the applied
visible offsets. The text block reports UI/normalized/Auto/effective strength, fitted
face width, signed offsets, capture/display orientation, preview angle, mirroring and
accepted contour count. The overlay reuses fixed Core Animation layers, skips unchanged
snapshots and emits no per-frame coordinate logs. Set the single internal flag to `false`
before the future production App Store release to stop both diagnostic frame handoff and
drawing. No face data is stored, exported or sent to a network.

## Verification boundary

- Project/catalog checks: passed locally, including 35 app source and 8 test source memberships,
  all existing localization keys/placeholders and continued dependency/network/rendering guards.
- Existing Python suite: 27 tests passed locally.
- Swift parse: 43 files parsed for the iOS target. Host typecheck: four pure Swift Domain
  files and three existing pure Swift camera-control helpers passed.
- A separate Foundation model/coordinate/mailbox host typecheck was attempted, but this
  Windows installation lacks `errno.h` required by SwiftOverlayShims. It did not validate
  those types. The existing syntax-check script remains usable without introducing that SDK dependency.
- Xcode build and XCTest commands were attempted but `xcodebuild` is unavailable on Windows.
  Nine FaceDetectionTests and three CameraServiceTests were added (45 methods in the suite).
  These cover quarter turns, coordinate origin/inverse rotation, aspect-fill bounds, one-time
  mirror projection, optional landmarks, synthetic zero/one/multiple Vision observations,
  bounded admission/cooldown, errors, invalidation, interruption, inactivity and output fallback.
  They have not been executed on Apple platforms. Projection tests use known mathematical
  layer transforms; they do not execute an attached camera's preview-layer conversion.
- No device camera, live Vision inference, performance measurement or final CI result is claimed.
  Follow [DeviceValidation.md](DeviceValidation.md). **尚未完成 Apple 平台 / 真机验收。**

Delivery policy for this task is local validation, commit, push and confirmation that the
matching SHA triggered iOS CI; stop after trigger confirmation without waiting for CI completion.

## Apple references

- [VNDetectFaceLandmarksRequest](https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest)
  documents detection of all faces before landmark analysis.
- [RotationCoordinator](https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator)
  supplies separate capture and preview compensation angles.
- [videoRotationAngle](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/videorotationangle)
  describes video-output buffer rotation and its processing cost.
- [layerPointConverted](https://developer.apple.com/documentation/avfoundation/avcapturevideopreviewlayer/layerpointconverted(fromcapturedevicepoint:))
  defines the unrotated, normalized top-left capture-device coordinate system and layer conversion.
- [Preview-sized buffers](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/deliverspreviewsizedoutputbuffers)
  documents automatic buffer sizing.
- [TN2445: Handling frame drops](https://developer.apple.com/library/archive/technotes/tn2445/_index.html)
  explains late-frame discard, the queue bound and capture-pool pressure from slow consumers.
