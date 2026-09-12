# Capture responsiveness and final-photo diagnostics

## Phase 2 baseline and confirmed cause

Investigation and implementation started from clean `main` and freshly fetched
`origin/main` at `068c3d7b6536b4610ac102d5545066ed693d18e8`.
In that revision, `PhotoProcessingQueue.startNextIfNeeded()` set `isProcessing`
before final processing, then cleared it only in `finish`, reached from the
PhotoKit callback. The effective schedule was `P1 -> S1 -> P2 -> S2`.
The camera acquisition slot was already independent, but the total limit of 3
included the job waiting for PhotoKit. Admission rejection and processing/save
failure all surfaced as `captureFailed`. A short `isCapturing` interval could
also disappear before the next visible UI frame.

These are source-confirmed scheduling and feedback problems, not measured
Vision/GPU/codec bottlenecks. No physical-device measurements were available.

## Current lifecycle and ownership

```text
Shutter: immutable BeautyConfiguration + capture UUID/diagnostics
  -> CameraSession checks native state AND processing capacity before acquisition
  -> PhotoOutput: keep delegate until didFinishCaptureFor, then release registry
     Silent Frame: take the original native buffer, with its metadata/orientation
  -> Enqueue bounded processing job; publish capacity before releasing shutter
  -> Main actor clears isCapturing and emits one successful-acquisition pulse

Processing worker (serial, utility): P1 -> P2 -> P3
                                    |     |     |
Save FIFO (serial, utility):         S1 -> S2 -> S3
```

P2 can process while S1 is waiting for authorization or PhotoKit completion.
Conversely, S1 can release capacity and publish its result while P2 is rendering.
There is one final render/encode at a time and one PhotoKit transaction at a time.
Neither worker synchronously waits on main, the other worker, or a semaphore.

`PhotoProcessingJob` owns native Data/SilentFrame, the complete immutable Beauty
configuration and diagnostics. Its capture UUID travels through the Save FIFO and
terminal result. A save entry contains encoded Data and the existing bounded
2048-pixel display thumbnail in `CapturedPhoto`, plus UUID and diagnostics. It
never holds the source job, native PixelBuffer, CI graph, geometry cache or Beauty
intermediates. Final processing runs in an autorelease pool. Final Makeup uses an
invocation-local cache; Preview keeps its existing exact-geometry cache.

All terminal results use the same FIFO, including processing failures, so a newer
failure cannot overtake an older save. Duplicate or late save callbacks are
ignored using the active save UUID. Queue counts are protected by a single lock;
callbacks are scheduled on a serial delivery queue and never executed under the
lock. Capacity snapshots have monotonic revisions so a delayed worker event
cannot overwrite the snapshot published at the acquisition boundary.

### Capacity and visible state

The production limit remains **3 total**, shared across both workers:

```text
pendingTotal = processingQueued + processingActive + saveQueued + saveActive
```

A failed processing entry briefly remains in the Save FIFO until its ordered
terminal result is delivered. Native acquisition is not counted as a processing
job: CameraSession is the sole submitter, permits only one native acquisition,
and checks capacity before acquiring it. Therefore other producers cannot consume
its slot while it is in flight; workers can only free capacity in that interval.

`CameraService.canCapture` combines native `CameraState.canCapture` with current
application capacity. At 3, the shutter dims/disables and a light processing
message appears. A count badge by the album button shows 1/2/3 outstanding photos.
A race-window admission rejection clears acquisition busy state without a severe
alert or a successful-acquisition pulse. Capacity returns on each terminal result.

Successful acquisition triggers one 0.90-scale/opacity pulse on the existing
80-point shutter. Reduce Motion keeps the opacity cue and omits scale. Processing
and save results never emit this pulse or modify a newer acquisition's busy state.
No sound, haptic system, preview flash or automatic result presentation is added.
The thumbnail still represents only the newest successfully saved photo. Opening
the album/result remains explicit and retains its own photo snapshot.

Failures distinguish native capture (`captureFailed`), final processing
(`processingFailed`), PhotoKit (`saveFailed`) and backlog state (`captureBacklogFull`,
not a `CameraFailure`). Processing/save failures preserve the last saved thumbnail.
The processing status and two new error messages are localized in all five locales.

## Safe computation reuse

