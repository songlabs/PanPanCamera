# Makeup and filters: implementation and acceptance boundary

> Historical implementation/performance record. The analysis and Beauty architecture below was superseded on 2026-09-13 by [FaceAnalysisArchitecture.md](FaceAnalysisArchitecture.md). Prior Vision/model/geometry descriptions and measurements do not describe the new pipeline. Current model assets and Apple/device acceptance remain blocked.


Investigated baseline: `main` at `f7ed3398382e784ed91e4df2e2f7f49ad29ef594`, clean and equal to fetched `origin/main`.
The original panels only selected `CameraToolState.makeupTool` / `filterPreset` and displayed unimplemented notices.
There was no color-effect configuration or renderer call from either camera output path.
Both preview and final processing also bypassed all work when there was no face.

## Controls and state

Both panels now use `PanelContainer(compact: true)`, the same `0.38`/large detents,
28-point corner radius, system NavigationStack header/close behavior and 16/4/8
horizontal/top/bottom padding as Beauty. Their title/percentage, caption help,
44-point slider and three-column compact grid use the Skin panel's existing metrics.
No meaningless category segment was added. DEBUG screenshot mode still forces large;
its screenshots cannot establish the normal device detent height.

`BeautyParameters` owns all four groups. Makeup uses independent per-tool values,
0...100 with default 50, without multiplying by Skin Auto or Face Auto. Selecting a
tool changes the displayed control, not the other makeup values. Thus all four makeup
effects initially have strength 50. Each non-original filter retains its own strength
(default 50). Original is the initial preset and always reports 0; its slider is disabled.
Selecting Original disables only the global filter, preserving other enabled effects.

UI bindings target `CameraService.beautyParameters`. Its existing didSet publishes
one immutable `BeautyConfiguration`, now containing `MakeupConfiguration` and
`FilterConfiguration` with 0...1 values. Nonfinite values are rejected by UI state
and clamped to zero in renderer configuration. Existing skin/face batch semantics
and face displacement ranges are unchanged.

## Processing

Preview: native VideoDataOutput buffer + latest existing Vision observation + configuration
snapshot -> orientation/residual rotation/mirror/aspect fill -> existing skin stages ->
makeup -> existing face geometry -> global filter -> existing Core Image/Metal overlay.
No effective stage returns the original native preview layer. Global filters work without faces.

Makeup is applied before face geometry deliberately: Vision landmarks describe unwarped
pixels, so the combined face and makeup move together through the existing displacement
field. Applying an unwarped mask after geometry would misalign features. Each color stage
consumes the preceding stage's result; it never replaces it with the original source.

Capture: the existing shutter-boundary configuration snapshot is passed to both
`FinalBeautyProcessor.processPhotoData` and `processSilentFrame`. PhotoOutput decodes
the original capture; silent capture reads the native video buffer. Each applies the
existing orientation/mirror handling, the same skin -> makeup -> global filter sequence,
then native-size ImageIO encoding and the existing capture-result/Photos save path.
Filter-only captures skip Vision entirely; no-face scenes still receive the filter.
Disabled/zero PhotoOutput jobs return original bytes before decode. Missing face data
only skips face effects. Existing final failures continue to report capture failure.

**Face geometry is shared by Preview and final capture.** The five
reshape operations to saved photos or implement the separate eye/nose/mouth reshape
controls. Four groups can compose in Preview; photos contain skin, makeup and filters.
The makeup and filter parameter meanings are identical between Preview and Capture.

## Makeup algorithms

- Lips: feathered outer-lip mask minus an expanded, fully protected inner-mouth mask;
  outer support clips tint to the lip. Missing inner-lip geometry skips the effect.
- Blush: broad elliptical gradients located from both eyes, the mouth and face size;
  the local eye axis follows roll. Expanded eye/nose/mouth exclusions prevent central
  facial features receiving cheek color.
- Eyes: a softly expanded eye-landmark surround with the eye polygon and a safety
  margin removed. This is a light contour enhancement, not an eyeshadow palette.
- Brows: feathered strokes follow existing eyebrow landmarks. Local source contrast
  admits existing dark hair; flat skin receives no invented brow. Each face has its
  own reference scale, and eye regions remain excluded.

All four use bounded multiplicative channel adjustments and continuous scalar mask
blending, preserving texture and shading instead of painting a solid polygon. Full
lip gains are `(1.12, 0.88, 0.94)`, blush `(1.07, 0.978, 0.995)`, eye
`(0.925, 0.895, 0.88)`, and brow `(0.78, 0.78, 0.78)` behind local hair weighting.
These are conservative engineering starting bounds, **not calibrated real-face results**.

The existing temporal smoothing policy is reused with a separate all-feature history
from the same Vision observations; no additional face detector or per-frame Vision
request is added. Existing Slim history stays contour-only. Loss, stale observations,
confidence, association and topology changes reset history. Multiple faces retain raw
observations to avoid mixing identities; multi-person tracking stability remains a limit.

Geometry-only mask caching is limited to the latest face set/extent. It never retains
source photos. Raster tiles have a maximum edge of 256 pixels; motion can invalidate
the cache each frame. Preview keeps its bounded display resolution, shared rendering
context and one in-flight render. FPS/heat/memory improvements are not claimed.

## Filter recipes

One `FilterEffectRecipe` and one `FilterProcessingStep` serve every preset using the
existing `CoreImageRendering` helpers. The full recipe is blended against its current
input with a working-space scalar; zero returns the identical input graph and 1 uses
the complete recipe. The 50% weight is constructed numerically, avoiding an sRGB
gray being converted into an unintended linear weight.

| Preset | Full recipe |
| --- | --- |
| Original | Exact filter bypass |
| Natural | Saturation 1.02, contrast 1.02, linear brightness +0.005 |
| Clear | Saturation 0.96, contrast 0.98, linear brightness +0.02 |
| Warm | Red gain +3%, blue gain -3%; green compensates using existing linear-sRGB luminance weights |
| Cool | Opposite red/blue gains with the same luminance compensation |

There was no pre-existing global filter recipe or LUT to reuse. Bounds are centralized:
color/contrast departures at most 4%, brightness lift at most 0.02, channel gains at
most 3%. They support numerical regression checks but require photographic tuning.
Apple documents the native [Core Image filters and input semantics](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/index.html);
it does not prescribe PanPan's appearance.

## Verification and remaining acceptance

Added tests cover normalization, default/zero/full values, independent parameter and
preset retention, configuration snapshot isolation, four makeup regions/protection/
texture, filters and interpolation, native PhotoOutput/silent filter encoding, and
combined Preview/Final processor contributions. Existing skin and shape tests explicitly
disable the new default makeup when testing isolated zero-strength behavior.

Windows project/reference/localization guards, Python script/static tests, Swift syntax
parsing and pure Swift domain typechecking are executable. They do not execute Apple
frameworks. New XCTest sources are in the existing test target; Apple SDK compilation,
Core Image kernels/pixels and Simulator tests await the existing CI workflow.

**尚未完成 Apple 平台 / 真机验收。** On iPhone, check normal sheet heights and Dynamic Type,
each makeup effect at 0/50/100, every filter including Original, saved photo persistence,
front/back orientation/mirror and edge-of-frame faces, mild face motion and loss/reacquire,
multi-person behavior, naturalness across skin tones/lighting, all-group Preview composition,
shutter latency, FPS, memory and heat. The code-level graph does not establish these results.
Delivery stops after exact-SHA Actions trigger confirmation; final CI is not polled.
