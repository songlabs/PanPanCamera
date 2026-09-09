# Skin Semantic Mask Infrastructure v1

Experimental local Core Image implementation, reached through DebugPhotoProcessing
and MockFaceDetector / MockFaceLandmarkDetector / MockSkinMaskProvider only. The official capture/save path and product UI do not invoke
it. This is an explainable two-scale approximation, not a copy of a closed-source app,
semantic skin detection, identity verification or visually accepted beauty feature.

## Architecture retained

ImageProcessingPipeline still admits one job under its lock, rejects competing requests
with busy before decode, and executes loading/detection/steps on its serial background
queue. ProcessingImage remains an immutable, eagerly rendered CGImage in display
orientation; FaceRegion is normalized with a bottom-left origin.

CoreImageRendering still owns one lazily initialized shared CIContext with
cacheIntermediates: false. Working color space is unchanged; output remains RGBA8 in the
source CGImage color space. Only bounded filter/mask helpers were added to this renderer.
All CIImages are job-local. No per-face context, new queue, Task, photo cache or history
is introduced. Image-processing errors propagate through the unchanged pipeline;
optional landmark detection failure falls back to the existing face/edge path.
Expected semantic unavailability falls back per face; actual image-processing errors
still propagate. The development baseline for this addition is main
`97cf0899f5b16c2a3104e944951e4d2db4190b20`, inspected after fetching origin/main.

NaturalSkinProcessingStep is retained (brightness +0.008, saturation 1.005, contrast 1),
but is absent from the default DEBUG chain. Its tests and the older rectangular DEBUG
brightness probe remain. Texture and tone are not stacked.

## Skin semantic contract and responsibilities

The code chain is now:

    FaceDetecting -> FaceRegion                     where a face is
    FaceLandmarkDetecting -> FacialLandmarks         where features are
    SkinMaskProviding -> SkinMaskResult              where skin is allowed
    SoftFaceMaskGenerator                           geometric face coverage
    FeatureProtectionMaskGenerator                  semantic feature protection
    DetailProtectionMaskGenerator                   high-frequency protection
    EffectiveSkinMaskComposer                       where processing is allowed
    TexturePreservingSkinSmoothingStep              how texture is processed

`SkinMaskProviding.skinMask(in:region:landmarks:)` synchronously receives the immutable
ProcessingImage, one FaceRegion and that region's optional FacialLandmarks on the
existing worker. The step accepts an optional `any SkinMaskProviding`; nil already
means disabled/unavailable, so SkinRetouchConfiguration gains no semantic toggle.
The backend does not depend on a Mock. A future local adapter can implement this
interface; no actual segmentation model or photo Vision adapter is implemented here.

`SkinMaskResult` includes its **FaceRegion**, matched by structural equality exactly
as FacialLandmarks. It contains an available CIImage or `.unavailable(for: region)`
(nil mask). A black available mask forbids processing; unavailable means use S = 1.
No array-index association, UUID, tracking, confidence or video state is introduced.
The step requests each unique region once, supplies only matching landmarks and
treats a mislabeled return as unavailable for the requested face. Missing/reordered
results do not discard any other face. Duplicate available results max-union; a nil
duplicate never replaces usable data. Unrelated regions are ignored by the composer.

Weights are **0 = non-skin / processing forbidden; 1 = skin / processing allowed**,
with continuous values in 0...1. The available-result initializer requires the exact
finite original extent, including nonzero origins; it rejects infinite, empty, shifted
or mismatched masks. It composites input alpha over zero, then bounds the red scalar
into equal RGB channels with alpha 1. Thus a white semantic pixel with alpha 0.25 has
weight 0.25, and a transparent semantic pixel has weight 0. Output photo alpha follows
the unchanged conservative reconstruction policy described below. This is scalar
data: future raster providers must disable color-space conversion when importing it.

All coordinates use the existing display-oriented bottom-left FaceRegion contract.
Mock fixture rectangles use the same face-local normalized 0...1 convention as photo
landmarks and map through FaceRegion.imageRect(in:). There is no extra EXIF transform,
y flip or mirror. ProcessingImage itself is CGImage-backed with zero-origin extent;
job-local graph entry points exercise translated extents without a second image type.
All generated gradients are cropped after mapping to the exact image extent.

## Geometric Mock modes and feathering

