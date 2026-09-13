# Vision + local adaptive Skin architecture

Inspected after `git fetch origin`: local/main/origin/main all
`b89979088b8ff57c230f895a8c7dd7e764491a11`, clean tree, 2026-09-13.
Implementation is connected; visual quality and performance are not device-certified.
**尚未完成 Apple 平台 / 真机验收。**

## Decision record

**【原决定】** Core ML Face Detection + Dense Landmarks + Face Parsing. At the
baseline, bundled assets were nil. The default analyzer returned `unavailable`, so
Skin/Makeup/Shape bypassed. No pretrained model was integrated.

**【新证据】** PanPan is silent capture + natural skin treatment + simple face shape.
It does not take responsibility for professional retouching. Model conversion,
licensing, size, tuning and maintenance costs do not match the added product value.

**【当前决定】** AVFoundation + Apple Vision + Adaptive Skin Color Mask + Core Image /
the existing Metal preview renderer + PhotoKit. All local: 0 AI API, 0 server,
0 third-party Beauty SDK, 0 custom model licensing cost. Remove model scaffolding;
retain the shared DTO, normalization, scheduling and Final pipeline.

Vision locates faces/features. **Neither its box nor its contour is a skin mask.**
Color classification remains mandatory above the detector box.

## Ownership and pipelines

```text
Preview native frame (unrotated, unmirrored)
  -> orientation normalization -> Scheduler -> VisionFaceAnalyzer -> Smoother
  -> latest non-stale FaceAnalysisResult
  -> BeautyPreviewProcessor (same rotation/mirror/aspect-fill for pixels and points)
  -> BeautyProcessor: Skin -> Makeup -> simple Shape -> Filter -> Metal preview

PhotoOutput encoded data -> decode + EXIF normalization ----+
                                                          +-> FinalBeautyProcessor.processSource
Silent Frame native buffer -> rotation/mirror normalization +   -> fresh Vision analysis
                                                              -> same BeautyProcessor
                                                              -> final render -> encode -> PhotoKit
```

Camera retains acquisition, lifecycle and immutable shutter-time configuration. It
does not understand Skin algorithms. Apple shutter suppression still selects native
PhotoOutput when supported, otherwise the latest native VideoDataOutput buffer.
Permissions, maximum dimensions, metadata and highest-quality policy are unchanged.
Neither source captures a rendered preview screenshot.

Final analyzes its own normalized pixels at native resolution; no Preview coordinates,
mask, crop or history are reused. EXIF normalization handles all eight orientations,
zeros the extent origin and applies mirroring once. Vision consequently receives `.up`.

## Contract and scheduling

`FaceAnalysisResult`: timestamp, imageSize (pixels), orientation, mirrored, faces,
outcome (analyzed / failed). Successful no-face is an empty array. There is no model
availability/loading state. `AnalyzedFace`: ephemeral UUID trackingID, confidence,
boundingBox, FaceLandmarks.

Regions: faceContour, left/right eye, left/right eyebrow, nose, noseCrest, outerLips,
innerLips, left/right pupil. Missing features stay empty. Diagnostic points are computed
from regions, not raw indices. Coordinates are image-relative, normalized, bottom-left.
DTO/transform/smoother contain no Vision, CI, camera or ML types.

The adapter reuses face-local-to-image mapping from the Vision detector in Git history
(`b899790^`). It pins shipping revision 3 and the 76-point constellation, predating the
unchanged iOS 17 target. No beta/default future revision. Vision observations end in the
adapter. [Apple request documentation](https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest).

Scheduler retains one in-flight task, drops busy input, keeps no pending buffer queue,
expires old results and rejects invalidated generations. Shared-engine admission bounds
rapid camera switches. Policy starts at 1/12 s analysis interval and 0.5 s stale expiry:
adjustable values, not measured device parameters. Box/feature smoothing uses unambiguous
overlap identity, never array order. Crossings and rotation/mirror/size changes reset history.

## ROI, sampling and classification

SkinFaceROI combines face bounds with a forehead projection from the mouth-to-eye
direction, eyebrow center and eye separation. It can extend above the box and include
temple candidates. It neither closes the contour nor makes expanded geometry into skin.
Missing usable eyes/brows/lips fails closed, including uncertain partial/profile faces.

Two cheek patches below eyes/outside nose and one upper bridge patch above nostrils
form an 18x6 atlas. The existing long-lived CIContext reads 108 pixels once per face.
CPU work is bounded independently of photo dimensions. Clipped/neutral/dispersed or
insufficient samples bypass Skin; no white-mask fallback exists.

AdaptiveSkinColor converts sampled linear sRGB into encoded-sRGB YCbCr. Median chroma,
robust spread, inliers and confidence determine a per-person elliptical tolerance.
No target complexion/ethnicity threshold. Relative exposure gates reject deep shadows
and clipping but allow a brighter forehead with the same chroma. Synthetic cases cover
light/medium/dark complexions under neutral/warm/cool lighting.

The GPU graph uses CILinearToSRGBToneCurve before a 32³ cube, giving dark and light skin
uniform encoded-color resolution. The cube emits linear scalar coverage. An immutable
conversion grid is shared. CPU LUT work is bounded to 32³ entries per face, never 12/24 MP
pixel count; this and sample readback remain profiling targets, not proven speedups.

Generator Policy starts at maximum dimension 320 for Preview, 768 for Final. Classification,
detail/features and inward feather use this working size; the mask maps back to the original
extent. Final Beauty/render retain native resolution. Device tuning, including small faces,
glasses and fine hair, remains mandatory.

## Protection, forehead and mask reuse

