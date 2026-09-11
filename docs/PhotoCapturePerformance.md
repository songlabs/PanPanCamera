# Capture responsiveness and final-photo diagnostics

## Verified source baseline

Investigation started from clean `main`/`origin/main` at
`08f72add383a358e26090c8dfed267605bcb31a7`. No physical-device measurements
were available. The source showed two independent waits:

1. PhotoOutput's final delegate callback dispatched FinalBeauty processing to
   `camera.panpan.silent-encoding`. Only after Vision, effects and encoding did
   CameraSession call `captures.finish(id:)` and build the display thumbnail.
   Silent Frame occupied a sentinel registry ID through the same processing wait.
2. CameraService awaited add-only PhotoKit saving before clearing `isCapturing`.
   Publishing `capturedPhoto` then automatically opened a full-screen result,
   stopping the camera preview.

These are confirmed acquisition/UI coupling issues. They are not measurements
of Vision, a particular effect, GPU rendering or codec performance.

## Current lifecycle

```text
Shutter: snapshot BeautyConfiguration + create per-shutter diagnostics
  -> Session queue checks acquisition availability and bounded job capacity
  -> PhotoOutput: retain delegate through didFinishCaptureFor
       -> release registry slot/delegate and emit acquisition completion
     Silent Frame: take the original native buffer
       -> emit acquisition completion (no AV delegate/sentinel needed)
  -> Main actor clears isCapturing; shutter can be used again
  -> Independent FIFO job owns Data or SilentFrame + configuration + diagnostics
       -> Vision (only for enabled face effects)
       -> Skin graph -> Makeup graph -> Filter graph
       -> one full-resolution Core Image render -> original codec, quality 1.0
       -> oriented display thumbnail -> asynchronous add-only PhotoKit save
       -> publish saved photo, then advance to next job
  -> Update album thumbnail; opening the result is an explicit album-button tap
```

`capturedPhoto` remains the latest successfully saved final photo. A failed
processing/save result reports the existing capture failure and keeps the prior
saved photo. A result cover holds its own photo snapshot, so subsequent saves
cannot replace the image being viewed. Only explicit result presentation pauses
the preview. No panel styles, permissions or new localization keys were added.

The worker uses one utility-QoS serial queue. Final processing and display-image
decoding run there, never on main or the camera session queue. PhotoKit completion
returns to that worker before the next job starts. Serializing saving as well as
processing bounds encoded-image retention and preserves result order even when
PhotoKit is slow. Neither worker success nor failure mutates `isCapturing`.
Completed acquisition jobs survive camera switching/reset; their native input,
orientation, mirroring, metadata and parameters are already captured. A reset
still invalidates unfinished AV acquisition, retaining its delegate until the
late final callback without completing a newer capture.

### Backlog policy

At most **3 jobs total**, including the job currently processing or awaiting
PhotoKit, are accepted. CameraSession is the only submitter and checks capacity
before obtaining another native image. It submits the completed acquisition
before admitting the next one. At capacity, a shutter request reports the
existing capture failure without acquiring/dropping another photo. Already
accepted jobs are retained and saved in order; capacity returns on success or
failure. Diagnostic output records every admission, completion and rejection.

This is a conservative initial memory bound, not a device-certified capacity.
Silent jobs retain native video buffers until processing finishes; validate
buffer-pool pressure, FPS and peak memory in bursts before raising the limit.
There is no disk queue, cancellation system, task database or unlimited parallel
rendering. Jobs have app-process lifetime, with no guarantee of completion after
the OS suspends/terminates the app.

## Measuring on an iPhone

In a **Debug** Xcode launch, add `-PanPanPhotoPerformanceDiagnostics` and filter
console output for `[PhotoPerformance]`. Without this argument Debug does not
emit these logs; Release compiles out timing storage and logging entirely.
Every line contains a shutter UUID, `source=photo_output` or `source=silent_frame`,
and actual active photo-effect categories (`none`, `skin`, `makeup`, `filter`,
or their combinations). Preview-only Face Correction does not count as a final
photo effect. No images, facial coordinates or EXIF contents are logged.

| Stage | Measurement meaning |
| --- | --- |
| `shutter_requested` | Origin of the monotonic per-shutter timeline |
| `avcapture_submitted`, `avcapture_start` | Submission and AV willBeginCapture callback |
| `avcapture_didFinishProcessingPhoto`, `capture_file_data` | AV processing callback and fileDataRepresentation duration |
| `avcapture_didFinishCapture` | Final AV callback, including failure |
| `silent_frame_start`, `capture_data` | Native frame acquisition / availability of encoded AV source data |
| `capture_slot_released`, `shutter_ui_released` | Registry release and main-actor busy-state release |
| `job_enqueued`, `queue_wait`, `final_beauty_start` | FIFO admission, waiting duration and start of final work |
| `decode` | PhotoOutput ImageIO source decode; Silent Frame already has pixels |
| `vision_face_detection` | Synchronous final Vision detection and landmark conversion |
| `skin_graph`, `makeup_graph`, `filter_graph` | CPU graph/mask construction, including lazy CI operations |
| `core_image_render` | Synchronous final render, including deferred graph execution |
| `image_encode` | ImageIO destination creation/add/finalize, using the original codec or silent JPEG |
| `final_encoded`, `thumbnail_decode`, `final_processing` | Encoded image readiness, display decode and complete worker processing duration |
| `photokit_start`, `photokit_complete` / `photokit_failed`, `photokit_latency` | Authorization plus add-only save timing and success/failure |
| `photo_saved` | Successful PhotoKit completion |
| `total_shutter_to_capture_data` | Native capture latency |
| `total_capture_data_to_final_encoded` | Remaining AV callback wait plus queue/effects/render/encode; excludes thumbnail/save |
| `total_shutter_to_photo_saved` | Complete shutter-to-save latency |