MockSkinMaskProvider and its configuration exist entirely inside `#if DEBUG`, like
the existing two mocks. It reads only CGImage width/height and deliberately ignores
even supplied landmarks. It never inspects source pixels or alpha, calls detection,
loads a model, classifies RGB/HSV/YCbCr, accesses a camera, or sends data anywhere.
All fixed geometry/defaults live in MockSkinMaskProvider.Policy. Configuration values
are immutable and validated; none are added to formal retouch parameters.

| Mode | Synthetic behavior |
| --- | --- |
| `.normalSkin` | Most of an ellipse covering local rect (0.02,0.01,0.96,0.98) is 1; softened periphery, top hair boundary y=0.88, eye weights reduced by 0.85 and lip weights by 0.80. FeatureProtection remains the main feature exclusion. |
| `.hairExclusion` | Moves hair boundary down to y=0.72; weights above the transition are exactly 0 even inside SoftFaceMask. |
| `.glassesOcclusion` | Zero-weight interior in local rectangle (0.12,0.56,0.76,0.17), with soft edges. |
| `.beardReducedWeight` | Lower-face weight defaults to 0.25 below y=0.40, continuously rising to normal skin above the transition. It preserves the other normal exclusions. |
| `.unavailable` | Returns no semantic graph for that face; composer retains the existing face/feature/detail treatment. |

`nonSkinOcclusion: CGRect?` supplies an asymmetric generic face-local rectangle in
any available mode, replacing the glasses rectangle when present. `faces:` provides
region-bound configuration overrides, so one job can include hair, beard and unavailable
faces. If an override repeats the same region, the first configuration wins; masks
themselves still max-union, never add. Defaults are engineering fixtures, **not visually
validated skin geometry or beard treatment**.

Outer/eye/lip ellipses use CIRadialGradient, with a full-weight interior and a feather
band derived from `featherFraction * min(face.width, face.height)`. Hair, beard and each
side of an occlusion use CISmoothLinearGradient (S-curve interpolation). Default
featherFraction is 0.015, validated in 0.001...0.1. Occlusion feather is capped at one
quarter of its shorter side to keep an exact-zero interior after inversion. Hair and
beard transitions span boundary ± feather; eyes/lips remain reduced rather than
replacing semantic feature protection. No custom kernel, Metal, raster photo render,
new context, queue or image cache is needed. Linear-gradient endpoints and radial
parameters follow Apple's [Core Image filter reference](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/index.html).

## EffectiveSkinMaskComposer

The composer receives face coverage generation, per-face skin results, feature and
detail masks, and the existing configuration. It only combines masks; it does not
smooth or render a photograph. ProtectionMaskCombiner retains the existing protection
maximum; its old effective helper delegates to the composer for compatibility.
The step and DEBUG diagnostics use the same `makeMasks` path and returned masks.

For one face, using F = SoftFaceMask, S = SkinSemanticMask, P = feature protection,
D = detail protection, e = edgeProtectionStrength, i = intensity:

    C = max(clamp(P, 0, 1), clamp(D * e, 0, 1))
    effectiveSkinMask = clamp(F * S * (1 - C) * i, 0, 1)

For multiple faces, first pair coverage with **that face's** semantics:

    Sj = available semantic mask, or 1 when unavailable
    coveredSkin = max_j(Fj * Sj)
    effectiveSkinMask = clamp(coveredSkin * (1 - C) * i, 0, 1)

Feature protection retains its existing maximum across all faces/features, and detail
protection still comes from the original photo. No overlap adds strength or repeats
photo processing. This intentionally does not multiply independently unioned F and S:
doing so would let another face's fallback/semantic mask open exclusions beyond its
own coverage. In overlapping coverage, the maximum allowed contribution wins; the
mock does not infer which person physically occludes another.

All unavailable results reduce to the old `max(Fj) * (1 - C) * i`. A single unavailable
face does not zero the whole image or require all faces to succeed. True invalid
extents/filter/processing failures throw through the existing pipeline.

The diagnostic `.skinMask` is `max_j(Sj bounded to region j)`, with black outside all
regions and white inside an unavailable region. It shows the actual fallback policy,
not an assertion of successful segmentation. It is not multiplied into the combined
face mask again; processing uses the paired coveredSkin graph above. Fallback diagnostic
region borders may be hard; the actual effective input remains feathered by Fj.

