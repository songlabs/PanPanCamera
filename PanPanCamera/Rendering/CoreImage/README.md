# Facial Feature Protection v1 + Texture-Preserving Natural Skin Retouch v1

Experimental local Core Image implementation, reached through DebugPhotoProcessing
and MockFaceDetector / MockFaceLandmarkDetector only. The official capture/save path and product UI do not invoke
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

NaturalSkinProcessingStep is retained (brightness +0.008, saturation 1.005, contrast 1),
but is absent from the default DEBUG chain. Its tests and the older rectangular DEBUG
brightness probe remain. Texture and tone are not stacked.

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

    F = featureProtectionMask (0 when absent)
    D = detailProtectionMask
    combinedProtection = clamp(max(clamp(F, 0, 1),
                                   clamp(D * edgeProtectionStrength, 0, 1)), 0, 1)
    effectiveMask = clamp(faceMask * clamp(1 - combinedProtection, 0, 1)
                          * intensity, 0, 1)

Grayscale matrix arithmetic, multiplication and clamping keep mask alpha 1. One photo
blend follows union/protection/intensity. ProtectionMaskCombiner implements the shared
formula for processing and DEBUG output. DetailProtectionMaskGenerator keeps its
existing CIEdges graph; its existing effectiveMask helper delegates to the same combiner
with no features. max avoids repeated accumulation and applies edge strength only once.
With F absent the original face/edge formula is retained. No segmentation is added.

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
| CIMultiplyCompositing | faceMask and inverted/scaled protection weight |
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

Intensity zero and no faces return the exact input CGImage before the landmark provider or any CIImage, filter,
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
    let features = try await DebugPhotoProcessing.process(data: data, output: .featureProtectionMask)
    let protection = try await DebugPhotoProcessing.process(data: data, output: .detailProtectionMask)
    let combined = try await DebugPhotoProcessing.process(data: data, output: .combinedProtectionMask)
    let difference = try await DebugPhotoProcessing.process(data: data, output: .difference)

The methods also accept CapturedPhoto. Existing processedPhoto/softFaceMask spellings
remain aliases. Inspect returned CGImages in Xcode/local developer code; release outputs
when finished. No UI, slider, saving, upload, logging or image history is added.
Original here means the common oriented/downsampled decoded preview, not original file
bytes. Immutable output/configuration travels with each job through the one static
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

Windows checks: 37 Python tests passed (ten processing scope/Release isolation checks);
project checks passed for 55 app and 18 XCTest files; 73 Swift files parsed both with and
without DEBUG; four existing pure Swift domain types and three camera control helpers
passed host typechecking. No Apple framework typecheck occurred. The host Foundation
XCTest harness includes the new landmark tests but was blocked before execution by
missing msvcrt.lib, oldnames.lib and msvcprt.lib. Separate Foundation typechecking of
the actual landmark sources was blocked by missing errno.h in the Windows C SDK. These attempts are not
passing XCTest/typecheck evidence.

Texture-Preserving Natural Skin Retouch v1 已完成代码实现和当前环境可执行验证，
但实际 Core Image 图像效果尚未在 Apple 平台验证。
Facial Feature Protection v1 的实际 Core Image Mask 与像素行为尚未在 Apple 平台执行验证。
真实 Vision 人脸检测 / landmarks 尚未验证。
CIColorKernel(source:) 尚未完成 Apple SDK / Xcode 编译验证。
尚未完成 Apple 平台 / 真机验收。
Apple XCTest, Xcode Build, Simulator, real photos, device performance, GPU, memory and
thermals remain unverified. No identity-model validation claim is made.

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