Final Skin creates one `SkinGeometryCache` from the existing once-per-invocation
DetectedFace -> FaceRegion/FacialLandmarks conversion. Smoothing, brightening, tone
and local-correction mask construction reuse identical face ellipses and feature
protection geometry at the same extent. Cached nil geometry remains nil.

Detail protection is reused **only** for the identical original CIImage object,
same SkinRetouchScale and unchanged generator policy. A later stage's modified
image always recomputes detail. The original-source cache can then serve the local
correction stage without mistaking smoothed/brightened pixels for original pixels.

Effective intensity masks, semantic masks, source-derived tone/luminance masks,
and strict local-correction exclusions are not cached or merged. Geometry/extent
mismatches use the ordinary uncached path. Cache lifetime ends inside the job.
An internal uncached mode provides a pixel comparison reference for XCTest.

Makeup converts normalized landmarks to pixels once per face/extent for missing
components, then keeps each component's shape, feather, alpha, gain and blend
separate. Its existing hard/soft raster paths stay separate: feather changes the
raster bounds and possibly the sampling scale, so sharing that raster was not
proven equivalent. All Beauty/Makeup/Filter parameters and order remain unchanged.

## Diagnostics

In a Debug Xcode launch, add `-PanPanPhotoPerformanceDiagnostics` and filter for
`[PhotoPerformance]`. Every real shutter has one UUID. Release compiles out timing
storage and printing; disabled Preview diagnostics remain a shared no-op object.
No photo pixels, EXIF contents, device identifiers or face coordinates are logged.

| Data | Fields / events |
| --- | --- |
| Source | `source_selected`, `photo_output` / `silent_frame` |
| Native input | `input_width`, `input_height`, `input_pixel_format` |
| Resolved PhotoOutput | `resolved_photo_width`, `resolved_photo_height` |
| Image/data size | `decoded_width/height`, `final_width/height`, `photo_data_bytes`, `final_data_bytes` |
| Acquisition | `capture_requested`, `capture_data_ready`, `capture_slot_released`, `shutter_ui_released` |
| Processing | `processing_enqueue`, `processing_start`, `processing_end` |
| Saving | `save_enqueue`, `save_start`, `save_end`, `photo_saved` / `save_failed` |
| Waiting | `queue_wait_processing`, `queue_wait_save` |
| Stages | `decode`, `vision`, `skin_graph`, `makeup_graph`, `filter_graph`, `render`, `encode`, `thumbnail` |
| Totals | `shutter_to_capture`, `capture_to_processing`, `processing_total`, `save_total`, `shutter_to_saved` |
| PhotoKit | `authorization_start/end`, `authorization`, `performChanges_start`, `photokit_completion_callback`, `performChanges` |
| Backpressure | `pending_total`, `pending_processing`, `pending_save`, `processingQueued/Active`, `saveQueued/Active`, `backlog_rejected` |