The frequency decomposition, both radii, CINoiseReduction, detailRetention, maximum
channel delta, default intensity and reconstruction kernel are unchanged. Intensity
zero still returns the exact original CGImage before calling either optional provider
or creating a CIImage, filter, mask or render. Explicit mask diagnostics may run at
zero; effectiveSkinMask is then black while raw semantic weights remain inspectable.

## Existing Vision investigation and shared semantic names

The existing video route remains AVCaptureVideoDataOutput -> CameraFaceFrameProcessor
-> VisionFaceDetector. VisionFaceDetector already owns one VNDetectFaceLandmarksRequest,
returns all observations as DetectedFace, and collects leftEye, rightEye, nose,
noseCrest, outerLips, innerLips and faceContour (no eyebrows). FaceCoordinates converts
Vision face-local points with boundingBox.origin + localPoint * boundingBox.size.
Stored preview points are image-normalized in the oriented, unmirrored Vision frame;
FaceCoordinates and AVCaptureVideoPreviewLayer then own preview rotation/mirroring.
No detector, camera frame processor, camera session or preview code was changed.

The pure nested DetectedFace.Landmark enum was extracted as FacialLandmarkRegion and
retained through a typealias, adding only leftEyebrow/rightEyebrow. Existing preview
cases remain for its existing consumers. There is one shared semantic vocabulary;
photo processing does not reuse the preview frame, its confidence, or camera metadata.
Photo FacialLandmarks stores only the six features actually used below; it does not
introduce another DetectedFace or tracking identity model.

## Photo landmark contract and provider

FacialLandmarks = immutable FaceRegion + [FacialLandmarkRegion: [CGPoint]]. All photo
landmark points are **FaceRegion-local normalized 0...1, bottom-left origin**. The
image and FaceRegion are already display-oriented and mirrored by the ImageIO loader.
No second EXIF transform, y flip, preview conversion or mirror occurs in this layer.
The provider names left/right; both sides use identical protection policies, and
coordinates are never swapped based on the name.

For extent E and face pixel rect R = FaceRegion.imageRect(in: E):

    imagePoint = (R.minX + local.x * R.width, R.minY + local.y * R.height)

This includes nonzero extent origins and is directly testable with asymmetric points.
Face-local coordinates are chosen because future detection on the **same oriented
photo** can use Vision normalizedPoints directly, with no preview-frame coupling.
That future adapter must return the supplied FaceRegion values in this image contract;
the existing live preview DetectedFace.landmarks must not be passed here directly.

FaceLandmarkDetecting<Image> synchronously returns [FacialLandmarks] for one image and
its regions on the existing worker. Every returned value includes its region; both
the mock and mask generator match by immutable FaceRegion equality, never array index.
Reordering and partial results are safe. Equal duplicate boxes need no tracking IDs;
all matching feature masks union with max and duplicate identical coverage is idempotent.

MockFaceLandmarkDetector exists wholly inside DEBUG. It never inspects the image,
invokes detection, camera, files or network. Default proportions live in one static
dictionary in that file; init(landmarks:) injects custom, empty or partial results.

| Synthetic feature | Face-local proportions |
| --- | --- |
| leftEye / rightEye | Six-point closed polygons centered around (0.30,0.64)/(0.70,0.64); x 0.20...0.40 / 0.60...0.80; y 0.60...0.68 |
| leftEyebrow / rightEyebrow | Open curves (0.18,0.75),(0.27,0.79),(0.40,0.76) / (0.60,0.76),(0.73,0.79),(0.82,0.75) |
| outerLips | Six-point polygon x 0.34...0.66, y 0.25...0.34, side corners at y 0.30 |
| nose | Open curve (0.50,0.59),(0.50,0.45),(0.42,0.43),(0.50,0.40),(0.58,0.43) |

These are fixed data-chain/mask fixtures, **not measured or validated human landmarks**.
The nose curve is deliberately approximate and makes no precise nostril claim.

Validation discards an entire invalid feature while retaining its valid siblings.
Points must be finite and within 0...1. Eyes/lips require at least three unique points,
nonzero area, no nonadjacent edge intersection/touch, and no repeated closing vertex;
either winding and simple concavity are accepted. Brows/nose need at least two distinct
points. Empty/short/repeated/NaN/infinite/out-of-range/degenerate/self-intersecting data
cannot reach a raster path. Unused preview-only feature keys are omitted.