FeatureProtectionMaskGenerator is recovered from Git history and adapted to image-relative
landmarks. Eyes/lips use filled protection polygons; brows/nose use rounded strokes.
Expansion/dilation plus Gaussian feather keeps a full exclusion plateau with a soft ramp.
Rasterization failure aborts the mask instead of losing protection. The existing
DetailProtectionMaskGenerator protects strong luminance/chromatic edges and glasses lines.

Classified pixels are restricted to the search ROI, feathered inward by multiplying
original support, then multiplied by inverse feature/detail protection. Faces union by
maximum, never add strength; feature exclusions union across faces. Per-face masks retain
tracking identity for dark-circle processing.

Matching forehead pixels above the detector box enter Skin. Obvious dark hair/background
is rejected independently of ROI expansion. Color cannot guarantee semantic separation
of skin-colored hair/background, heavy casts, occlusion or reflections. Real hairline
quality, diverse skin tones and forehead/cheek continuity need device acceptance.

BeautyProcessor builds one original-source SkinMaskResult per frame/job. Smoothing,
brightening, tone, blemish and dark circles reuse it; no effect reclassifies adjusted
input. Mask failure bypasses Skin while Makeup/Shape/Filter remain eligible. No-face /
Vision failure still permits Filter. Zero strengths return the identical input;
fully bypassed PhotoOutput preserves original encoded data.

## Shape, Makeup and UI

Slim retains continuous 12-zone contour displacement and temporal smoothing. Width
retains the simple contour side pair; Chin retains jaw-side/chin-center movement.
Gentle Eyes uses actual eye contours and bounded Core Image bump distortion, maximum
scale 0.06. Missing/too-small eyes bypass independently. No dense topology is introduced.

Forehead/hairline and cheekbone shaping now bypass because sparse points cannot reliably
locate these targets. Stored values and panel layout remain, with the existing unavailable
description. Eye spacing/height, nose and mouth shape were parameter-only and remain so.
The newly active gentle-eyes description is added in the same five languages.

Lip/blush/eye/brow Makeup preserves its algorithms and geometry cache using FaceLandmarks.
It precedes Shape because landmarks describe unwarped pixels. Filter recipes/UI are unchanged.

## Response and diagnostics

The baseline already released native capture ownership after acquisition, with separate
serial Processing and PhotoKit Save workers and combined capacity 3. These queues, camera
graph, permissions and UI interaction policy are preserved.

Final uses one analysis, one mask and a lazy effect graph followed by one full-resolution
render/encode. Tiny sample readback and bounded feature-geometry rasters are the explicit
intermediate materializations, not intermediate full-resolution photo renders/encodes.
CIContext/Vision requests are reused off main. See Apple's [performance guidance](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/CoreImaging/ci_performance/ci_performance.html)
and [processing guidance](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/CoreImaging/ci_tasks/ci_tasks.html).

Debug defaults off. Independent flags: -PanPanFaceBoxes (green), -PanPanVisionLandmarks
(yellow), -PanPanFaceROI (cyan), -PanPanSkinMask (actual shared mask, green, before Shape).
Mask overlay follows Shape and is Preview-only, never encoded into Final even in Debug.
Release flags are false; no diagnostic image/coordinate/mask is persisted/uploaded.
Normal user-requested PhotoKit photo saving remains the product behavior.

-PanPanFaceAnalysisTiming records worker elapsed time. Existing -PanPanPhotoPerformanceDiagnostics
records analysis, mask graph + sampling, effect graph setup, render, encode, PhotoKit save
and total time. Graph setup is not GPU time; Instruments must measure GPU mask execution,
FPS, peak memory and thermals.

## Removed code and validation

Removed CoreMLFaceAnalyzer, nil assets, prediction loader, Detection/Landmarks/Parsing
adapters, dense topology, FaceSemanticMask probabilities/raster import, semantic-only Skin
composer and obsolete model tests. Production has no custom model resources/fallback,
MediaPipe, TensorFlow Lite, Beauty SDK, URLSession or upload. Project membership/static
gates require Vision only in its adapter.

Tests cover observation/point mapping, orientation/mirror, tracking/scheduler, per-face
adaptation, forehead ROI/inclusion, hair/background/lip rejection, feature protection,
feather, multiple complexions/faces, failures/no-face/mismatch, one mask, exact zero bypass,
gentle eyes/unsupported shape and common full-resolution PhotoOutput/Silent Final. Existing
reconstruction/opacity/detail unit tests retain deterministic masks separate from classification.

Executed on Windows: project/resource/localization (64 app + 24 test sources; 122 UI keys
x five languages), 88-file Swift parsing, five Domain and three camera helper typechecks,
plist lint and diff checks. Python: 39 tests, 38 passed, one host runtime test skipped.
run_pipeline_tests.py was attempted; SwiftPM manifest linking failed before tests because
msvcrt.lib, oldnames.lib and msvcprt.lib are absent. No Apple SDK/Xcode Build, Apple XCTest,
Simulator, Vision inference, GPU pixels or device performance was executed locally.

Device matrix: front/rear, portrait/landscape, front mirror, Preview/PhotoOutput/Silent,
multiple faces, bangs, glasses, exposed forehead, diverse skin, warm/cool/weak/strong light.
Check forehead/cheek continuity, hair exclusion, brows, sharp eyes, natural lips, no halos,
stable Slim and Preview/Final consistency. Measure FPS, Vision/GPU mask time, Final render,
encode, PhotoKit save, shutter-to-save, peak memory and heat.

Delivery: commit -> push -> exact-SHA Actions trigger -> stop. No polling/TestFlight.
Triggered/queued/in-progress does not mean CI passed.
