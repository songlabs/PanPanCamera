# Local Face Analysis and Beauty architecture

Status: architecture replacement, model assets blocked. Reviewed against origin/main
`b0edd843e61a2b0c170f42518169b59c9d749a2c` on 2026-09-13. No model binary is bundled.
The default analyzer returns `unavailable`; Skin, Makeup and Face Shape bypass, while
filters and native capture/save remain usable. This is not a working pretrained
Beauty release. 尚未完成 Apple 平台 / 真机验收。

## Evidence and decision

Original decision: use Vision Face Landmarks as the PanPan Beauty foundation.

The inspected production flow was:

```text
AVCaptureVideoDataOutput (unrotated, unmirrored)
 -> CameraFaceFrameProcessor (synchronous inference on video queue, <=8 Hz)
 -> VisionFaceDetector / VNDetectFaceLandmarksRequest
 -> DetectedFace (image-relative) + separate Slim / Makeup smoothers
 -> BeautyImageProcessor (orientation / mirror / aspect-fill)
 -> Skin -> Makeup -> Face Shape -> Filter -> Core Image / Metal preview

PhotoOutput -> CGImage + EXIF -> VisionFaceDetector(CGImage, EXIF) -----+
                                                                  +-> BeautyImageProcessor
Silent Frame -> VisionFaceDetector(buffer, orientation)              |   -> render/encode -> PhotoKit
             -> separate reorientedFaces(mirrored:) -----------------+
```

Both detector call sites lived in `CameraFaceFrameProcessor` and
`FinalBeautyProcessor`; `CameraSession` owned the preview detector. Final PhotoOutput
and Silent Frame shared effect code but duplicated analysis/orientation branches.
`FaceCorrectionGeometry` consumed faceContour/eyebrow point arrays; Makeup consumed
eye, brow, nose and lip regions. The DEBUG still-image pipeline also had separate
`FaceRegion` / face-local `FacialLandmarks` contracts and mock providers.

New evidence: the old detector box/contour was not a complete skin-semantic boundary.
`BeautyImageProcessor.geometry` expanded width 10% and height 15% to approximate the
forehead. `BeautySkinMaskGenerator` used pixel-color rules, while
`SoftFaceMaskGenerator` / `EffectiveSkinMaskComposer` still bounded processing by face
geometry and could use a white per-region fallback when semantics were absent.
Each Skin stage classified its input again. Sparse landmarks constrained further
shape/makeup work. The renderer's temporary geometry overlay was always enabled.

Current decision: remove Vision, replace the analysis foundation with local Core ML
Face Detection + Dense Landmarks + Face Parsing, and make unavailable analysis explicit.
No old production or experimental Beauty pipeline remains as a fallback.

## New ownership and data flow

```text
Camera: native frame / photo acquisition, lifecycle and immutable configuration
  |
  + Preview: FaceAnalysisScheduler -> FaceAnalysisEngine -> FaceAnalyzer
  |                                  CoreMLFaceAnalyzer
  |                                    Detection / Landmarks / Parsing
  |                                  -> FaceAnalysisSmoother
  |                                  -> latest FaceAnalysisResult
  |     latest video frame + latest result + same BeautyConfiguration
  |       -> BeautyPreviewProcessor (one image/analysis transform)
  |       -> BeautyProcessor -> Core Image / Metal -> Preview
  |
  + PhotoOutput / Silent Frame: FinalBeautyProcessor.processSource
        -> normalize orientation/mirror
        -> FaceAnalysisEngine (new analysis for this final image)
        -> BeautyProcessor -> native-resolution render -> encode -> PhotoKit

BeautyProcessor: Skin -> Makeup -> Face Shape -> Filter
```

`FaceAnalysis/` owns model loading, output adaptation, semantic data, topology,
ephemeral tracking and scheduling. It does not perform Beauty or access the network.
`BeautyEngine/` owns effect policy, orchestration, quality and masks. Its Skin,
Makeup, FaceShape and Filters directories consume business values, not ML tensors.
`Rendering/CoreImage/` provides raster normalization, scalar import, CI filters,
vector displacement and reusable CIContext/Metal rendering. Camera does no inference
or mask/landmark work; its frame adapter creates a normalized image handoff.
Presentation only draws opt-in diagnostics and existing UI.

UI `0...100`, Auto, Skin/Shape/Makeup/Filter state and shutter-time parameter snapshots
are unchanged. The existing implemented shape controls remain slim/width/chin/
forehead/cheekbones; eye/nose/mouth shape controls were parameter-only at the inspected
baseline and are not newly claimed as implemented. Typed dense eye/lip/nose contours
are available to extend those effects once actual model topology is integrated.