Milestone `ms` values are offsets from the shutter; measured stages and `total_*`
values are elapsed durations. `vision_skipped`, `bypass_original_data`,
`bypass_silent_beauty`, `bypass_no_face`, failure markers and pending counts explain
missing/inapplicable work. A bypassed PhotoOutput preserves original bytes before
decode; silent capture must still render/encode its native buffer. Missing stages
are **not** zero-duration measurements.

Core Image defers pixel computation until render. Do not interpret `skin_graph`
as the full GPU cost of skin smoothing, or add forced intermediate renders to
make stage timings appear independent. This matches Apple's
[CIContext graph/render model](https://developer.apple.com/documentation/coreimage/cicontext).
The slot boundary follows Apple's
[final photo capture callback lifecycle](https://developer.apple.com/documentation/avfoundation/tracking-photo-capture-progress).

**No device latency values have been collected.** A 100–200 ms shutter-recovery
time is a target, not a result: PhotoOutput still waits for the real AVFoundation
final callback, whose latency depends on hardware and capture settings.

## Algorithm investigation and follow-up conditions

- **Preview landmarks:** CameraFaceFrameProcessor holds raw observations on its
  video queue, plus separate smoothed Slim/Makeup histories. FaceDetectionFrame
  has device ID, EXIF quarter turn, pixel size and sample-buffer timestamp;
  BeautyPreviewFrame has no equivalent freshness/device identity contract.
  Preview then applies residual rotation, mirroring and aspect-fill fitting.
  PhotoOutput uses its own dimensions, capture rotation and EXIF orientation;
  a matching normalized coordinate and field-of-view mapping between the photo
  and video sensor formats has not been demonstrated. SilentFrame carries its
  timestamp/orientation/mirror/metadata but no matched detection generation.
  Multi-face observations have no stable identities. Therefore both native
  final paths keep Final Vision; no unverified reuse interface is introduced.
  A follow-up needs same-device/generation, age in a common clock domain, raw
  unsmoothed coordinates, format/crop mapping and fallback tests for every
  rotation/mirror combination before reusing observations.
- **Skin masks:** Skin face/landmark geometry is built once per skin invocation.
  Smoothing, brightening and tone each call mask generation, but the latter two
  consume already-modified source pixels and different intensity configurations.
  Their detail/protection/effective masks are therefore not interchangeable.
  Blemish and dark-circle stages already share their protection mask computed
  from original pixels. Makeup caches geometry masks for matching faces, extent
  and active components; its lip/eye/brow/blush masks have different meanings
  from a skin mask. No masks or parameters were merged in this change.
- **Rendering:** FinalBeauty passes a CIImage through Skin -> Makeup -> Filter
  and materializes it once via `createCGImage`. Existing small mask rasters and
  local analysis graphs do not introduce a full-photo CGImage round trip between
  effects. No redundant full-resolution materialization was found to remove.
- **Codec / renderer:** Dimensions, quality `1.0`, codec selection, color space,
  EXIF normalization, front mirroring and final effect amplitudes are preserved.
  Codec changes, an explicit Metal final context, or geometry-only mask reuse
  remain unmeasured candidates, not established bottlenecks or delivered speedups.

## Validation boundary and device worksheet

New XCTest coverage includes acquisition release while a job is blocked, FIFO
configuration snapshots, bounded admission, decode/encode failures, delayed save
failure, original-byte bypass, and old result/error events during a new capture.
Existing Beauty/Filter/Makeup tests continue to cover both native image paths.
The optional host coordination test substitutes Apple image/save types and runs
the actual queue/registry/diagnostics in Debug and Release; it cannot validate
image processing or camera APIs and explicitly skips when Foundation cannot link.

Windows source parsing/project/script checks are not an Apple build or XCTest
run. **尚未完成 Apple 平台 / 真机性能与照片效果验收。**

On at least one real iPhone, record model, OS, source strategy, photo dimensions,
configuration values, warm/cold run and per-shot diagnostics. Measure each of:
none, Skin only, Makeup only, Filter only, Skin + Makeup, and all three. For each
front/rear camera and portrait/landscape/mirror combination, capture 5–10 attempts
and record accepted/rejected/saved counts, order, shutter recovery, queue depth,
stage latencies, Preview FPS, main-thread stalls, memory peak and heat trend.
Repeat Silent Frame and supported suppressed PhotoOutput separately. Check real
saved dimensions, direction, EXIF, skin/makeup/filter appearance and final quality,
including parameter changes between consecutive shots. Exercise PhotoKit denial,
camera interruption/reset and return from an explicitly opened result.