No provider, no results, missing faces, empty/invalid features, or a thrown optional
provider error means zero additional semantic protection, not loss of skin processing.
Raster allocation failure drops only that feature. Invalid image extents and unavailable
Core Image filters remain actual processing errors. No photo/face data is logged.

## Feature rasterization and soft protection

FeatureProtectionMaskGenerator fills eye and outer-lip polygons, then expands their
boundary with a round stroke of width 2 * expansion. Filled eye interiors cover the
eyeball as well as eyelid/lash surroundings; lip interiors protect color and texture.
Brows use a widened open curve to cover hairs. Nose uses a weaker widened open curve
for approximate bridge/alar structure, leaving other nose skin available to smoothing.
Generic image edges still add structure protection.

Let s be **that face's** shorter pixel side. Fixed policy (no new user parameter):

| Feature | Expansion radius | Gaussian feather radius | Peak protection |
| --- | --- | --- | --- |
| Both eyes | 0.025 * s | 0.010 * s | 1.0 |
| Both eyebrows | 0.020 * s | 0.008 * s | 1.0 |
| Outer lips | 0.020 * s | 0.008 * s | 1.0 |
| Nose curve | 0.018 * s | 0.010 * s | 0.55 |

Core Graphics rasterizes only each feature's bounds plus black padding of
(expansion + 4 feather radii + 2 pixels). Grayscale tiles are at most 1024 pixels on their longer
side; larger tiles scale back to the exact image coordinates. No full photo is rendered
for each feature and no per-feature CIContext is created. The temporary CGImage is
retained only as a source in the current CIImage graph, never in a cache or property.

The tile is imported as scalar data with colorSpace: NSNull(), placed over opaque black,
and Gaussian-feathered. Clamp(blur / 0.98, 0, 1) restores an exclusion plateau while
preserving a continuous outer ramp, then multiplies by feature strength. Every result
is cropped to the original extent; all features/all faces max-union into one grayscale
opaque mask. Faces smaller than one pixel in either dimension are skipped as before.
The unchanged shared renderer performs the final photo render only once.

## Decomposition and reconstruction (unchanged)

For original working-space RGB O, independently compute:

    S = Gaussian(O, smallRadius)
    L = Gaussian(O, largeRadius)
    N = CINoiseReduction(L, noiseLevel, sharpness: 0)
    H = O - S                              original high-frequency detail
    M = S - L                              original mid-frequency texture
    d = detailRetention
    m = 1 - 0.5 * (1 - d)
    R = N + m * M + d * H
    candidate = O + clamp(R - O, -0.02, +0.02)   per working-space RGB channel
    output = blend(original, candidate, effectiveMask)

Zero noiseReductionStrength bypasses CINoiseReduction, giving N = L. With d = 1
and noise reduction disabled, the signed bands reconstruct O. Gaussian images are
internal bases only; neither is the final adjusted photo. Small-scale attenuation
reduces fine random variation; the larger base and limited mid-band attenuation address
mild regional variation. Neither component identifies blemishes. Texture is retained
from the original rather than generated.

One small pointwise CIColorKernel implements signed subtraction/reconstruction and the
delta bound. This avoids treating absolute differences or clamping blend modes as signed
detail, and keeps alpha explicit. It uses Apple's legacy CIColorKernel(source:) API
(deprecated since iOS 12, still available). Kernel compilation/execution requires Apple
validation. There is no custom Metal/MPS renderer or shader framework; no MPS spike was
needed or implemented.

The 0.02 bound is an engineering guard in the existing working space, not a fixed 8-bit
increment, exposure-stop value or proven perceptual safety threshold. Default intensity
further scales it by at most 0.25. Changes can be very small or quantize away in RGBA8.
Real photos must determine future tuning.

## Configuration and adaptive scale

All retouch parameters and frequency policy remain in SkinRetouchConfiguration.swift.
This task does not change that file or any existing frequency/intensity defaults.
Feature-mask-only constants live in FeatureProtectionMaskGenerator.Policy.

| Parameter | Initial value | Throwing validation |
| --- | --- | --- |
| intensity | 0.25 | Finite 0...1 via SkinRetouchIntensity |
| detailRetention | 0.9 | Finite 0...1; 1 retains all high/mid detail |
| noiseReductionStrength | 0.015 | Finite 0...0.03, a conservative v1 cap |
| edgeProtectionStrength | 1.0 | Finite 0...1 |