## Model provenance and license investigation

No detector, dense landmark or parsing model is currently used by the shipped target.
`CoreMLFaceModelAssets.bundled == nil` is the explicit asset blocker, not a fake model.
No `.mlmodel`, `.mlpackage`, `.mlmodelc`, `.onnx` or `.tflite` was added. The model
resource check therefore correctly expects no ML resource in the target.

| Stage | Candidate/source checked | Evidence | Current decision |
|---|---|---|---|
| Detection | Google MediaPipe BlazeFace, full-range sparse | The official [BlazeFace model card](https://storage.googleapis.com/mediapipe-assets/MediaPipe%20BlazeFace%20Sparse%20Model%20Card%20%28Full%20Range%29.pdf) identifies Apache 2.0. The official [face detector guide](https://developers.google.com/edge/mediapipe/solutions/vision/face_detector) describes the detector models. | Commercial use/redistribution are supported by Apache 2.0 subject to its conditions. Candidate only: no pinned downloaded weights, Core ML conversion, numeric equivalence or iPhone performance validation in this change. |
| Dense landmarks | Google MediaPipe Face Mesh V2 | Official [Face Mesh V2 model card](https://storage.googleapis.com/mediapipe-assets/Model%20Card%20MediaPipe%20Face%20Mesh%20V2.pdf) describes 478 3D points and Apache 2.0. [MediaPipe source license](https://github.com/google-ai-edge/mediapipe/blob/master/LICENSE) is Apache 2.0. | Candidate only. Repository licensing is not used as a substitute for binding the exact weights to their model card, notices and checksum. No converted asset or production index map selected. |
| Parsing | [zllrunning/face-parsing.PyTorch](https://github.com/zllrunning/face-parsing.PyTorch), [yakhyo/face-parsing](https://github.com/yakhyo/face-parsing) | Code is offered under MIT; repositories identify CelebAMask-HQ training. The dataset owner's [agreement](https://github.com/switchablenorms/CelebAMask-HQ#dataset-agreement) restricts non-commercial research and commercial use of images/derived data. | Commercial pretrained-weight and redistribution rights are not sufficiently established for this App. Excluded. A third-party Core ML conversion labeled MIT does not resolve this provenance issue. |

This is a project acceptance decision, not a claim that every parsing model is
non-commercial. No sufficiently documented, converted, instance-aware parsing asset
was established in this investigation. To unblock: obtain an explicit commercial
weight/redistribution grant, or train with commercially licensed/consented data.

Before setting `bundled`, record the exact upstream URL/version, original and converted
SHA-256, code/weights/dataset grants, commercial and redistribution terms, notices,
conversion tool versions/commands, input normalization, channel order, crop policy,
output names/shapes/classes/topology, deployment target, size and device benchmarks.
Commit required license/NOTICE files with the asset. Add the model to Resources in
the app target and update `check_project.py`'s resource set. Validate prediction
equivalence against the source model, orientation, multiple faces and small faces.
Do not treat changing the nil manifest as sufficient integration.

## Model adapter export contract

`CoreMLFacePrediction` loads only an explicitly supplied local compiled URL, once per
adapter, on the analysis queue. It uses `MLModel.prediction(from:)` with feature
providers ([Apple API](https://developer.apple.com/documentation/coreml/mlmodel/prediction(from:))).
The shared inference CIContext and model objects are lazy and long-lived.

These adapters define a **future converted-model contract**, not drop-in support for
the candidates' original tensors:

- Input `image`: fixed-size BGRA image; exported preprocessing must handle RGB channel
  order, normalization and full-image resize aspect distortion consistently.
- Detector output: `[N,5]` x/y/width/height/confidence, normalized bottom-left; adapter
  validates finite unit boxes/scores, applies IoU NMS 0.5 and limits accepted faces to 8.
- Landmark/parser input `face_box`: Float32 `[4]`, normalized bottom-left x/y/w/h,
  selects this face instance. The full image remains available, including forehead.
- Landmarks: `[pointCount,2]` full-image bottom-left coordinates. A validated versioned
  `FaceLandmarkTopology` owns every raw index. Required face semantics must be mapped
  from the chosen model, not inferred from point positions. No production raw-index
  mapping is invented before a model is selected.
- Parsing: Float32 calibrated probabilities `[C,H,W]` (not logits), row zero bottom, full-image
  **instance** mask for the selected face. A generic scene segmentation copied onto
  each detection is invalid. The model/export must explicitly separate instances.
  Required classes: skin, hair, left/right eye, left/right brow, lips, mouth,
  background, glasses. Optional neck/ear/face are retained. Unknown/invalid dimensions,
  nonfinite/out-of-range values and missing protected classes fail closed.
- Per-pixel uncertainty remains in probabilities. The current parsing adapter uses
  aggregate confidence 1 after output validation; actual model calibration/quality
  gating remains part of the blocked asset integration. There is no measured claim
  about face coverage, accuracy, size, latency or thermal behavior.

## FaceAnalysisResult and coordinates

`FaceAnalysisResult` contains timestamp, normalized image size, orientation, mirror
state, outcome and `[AnalyzedFace]`. Each face binds temporary UUID trackingID,
confidence, detector box, `DenseFaceLandmarks`, optional `FaceSemanticMasks`.
Dense points and typed regions are image-relative; no face-local alternate contract.

```text
native pixels + EXIF/capture rotation
 -> FaceImageNormalization (rotate; apply display mirror once when final)
 -> normalized image, zero extent origin
 -> analysis coordinates [0,1], bottom-left
 -> one FaceAnalysisTransform for boxes, all points and every semantic raster
 -> render extent pixels, bottom-left (includes nonzero extents in component tests)
```

Masks store validated Float probabilities and a unit-raster-to-analysis affine map.
CGImage scanlines are populated top-first by explicitly reversing domain bottom-first
rows; Core Image imports them with color conversion disabled, then applies the same
transform as landmarks. An asymmetric raster XCTest checks actual import row order,
quarter turns, front mirror and nonzero origin; its Apple execution is pending.

Preview inference uses upright **unmirrored** pixels. The renderer rotates into the
preview coordinator's angle, applies residual horizon rotation, mirrors front-camera
pixels once, and aspect-fills the drawable. The same composed map handles analysis.
Final EXIF (all eight cases) is normalized before analysis; no face mirror runs after
inference. Both final source methods call the same `processSource`. The result size
must match the Beauty input size or face effects bypass; global filter still works.

## Semantic Skin foundation

Per-instance foundation is `max(0, skin - max(protected probabilities)) * confidence`.
Protected classes include hair, eyes, brows, lips, mouth, background, glasses, neck,
ear. A confident protected label wins even if skin erroneously also scores high.
The union takes maximum skin weights, never sums per-face Beauty intensity. Hair/eye/
brow/lip/glasses exclusions are also unioned across instances; background is per-face.

`SemanticSkinMaskComposer` combines this with original-image edge/detail protection
and inward feathering, reapplying semantic support after feathering to prevent outward
leakage. Detector boxes set conservative frequency radius only. They do not crop,
close, expand or synthesize the mask. Consequently forehead above the detector box
participates if parsing labels it skin. This establishes the code rule; actual
forehead/hairline quality remains blocked by the missing model and device acceptance.

Smoothing, brightening, tone consistency, blemish and dark-circle stages reuse that
same foundation. Brightening/smoothing/tone strengths multiply it once. Local repair
keeps bounded deltas and source detail. Dark circles additionally require typed eye
geometry and use the matching instance's semantic support for skin/reference samples.
The preserved ellipse describes the under-eye correction locality only, never facial
skin membership or forehead coverage. No RGB skin-color classifier remains.

## Failure behavior and multiple faces

| Situation | Skin | Makeup | Shape | Filter |
|---|---|---|---|---|
| Missing models, inference failure, no detected faces | Bypass | Bypass | Bypass | Enabled by existing configuration |
| Detection valid, parsing missing/invalid | Bypass, no box fallback | Valid dense regions can run | Valid dense regions can run | Runs |
| Parsing valid, landmarks missing | Skin can run; dark circles bypass | Bypass | Bypass | Runs |
| Partial dense regions | Skin unchanged by missing points | Only valid regions run | Only supported geometry runs | Runs |
| Configuration zero/disabled | Exact graph bypass | Bypass | Bypass | Follows configuration; disabled bypasses all |

Photo-only jobs with no applicable effect preserve the exact encoded source bytes;
Silent Frame keeps its existing native encoder fallback. Analysis failure no longer
turns a valid capture/filter into a processing failure. Decode/render/encode errors
still use the existing processing queue's failure and capacity-release behavior.

All accepted faces are analyzed, not only the largest. Box-overlap association is
one-to-one and rejects ambiguous candidates; a crossing can reset IDs rather than
mixing histories. IDs are session-local, not biometric recognition. Parsing is called
with each detected face's identity selection and returned in the same face value.
Makeup and Shape consume all supported faces. Slim fields are grouped per face and
accumulated without the old total-12-control limit. Maximum 8 faces is a bounded
resource policy, not a measured performance guarantee.

## Preview scheduling, threads and memory

- Camera publishes frames independently of inference. Analysis admission targets
  12 Hz and drops inputs when busy. A slow inference adds proportional cooldown.
- A serial worker owns analyzer/models. The engine also gates preview work across
  camera generations, so rapid rotations cannot queue retained images behind a model.
- Latest completed analysis is reused across render frames, with a 0.5-second stale
  limit. It does not disappear merely because a camera frame skipped inference.
  An explicit failure/no-face result clears face effects. Stopping/switching invalidates
  generation publication; stale results cannot enter the next generation.
- Temporal smoothing covers boxes, dense points and mask transforms/probabilities
  only for unambiguous matched identities. Current protected labels veto prior skin;
  topology/orientation/size/generation changes reset history. This is a conservative
  baseline tracker, not a learned occlusion/re-identification model.
- One historical result, one in-flight analysis, latest-only preview/silent stores,
  and one Metal command in flight. Makeup caches geometry only, not segmentation
  rasters or source images. Model/CIContext/Metal queue instances are long-lived.
- Final processing stays on the existing bounded photo worker with autoreleasepool;
  final ML runs again against the normalized native-size source. Only model inputs
  are resized; final CIImage/output dimensions remain native (quarter turns swap
  width/height). Existing total pending-photo cap and PhotoKit FIFO are unchanged.
- ML and CI entry points retain off-main dispatch preconditions. No photos, masks,
  landmarks, IDs or tensors are written to disk/network by analysis/debug code.

## Debugging and acceptance

All modes are off by default and return false in Release. Independent launch flags:

| Flag | Display |
|---|---|
| `-PanPanFaceBoxes` | All detection boxes |
| `-PanPanDenseLandmarks` | All dense indexed points |
| `-PanPanSkinMask` | Raw skin class overlay |
| `-PanPanHairMask` | Raw hair class overlay |
| `-PanPanFaceParsing` | Color overlay of skin/hair/eyes/brows/lips/glasses |
| `-PanPanFaceAnalysisTiming` | Numeric inference duration, outcome and face count only |

`-PanPanPhotoPerformanceDiagnostics` retains final `face_analysis`, effect graph,
render/encode, queue and save timing. Measure actual Preview FPS, memory peaks and
heat with Instruments/device tools; graph construction timing is not GPU execution.

UT coverage includes orientation/mirror, topology validation, asymmetric scalar
raster mapping, forehead/exclusions, multiple faces/identity ambiguity, busy/stale/
invalidated scheduling, parser/landmark/analysis unavailable, filter-only scenes,
zero bypass, preview/final configuration, both native capture routes, metadata/native
resolution, texture/alpha/tone numerical behavior, Makeup/Shape pixel regressions,
and saving queue failure/capacity behavior. Synthetic masks are test fixtures only.

Local Windows verification: Swift source parsing (Debug and default configurations),
five pure Swift Domain types and three camera helpers typechecked; project/source/
resource/localization checks and Python static tests passed. Foundation typechecking
was blocked by missing `errno.h`. Host XCTest launch was blocked before test execution
by missing `msvcrt.lib`, `oldnames.lib`, `msvcprt.lib`. No Xcode is available here.
No Apple SDK build, XCTest assertion execution, Core ML inference, CI kernel runtime,
Simulator or real-device validation is claimed. Actions trigger is reported separately
from terminal success; this task does not wait for CI or start TestFlight.

Final device acceptance remains mandatory: front/rear, portrait/landscape, front
mirror, live Preview, PhotoOutput, Silent Frame, multiple faces, glasses, bangs,
exposed forehead, profiles, different skin tones, weak/strong light. Verify continuous
forehead/cheek treatment, hairline halos, hair/eye/brow/lip preservation, face/neck
color continuity, stable shape/makeup, latency, FPS, peak memory and thermals.
Neck/ear classes are preserved but excluded from current face-skin policy; natural
face/neck appearance is not asserted and requires model/device tuning.

## Retired code

Removed VisionFaceDetector and all Vision production imports/conversion/outcome
types; the old DetectedFace/face-local FacialLandmarks/FaceDetecting adapters;
separate preview smoothers; RGB BeautySkinMaskGenerator, SoftFaceMaskGenerator,
EffectiveSkinMaskComposer, feature-mask fallback and SkinGeometryCache; 15% forehead
and 5%-per-side ROI expansion; BeautyImageProcessor; the parallel DEBUG mock photo
pipeline, providers and geometric debug overlays. Reusable texture, tone, local
repair, Makeup, Filter and Shape algorithms moved into BeautyEngine; rendering
primitives remain in Rendering. Obsolete adapter/mask tests were removed; numerical
and product tests that still apply were migrated to the explicit semantic contract.
