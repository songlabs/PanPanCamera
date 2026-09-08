# Texture-Preserving Natural Skin Retouch v1

Experimental local Core Image implementation, reached through DebugPhotoProcessing
and MockFaceDetector only. The official capture/save path and product UI do not invoke
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
is introduced. Errors propagate through the unchanged pipeline.

NaturalSkinProcessingStep is retained (brightness +0.008, saturation 1.005, contrast 1),
but is absent from the default DEBUG chain. Its tests and the older rectangular DEBUG
brightness probe remain. Texture and tone are not stacked.

## Decomposition and reconstruction

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

All adjustable parameters and fixed v1 policy live in SkinRetouchConfiguration.swift.

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

    P = detailProtectionMask
    effectiveMask = clamp(faceMask * clamp(1 - edgeProtectionStrength * P, 0, 1)
                          * intensity, 0, 1)

Grayscale matrix arithmetic, multiplication and clamping keep mask alpha 1. One photo
blend follows union/protection/intensity. The generator is a small concrete type
returning a CIImage: a future landmark mask can replace that result or max-combine with
it. No speculative landmark/segmentation abstraction is added.

## Complete filter/kernel inventory for the new chain

| Operation | Explicit parameters |
| --- | --- |
| CIRadialGradient, existing face mask | center (0,0), radius0 65, radius1 100, opaque white/black, ellipse transform above |
| CIMaximumCompositing, existing union | next face mask + previous combined mask |
| CIGaussianBlur, two internal bases | original clamped to extent; smallRadius and largeRadius |
| CINoiseReduction, low base only | clamped large base, inputNoiseLevel 0.015 default, inputSharpness 0 |
| CIEdges | clamped original, inputIntensity 1 |
| CIMaximumComponent | edge image, no adjustable parameters |
| CIColorMatrix, scalar arithmetic | R/G/B vectors (scale,0,0,0), A vector zero, bias (bias,bias,bias,1); scale/bias pairs (4,0), (-edgeProtectionStrength,1), (intensity,0) |
| CIColorClamp, after each matrix | min (0,0,0,1), max (1,1,1,1) |
| CIMorphologyMaximum | clamped protection, inputRadius smallRadius |
| CIMultiplyCompositing | faceMask and inverted/scaled protection weight |
| CIColorKernel reconstruction | original, small, large, low; d, 1-0.5*(1-d), delta bound 0.02, opaque threshold 0.9999 |
| CIBlendWithMask | candidate over original using effectiveMask |
| CIDifferenceBlendMode, DEBUG only | processed graph + original, no gain |

Neighborhood inputs are clamped before filtering; every result is cropped to exact
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

Intensity zero and no faces return the exact input CGImage before any CIImage, filter,
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
    let protection = try await DebugPhotoProcessing.process(data: data, output: .detailProtectionMask)
    let difference = try await DebugPhotoProcessing.process(data: data, output: .difference)

The methods also accept CapturedPhoto. Existing processedPhoto/softFaceMask spellings
remain aliases. Inspect returned CGImages in Xcode/local developer code; release outputs
when finished. No UI, slider, saving, upload, logging or image history is added.
Original here means the common oriented/downsampled decoded preview, not original file
bytes. Immutable output/configuration travels with each job through the one static
pipeline. The caller serializes A/B requests.

## Tests and current evidence

Added 20 XCTest methods: five Foundation configuration/scale cases, thirteen texture
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

Windows checks: 36 Python tests passed (nine processing scope/Release isolation checks);
project checks passed for 50 app and 15 XCTest files; 65 Swift files parsed both with and
without DEBUG; four existing pure Swift domain types and three camera control helpers
passed host typechecking. No Apple framework typecheck occurred. The host Foundation
XCTest harness includes the new configuration tests but was blocked before execution by
missing msvcrt.lib, oldnames.lib and msvcprt.lib. Separate Foundation typecheck/module
emission was blocked by missing errno.h in the Windows C SDK. These attempts are not
passing XCTest/typecheck evidence.

Texture-Preserving Natural Skin Retouch v1 已完成代码实现和当前环境可执行验证，
但实际 Core Image 图像效果尚未在 Apple 平台验证。
真实 Vision 人脸检测尚未验证。尚未完成 Apple 平台 / 真机验收。
Apple XCTest, Xcode Build, Simulator, real photos, device performance, GPU, memory and
thermals remain unverified. No identity-model validation claim is made.

References: Apple's [Core Image filter reference](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/index.html)
and [kernel language reference](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CIKernelLangRef/ci_gslang_ext.html)
document APIs, not PanPan image quality. MPS guided filtering, Vision feature masks,
semantic segmentation and temporary-blemish research remain future separate tasks.