NaN/infinity/out-of-range values are rejected, never silently clamped. Use
SkinRetouchConfiguration.naturalDefault and withIntensity. Intensity constants original,
natural and stronger are 0, 0.25 and 0.5. These are engineering starting values, not
settings that have passed real-photo visual review.

Map each FaceRegion to image pixels and ignore boxes with either dimension below one
pixel, as the existing mask generator does. Let f be the smallest usable face short side:

    smallRadius = clamp(0.003 * f, 0.6, 3.0) pixels
    largeRadius = 3 * smallRadius           // 1.8...9.0 pixels
    protection dilation radius = smallRadius

One scale pair serves the combined photo mask. Face order and duplicates cannot change
scale. A large face cannot over-smooth a small face; mixed-size groups deliberately
under-process the larger face. This is not independent per-person tuning. Decomposition
and reconstruction run once regardless of face count.

## Face mask and detail protection

FaceMaskGenerating and SoftFaceMaskGenerator are unchanged. For each face:

    radiusY = 0.48 * height
    radiusX = min(0.45 * width, 0.8 * radiusY)

Transform an opaque radial gradient from radius 65 (white) to 100 (black) into this ellipse
at the face center, then crop to source extent. CIMaximumCompositing merges faces with
max(a, b), including feather overlaps. Weights stay in 0...1, outside is black, and the
photo is not repeatedly processed for each face.

DetailProtectionMaskGenerator returns opaque grayscale: white means protect, black
means allow. It runs CIEdges(O, intensity: 1), takes maximum RGB, multiplies by 4, clamps
0...1 and expands protection with CIMorphologyMaximum at smallRadius. This covers thin
structures and nearby edge pixels without weakening peaks. It uses chromatic/neutral
contrast, not absolute skin RGB/HSV thresholds, and does not semantically locate eyes,
lips, hair, moles or identity. Fixed skin-color thresholds cannot reliably cover different
complexions and lighting, so there is no such classifier or complexion exclusion.

EffectiveSkinMaskComposer combines this unchanged detail graph with features and
per-face semantic coverage using the formula above. ProtectionMaskCombiner still
scales edges exactly once and takes max(feature, scaled edge), preserving both
protection layers when semantics are unavailable.

## Complete filter/kernel inventory for the new chain

| Operation | Explicit parameters |
| --- | --- |
| CIRadialGradient, existing face mask | center (0,0), radius0 65, radius1 100, opaque white/black, ellipse transform above |
| CIMaximumCompositing, existing union | next face mask + previous combined mask |
| Core Graphics feature tile | filled/stroked path, round cap/join, grayscale scalar coverage |
| CIGaussianBlur, feature feather | per-feature radius above, black padding; crop to source extent |
| CIMaximumCompositing, feature/edge | max across features/faces, then max(feature, scaled edges) |
| CIGaussianBlur, two internal bases | original clamped to extent; smallRadius and largeRadius |
| CINoiseReduction, low base only | clamped large base, inputNoiseLevel 0.015 default, inputSharpness 0 |
| CIEdges | clamped original, inputIntensity 1 |
| CIMaximumComponent | edge image, no adjustable parameters |
| CIColorMatrix, scalar arithmetic | R/G/B vectors (scale,0,0,0), A vector zero, bias (bias,bias,bias,1); edge gain, plateau gain, feature strength, edge strength, (scale -1/bias 1) protection inverse, intensity |
| CIColorClamp, after each matrix | min (0,0,0,1), max (1,1,1,1) |
| CIMorphologyMaximum | clamped protection, inputRadius smallRadius |
| CIMultiplyCompositing | per-face F * S, then allowed protection; mock geometry intersections |
| CIRadialGradient / CISmoothLinearGradient, DEBUG semantic fixtures | ellipse/feather and hair, beard, occlusion ramps defined above |
| CIColorKernel reconstruction | original, small, large, low; d, 1-0.5*(1-d), delta bound 0.02, opaque threshold 0.9999 |
| CIBlendWithMask | candidate over original using effectiveMask |
| CIDifferenceBlendMode, DEBUG only | processed graph + original, no gain |

Photo neighborhood inputs are clamped before filtering; feature tiles use black padding.
Every result is cropped to exact
source extent. The retouch never warps, translates or resizes image coordinates. Graphs
support nonzero origins; ProcessingImage supplies CGImage's zero-origin extent as before.
DEBUG ImageIO applies EXIF rotation/mirroring exactly once before detection and retains
the existing maximum preview dimension of 2048.

