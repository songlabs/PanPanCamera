# Experimental local face tone processing

`ProcessingImage` remains an immutable, fully rendered CGImage in display orientation.
The ImageIO loader applies EXIF rotations and mirrors once, before detection. Face boxes
remain normalized to this exact image, with a bottom-left origin; `imageRect(in:)` also
preserves nonzero extent origins. No preview coordinates or landmarks are used here.

## Soft face mask

`FaceMaskGenerating.makeMask(regions:in:)` is the only replacement boundary. It returns
an opaque grayscale CIImage with RGB weights in 0...1 and exactly the supplied finite
image extent, or nil for no usable coverage. A later mask implementation can be injected
into `NaturalSkinProcessingStep(maskGenerator:)` without changing the pipeline.

`SoftFaceMaskGenerator` makes one portrait ellipse per usable bounding box:

- Center: bounding-box center, with no coordinate reinterpretation or translation bias.
- Vertical radius: `0.48 * box.height` (96% of box height).
- Horizontal radius: `min(0.45 * box.width, 0.8 * verticalRadius)` (at most 90% of box width,
  and at most 80% of the vertical radius, including unusually wide boxes).
- `CIRadialGradient`: opaque white at reference radius 65 and inside, transitioning to
  opaque black at reference radius 100 and outside. Scale the reference circle to the
  ellipse with one affine transform. The outer 35% of each radius is a continuous feather.
- Crop the transformed gradient immediately to the image extent. The infinite generator
  is black outside its outer radius; it is never rendered/exported with infinite extent.
  The ellipse falls to zero inside the box, keeping corners and surrounding pixels black.
- Merge faces with `CIMaximumCompositing` and crop after each merge. This is `max(a, b)`,
  including overlapping feather values; duplicates/order do not amplify weights. Inputs
  already in 0...1 stay in that range, with alpha 1. No repeated photo blend per face.

No faces return nil before any Core Image construction. Subpixel boxes (either mapped
dimension below one pixel) are skipped without enlarging them. If every box is skipped,
the processing step returns the original CGImage. A one-pixel box is allowed, with no
guarantee of a visible adjustment at that sampling resolution. Invalid image extents
throw before filter creation. The real image always supplies a finite CGImage extent.

The approximation covers central face, cheeks, main forehead and chin while lowering
corner/background/hair-periphery weights. It is not skin segmentation: it cannot reliably
exclude eyes, lips, brows, nostrils or hair within the ellipse. No blur, custom kernel,
Metal, learned model, third-party dependency or cached mask is introduced.

## NaturalSkinProcessingStep

The step returns the exact input for no faces, before making a CIImage or calling the
generator. Otherwise it obtains the final mask, applies one `CIColorControls` graph,
blends once with the source through `CIBlendWithMask`, then eagerly renders RGBA8 using
the original image color space and dimensions. The input CGImage is never modified.

| Control | Value | Purpose |
| --- | --- | --- |
| Brightness | `+0.008` | Small tonal lift in Core Image's working color space |
| Saturation | `1.005` | Only a 0.5% saturation adjustment |
| Contrast | `1.0` | Neutral contrast, avoiding extra texture/shadow emphasis |

The defaults intentionally stay near identity, and the feather reduces their weight
toward the edge. These numbers are not an exposure-stop or fixed 8-bit increment claim:
color management and source tone affect the rendered change. There is no spatial blur,
neighbor mixing, facial deformation, whitening algorithm or product beauty control.
These facts constrain the effect, but natural appearance across skin tones and lighting
still requires Apple pixel execution and visual inspection of local real photos.

## Shared rendering and DEBUG inspection

`CoreImageRendering` minimally extracts the previous probe's `CIBlendWithMask`, eager
render, failure cases and static CIContext. The context initializes on its first worker
render and is reused by the natural step, old probe and mask preview, with
`cacheIntermediates: false`. No per-face context, thread, task, mask cache or history exists.
Each job holds only its own filters/graphs until rendering completes. Calls assert the
existing off-main contract; the pipeline keeps its serial queue and busy rejection.
Filter/render errors throw; mask errors propagate unchanged through the step/pipeline.

The DEBUG-only `DebugFaceBrightnessStep` keeps its old inward-rounded rectangular mask
and +0.01 probe behavior. Only its blend/context/render plumbing is shared. It is no
longer the default DEBUG output and is not the soft-mask implementation.

Use `DebugPhotoProcessing.process(photo, output: .softFaceMask)` or
`DebugPhotoProcessing.process(data: encodedData, output: .softFaceMask)` for an opaque
black-background, white-mask `ProcessingImage`. Inspect `result.image.cgImage` with an
Xcode image viewer or a temporary developer/test view, checking center placement, smooth
gray boundary, black corners/exterior and all four image edges. For comparisons, call
the default `.processedPhoto` mode sequentially on the same data. Both modes apply the
same orientation/2048-pixel policy and share one admission slot. No product button,
camera hook, saving, logging or uploading is added. These entry/probe types are absent
from Release; the reusable mask/natural-step types have no production camera call sites.

## Tests and evidence

New Apple XCTest coverage consists of:

- Nine `SoftFaceMaskTests`: center/feather/exterior/corners; gradual radial falloff;
  empty and subpixel boxes; one-pixel face; all four edges with nonzero origin; portrait
  shape for wide boxes; disjoint faces; maximum union/duplicate/order behavior; invalid
  extents. Full RGBA float masks check finiteness, range, grayscale, alpha and exact extent,
  so 8-bit output clamping cannot conceal invalid weights.
- Nine `NaturalSkinProcessingTests`: no-face identity without calling the generator;
  nil/tiny coverage identity; weak center/feather/exterior behavior and input immutability;
  colored one-pixel detail across tones; duplicate/partial overlap; disjoint faces;
  all four edges/one-pixel box without black borders; transparent/translucent alpha;
  injected mask error identity and release of pipeline admission after failure.
- Three additional `DebugPhotoProcessingTests`: mask pixels and mode switching without
  altering CapturedPhoto data; oriented/downsampled mask output; opaque-black empty mask.
  Existing rectangle-probe, all-eight-EXIF, decode-error and pipeline tests remain.

The Xcode project registers these tests under the existing shared scheme/CI Debug test
target. Added Python scope guards ensure there are no camera/product call sites or
concrete mask dependencies in the pipeline, and include the new preview in actual Release
exclusion compilation. Windows static validation results are in the parent README.

真实 Vision 人脸检测尚未验证。
Soft Face Mask 和 NaturalSkinProcessingStep 的实际 Core Image 图像效果尚未在 Apple 平台执行验证。
尚未完成 Apple 平台 / 真机验收。