Milestone `ms` values are elapsed from the shutter request; measured stage/interval
values are their own durations. Bypassed or failed paths naturally omit stages
that did not execute and emit bypass/failure markers. Silent Frame has no encoded
acquisition Data, so `photo_data_bytes=0`; its actual native buffer dimensions and
CV pixel format are logged. Compressed PhotoOutput may expose no pixel buffer;
that case explicitly says `encoded_no_pixel_buffer`, not an invented CV format.
Resolved dimensions describe the delivered processed photo, per Apple's
[photoDimensions contract](https://developer.apple.com/documentation/avfoundation/avcaptureresolvedphotosettings/photodimensions).

CIImage is lazy: `skin_graph`, `makeup_graph` and `filter_graph` measure graph/mask
construction; GPU evaluation is included in the one final `render`. These numbers
are not isolated GPU costs for each effect. There are no forced intermediate
full-photo renders merely to obtain stage timings.

### Explicit Metal A/B foundation

Debug flag `-PanPanFinalMetalContext` selects a long-lived explicit
`CIContext(mtlDevice:options:)` for both final source paths if a default Metal device
is available. Missing device falls back to the original context. Without that flag,
and in Release, the original automatic context remains in use. Diagnostics log
`final_context_automatic`, `final_context_explicit_metal` or `automatic_fallback`.

Both paths retain `.cacheIntermediates = false`, default working color management,
`.RGBA8`, original output color space/extent and alpha behavior. Automatic CIContext
may already use Metal; Apple's [Metal initializer documentation](https://developer.apple.com/documentation/coreimage/cicontext/init(mtldevice:options:)-26usb)
does not establish a speed advantage. The switch is for controlled device A/B, not
a claimed measured improvement.

## Investigated options left unchanged

- **Vision downsample:** keep full-resolution Final Vision for both sources.
  There are no small-face/multi-face/landmark-accuracy fixtures or device profiles
  establishing 1280/1600/2048 as safe. Falling back only on an empty result or
  incomplete returned landmarks cannot detect an entirely omitted small second
  face. Therefore no unvalidated default or speculative scaling path is enabled.
- **Preview landmarks:** PhotoOutput FOV/crop, session generation, sample identity,
  orientation/mirroring and timing are still not jointly proven. SilentFrame also
  has no proven detector-result identity for the exact buffer consumed by take().
  A future contract needs device ID, generation, native dimensions, common-clock
  timestamp, orientation, mirror, zoom, clean aperture/crop and exact buffer ID.
- **ROI:** existing feature rasters already use local bounds with expansion and
  four-sigma feather padding. Skin reconstruction/local corrections use full-source
  detail, blur and morphology; narrowing their ROI without full dependency support
  and edge fixtures could truncate influence. No ROI or shader math is changed.
- **Readiness coordinator:** the iOS 17 target supports the API. Apple's
  [coordinator contract](https://developer.apple.com/documentation/avfoundation/avcapturephotooutputreadinesscoordinator)
  couples main-thread shutter tracking to the exact settings sent to background
  capture. This app creates settings and retains/invalidate delegates on its
  session queue, with a separate SilentFrame strategy. Tracking, reset/late-callback
  cleanup and source-specific gating need a dedicated Apple-tested lifecycle
  change. Current native state/slot checks remain, combined with backlog capacity.
- Codec/quality, photo size, `.photoQualityPrioritization = .quality`, Filter recipes,
  Preview-only Face Shape and capture orientation/mirroring remain unchanged.

## Verification boundary and device worksheet

New/extended XCTest covers suspended S1 while P2/P3 finish, serial processing/save,
FIFO result UUIDs, count-3 admission, S1 completion during blocked P2, failed S1
followed by S2, duplicate/late save callbacks, processing failure order, configuration
snapshots, decode/Vision/render/encode/thumbnail failures, authorization rejection,
source-buffer release, backlog UI semantics, stale state revisions and acquisition
feedback. Synthetic image tests compare cached/uncached pixels (maximum 1/255
channel difference), transforms/nonzero extent, metadata/codec/oriented dimensions,
and Metal-unavailable fallback. Existing acquisition/reset/SilentFrame and image
processing tests remain in the same Xcode target.

Windows verification: Swift source parse, pure Swift domain/control typechecks,
project/localization/reference checks and Python scope/delivery checks are available.
The host coordination probe uses the real queue/registry/diagnostics and substitutes
only Apple image/save APIs; it now requires P2 to process while S1 is suspended.
This host lacks required C SDK headers (`errno.h`), so its Foundation compile/run is
skipped. No skipped test is counted as an executed PASS. Apple SDK typecheck, Xcode
Build/XCTest, Simulator and physical camera/PhotoKit tests are unexecuted here.

**尚未完成 Apple 平台 / 真机性能与照片效果验收。**
**尚未取得真机性能数据。**

For each front/rear camera, portrait/landscape and both source strategies, run:
no effects, Filter, Skin, Makeup, Skin + Makeup, Skin + Makeup + Filter. Make 10
consecutive shutter attempts, including Beauty 20 -> shot 1 -> Beauty 80 -> shot 2.
Record model/OS, input and saved dimensions, accepted/rejected/saved counts, pending
peak, capture latency, processing/save waits, Vision/Render/Encode/PhotoKit/total,
Preview FPS, CPU/GPU, peak memory and thermal state. Compare actual saved photos for
orientation/mirror, EXIF, resolution, texture, skin tone and Makeup/Filter appearance.
Repeat cold/warm and Metal default/explicit A/B with all other settings identical.
Exercise permission denial, save failure, interruption/reset and album presentation.

The bound of 3 is conservative, not device-certified. Jobs have app-process lifetime
and no new guarantee of finishing after OS suspension/termination. True speedup,
GPU contention, memory/thermal behavior and the remaining Vision/Skin/Render/Encode
hotspots require these measurements. Delivery only confirms the exact-SHA CI trigger;
queued/in_progress is not CI success and no TestFlight run is started.