Reconstruction keeps original alpha and explicitly unpremultiplies/premultiplies RGB.
If original, small, large or low alpha is below 0.9999, it returns the original sample.
This conservatively bypasses translucent pixels and transparent neighborhoods, avoiding
cross-alpha contamination. Diagnostic masks are opaque; difference is a visualization,
not the alpha acceptance output. Nonzero processing still uses the existing RGBA8 render;
Apple tests allow one code value for color roundtrip and require unchanged alpha.

Intensity zero and no faces return the exact input CGImage before the landmark/skin providers or any CIImage, filter,
mask or render. All subpixel/nil coverage also returns the input. Explicit diagnostic
modes may render masks/difference even at zero; original and processed-at-zero are the
bypass comparison outputs.

## DEBUG A/B inspection

Run sequentially from one developer task; all requests share one busy slot:

    let original = try await DebugPhotoProcessing.process(data: data, output: .original)
    let zero = try await DebugPhotoProcessing.process(data: data,
        configuration: .naturalDefault.withIntensity(.original))
    let natural = try await DebugPhotoProcessing.process(data: data,
        configuration: .naturalDefault) // 0.25; no NaturalSkinProcessingStep
    let stronger = try await DebugPhotoProcessing.process(data: data,
        configuration: .naturalDefault.withIntensity(.stronger)) // 0.5
    let face = try await DebugPhotoProcessing.process(data: data, output: .faceMask)
    let skin = try await DebugPhotoProcessing.process(data: data, output: .skinMask)
    let effective = try await DebugPhotoProcessing.process(data: data, output: .effectiveSkinMask)
    let beard = MockSkinMaskProvider(configuration: try .init(mode: .beardReducedWeight))
    let beardPreview = try await DebugPhotoProcessing.process(data: data, skinMaskProvider: beard)
    let hair = MockSkinMaskProvider(configuration: try .init(mode: .hairExclusion))
    let hairMask = try await DebugPhotoProcessing.process(data: data, output: .effectiveSkinMask,
                                                         skinMaskProvider: hair)
    let features = try await DebugPhotoProcessing.process(data: data, output: .featureProtectionMask)
    let protection = try await DebugPhotoProcessing.process(data: data, output: .detailProtectionMask)
    let combined = try await DebugPhotoProcessing.process(data: data, output: .combinedProtectionMask)
    let difference = try await DebugPhotoProcessing.process(data: data, output: .difference)

| Output | Meaning |
| --- | --- |
| `.original` | Oriented/downsampled original development preview. |
| `.faceMask` | Face Region geometric coverage, maximum of soft face masks. |
| `.skinMask` | Semantic skin weights; unavailable faces display the white fallback bounded to their regions. |
| `.featureProtectionMask` | Eye, eyebrow, lip and nose semantic protection; white means protect. |
| `.detailProtectionMask` | Generic high-frequency/edge protection before edge strength. |
| `.combinedProtectionMask` | Final protection max(feature, clamp(detail * edgeStrength)). |
| `.effectiveSkinMask` | Actual final skin-smoothing weights, including paired F/S, protection and intensity. |
| `.processed` | One texture reconstruction and one masked blend. |
| `.difference` | Unamplified absolute change between the processed graph and original preview. |

The methods also accept CapturedPhoto. Existing processedPhoto/softFaceMask spellings
remain aliases. Inspect returned CGImages in Xcode/local developer code; release outputs
when finished. No UI, slider, saving, upload, logging or image history is added.
Original here means the common oriented/downsampled decoded preview, not original file
bytes. Immutable output/configuration/mock provider travels with each job through the one static
pipeline. The caller serializes A/B requests.
The optional landmarkOverlay mode is deferred to keep this change focused; separate
feature/combined masks and asymmetric coordinate tests support the next Apple inspection.

## Tests and current evidence

The preceding texture implementation added 20 XCTest methods: five Foundation configuration/scale cases, thirteen texture
cases, one detail-mask case, one DEBUG A/B/mode case. Coverage includes exact zero/no-face
identity, parameter rejection, scale limits/adaptation, signed reconstruction, high-detail
retention, lower flat noise variance, edge/one-pixel-line/dark-spot preservation, exterior,
duplicate/order/overlap/disjoint faces, alpha/transparent neighborhoods, flat colors
across tones, four borders, nonzero extent, one-pixel face, error propagation, protection/
feather relationships and job-local modes. Existing soft-mask/tone/EXIF tests remain;
former default-tone expectations now require texture-only flat patches to stay stable.

The deterministic noise fixture contains a hard edge and fine line. Gaussian baseline
code exists only in tests, uses the same SMALL radius, mask, intensity and renderer, and
requires both outputs to smooth while retouch retains more edge/line contrast. This is
not a comparison at matched residual noise variance or proof of real-photo superiority.

Facial Feature Protection v1 adds 22 XCTest methods: nine Foundation mock/model cases,
seven Core Image feature/combination cases, five processing/fallback cases and one DEBUG
output case. Existing A/B references now explicitly inject the mock landmark provider.
Coverage includes all six center > feather > outside relations, expanded interiors,
eye-vs-cheek/brow-vs-forehead/lip-vs-chin/nose-vs-cheek, finite opaque 0...1 masks,
nonzero origins/four edges/tiny faces, multi-face reordering/partial results/max overlaps,
missing/invalid/throwing provider fallback, one detection per photo, and zero bypass.
Synthetic noisy skin, dark eye/brow lines and a colored textured lip patch compare
feature change against skin change with edge strength 0 (semantic isolation) and 1
(combined behavior). This does not assert visual quality on real photos.

Skin Semantic Mask Infrastructure v1 adds 25 XCTest methods: 11 semantic mask,
six composer, six pipeline/reconstruction integration, and two DEBUG output methods.
The prior DEBUG A/B reference now injects MockSkinMaskProvider as well. Coverage includes
all five modes, custom asymmetric occlusion, beard partial weights, feather transitions,
all image edges, one/subpixel faces, nonzero extents, scalar alpha, invalid inputs,
image-independence, region overrides, max overlap/order/duplicates, mixed availability,
mislabeled results, the independent legacy fallback formula, exact zero/no-face bypass,
actual error propagation/admission recovery, alpha, shared mask output and difference.
These Apple XCTest methods are **added, not executed** in this task.

Windows checks: 39 Python tests passed (12 processing scope/Release isolation checks);
project checks passed for 58 app and 21 XCTest sources; 79 Swift sources parsed both
with and without DEBUG. Four existing pure Swift Domain files and three camera control
helpers passed host typechecking. Release redeclaration probes passed including the
new mock. No Apple framework typecheck occurred. Previous host Foundation attempts
were blocked by missing msvcrt.lib, oldnames.lib, msvcprt.lib and errno.h; those known
paths were not retried and the Windows environment was not modified.

Skin Semantic Mask Infrastructure v1 及 Natural Skin Processing 基础 Mask 链路已经完成代码实现，
并完成当前环境可执行静态验证。
Mock Skin Mask 不代表真实皮肤语义识别已经完成。
Apple Core Image / XCTest 实际运行验证暂缓，将在基础组件完成后统一执行。
真实 Vision 人脸检测 / landmarks 尚未验证。
真实 Skin Segmentation 尚未实现。
现有 CIColorKernel(source:) deprecated 风险保持，未修改、未新增第二处 legacy kernel；
Apple SDK / Xcode 编译与运行验证仍待统一阶段。
尚未完成 Apple 平台 / 真机验收。
Xcode Build, Simulator, real photos, GPU, memory, latency and thermals remain pending.
This task does not start the unified Apple acceptance phase or new beauty capabilities.

Future Mac/iPhone acceptance must inspect protection positions for eyes, eyebrows,
lips and nose, including frontal/profile, looking up/down, glasses, fringe occlusion,
multiple people and mixed face sizes, different skin tones, bright/dim light, front
camera mirroring, all EXIF orientations, retained skin texture, and accidental feature
blur. Mock positions cannot establish any of this. No Vision adapter is implemented.
After commit/push this task confirms an exact-SHA iOS CI trigger, then stops without
waiting or polling for completion; trigger confirmation is not CI success.

References: Apple's [Core Image filter reference](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/index.html)
and [kernel language reference](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CIKernelLangRef/ci_gslang_ext.html)
document APIs, not PanPan image quality. MPS guided filtering, Vision feature masks,
semantic segmentation and temporary-blemish research remain future separate tasks.
