# Local Beauty processing pipelines

The original AVCaptureVideoPreviewLayer remains active as the zero-strength and failure
fallback. When implemented Beauty effects are active, CameraFaceFrameProcessor places
only its newest native frame in BeautyPreviewFrameStore. BeautyPreviewRenderer consumes
at most one frame/Metal command buffer at a time, downscales only the display target to
a 1280-pixel long edge, and presents Core Image output over the original layer.

The shutter snapshots one immutable BeautyConfiguration. AVCapturePhotoOutput data is
processed at its original dimensions before encoding; the silent fallback processes the
native VideoDataOutput pixel buffer and never uses a preview/view screenshot or upscale.
Photo and silent paths bypass their former work when Beauty is disabled/zero where their
source format permits. Failures do not replace the original preview, while final failures
produce the existing capture error instead of saving damaged data.

BeautyImageProcessor defines the skin effect order and parameter mapping: texture-
preserving smoothing, bounded local brightening, then neutral tone consistency. Preview
uses the same definition on a smaller aspect-filled image with lighter internal settings;
final uses native pixels. Preview then maps the main face's contour/eyebrow landmarks to
the five local Face Correction controls. Their feathered signed vectors are added into one
cached RG displacement map and one explicit vector-sampling CI kernel; missing/incomplete landmarks
fall back to the original Preview layer. Face Auto batch-sets the category parameters,
and each implemented control is rendered at Auto multiplied by its concrete strength.
Face geometry is intentionally absent from final-photo processing. Both branches remain
entirely local. There is no upload, third-party SDK, skin segmentation, eye/nose/mouth
warp, blemish or dark-circle algorithm. Apple/device acceptance remains pending.

See [the Preview strength audit](../../docs/BeautyPreviewStrengthAudit.md) for the
historical parameter chain, skin quality differences, and the
overlapping-field overwrite repair. Requested overlay vectors are individual effect
inputs; the final map combines all active vectors at each pixel.

The temporary Face Geometry Debug Overlay consumes `FaceGeometryDebugSnapshot` from that
same Preview render operation. The snapshot is created only after the native buffer,
Vision faces and CIImage have passed through the production quarter-turn, residual
rotation, one front mirror and centered aspect-fill crop. `FaceCorrectionGeometryResult`
provides both the active warps sent to the vector-sampling kernel and the zero-strength
small-face center/radius zones; zero zones expose a zero vector and are not admitted to
the displacement map. The UIKit layer only converts final Metal drawable pixels from
bottom-left to Preview points from top-left. It does not run Vision, use safe-area sizes,
or estimate geometry separately. Fixed shape/text layers are reused and unchanged
snapshots do not rebuild their paths.

## Independent DEBUG route

    DebugPhotoProcessing.process(CapturedPhoto or Data, output, configuration, components, skinMaskProvider)
      -> one static ImageProcessingPipeline<JobImage>
         -> admitted background ImageIO orientation/downsample (maximum 2048)
         -> MockFaceDetector<ProcessingImage>
         -> FaceDetectionResult.regions -> FaceRegion
         -> NaturalSkinRetouchSteps.make (default: Texture then Tone)
         -> TexturePreservingSkinSmoothingStep
            -> MockFaceLandmarkDetector -> FacialLandmarks (bound FaceRegion + local points)
            -> MockSkinMaskProvider -> region-bound SkinMaskResult (or unavailable)
            -> SoftFaceMaskGenerator (per-face coverage)
            -> FeatureProtectionMaskGenerator (filled/expanded/feathered semantics)
            -> DetailProtectionMaskGenerator (image gradients)
            -> EffectiveSkinMaskComposer: max(per-face coverage * semantic weights)
               with ProtectionMaskCombiner: max(features, edges * edgeStrength)
            -> two spatial bases / low-base noise reduction
            -> signed original-detail reconstruction
            -> intensity * paired skin coverage * (1 - combined protection)
            -> one masked blend -> shared CoreImageRendering
         -> NaturalSkinToneAdjustmentStep
            -> unchanged provider/mask helpers on texture result
            -> effective-mask-weighted local/reference luminance
            -> bounded neutral correction + lighting/shadow/highlight protection
            -> one tone photo blend -> same shared CoreImageRendering
      -> ImageProcessingOutput (rendered ProcessingImage + detection result)

Alternate DEBUG outputs are original, faceMask, skinMask, featureProtectionMask,
detailProtectionMask, combinedProtectionMask, effectiveSkinMask and difference.
New outputs are processedTexture (Texture only), toneAdjusted (Tone only) and
toneDifference (Tone-only rendered difference). All nine older outputs and both
aliases remain. See the Core Image README for all twelve modes and fallback visualization.
Processed defaults to Texture then Tone; components accepts textureOnly, toneOnly
or combined. NaturalSkinProcessingStep remains for existing legacy tests with no
default call site. Original and processed-at-zero permit
A/B with intensity 0, 0.25 and 0.5 without a slider or code changes to parameter defaults.
Previous processedPhoto/softFaceMask spellings remain aliases.

## Contracts and ownership

FaceRegion validates a finite positive rectangle within 0...1 with a bottom-left origin
in the oriented image. It has no confidence, tracking ID or landmarks. imageRect(in:)
includes nonzero extent origins. ImageIO applies all EXIF rotations/mirrors once before
detection. The step never changes geometry. ProcessingImage still wraps an immutable,
fully rendered CGImage; no lazy CIImage graph escapes the processing call.

FaceDetecting<Image> and ImageProcessingStep<Image> keep their existing synchronous
throwing interfaces. The pipeline has no concrete Mock, Vision, mask or renderer
dependency. Both retouch steps optionally accept FaceLandmarkDetecting<ProcessingImage>;
DEBUG injects MockFaceLandmarkDetector and MockSkinMaskProvider through the optional
SkinMaskProviding interface. The backend never names a concrete mock. SkinMaskResult
binds each finite, full-extent, opaque 0...1 scalar graph to its immutable FaceRegion;
input alpha scales semantic weights before normalization. No second mirror is applied.
FacialLandmarks stores validated face-local normalized points bound to one FaceRegion.
The pure semantic enum is shared with DetectedFace through an alias; the existing
preview's image-normalized points and camera metadata do not enter photo processing.
Missing/invalid/failed optional landmarks preserve the existing face + edge fallback.
Unavailable skin results use S=1 per face, keeping every other face and its protection.
The composer max-unions F*S pairs before one photo blend, so overlap never adds strength.

The pipeline's short NSLock admits one job; competing calls throw busy before decoding
or enqueueing. Loading, detection, steps and rendering run on its serial worker queue,
with an Apple autorelease pool. There are no Tasks or pending image lists. Errors keep
their original identity and release admission. Cancellation is checked before admission
and after successful work; synchronous work finishes before releasing its slot, and an
operation failure retains priority over racing cancellation.

All DEBUG output modes and configurations use that same static pipeline/admission slot.
Each immutable JobImage carries its output, selected components, validated settings and mock skin provider. A/B calls should be
sequential. There is no global mode switch, per-output queue or cached photo history.
CoreImageRendering retains one shared lazy bitmap CIContext for final and DEBUG
processing. Preview reuses its own MetalRenderer context bound to the command queue's
MTLDevice and initialized on the Preview worker. Both disable intermediate caching
and retain the default working color space; no context is created per frame or face.
Combined performs up to two RGBA8 renders, one per component; providers and mask
helpers may run twice on the respective component inputs. No graph fusion or
cross-step cache changes the protected texture implementation. All filters/graphs stay in the current call; caller-owned returned images should be
released when inspection finishes.

The composition factory returns no steps at intensity zero; both processing steps
return the exact input CGImage for intensity zero or no faces,
before invoking landmark or skin providers or constructing a CIImage, mask, filter or render.
Tone also bypasses for toneConsistencyStrength zero or maxLuminanceCorrection zero. Subpixel/nil coverage also returns
the input. Explicit diagnostic requests intentionally render visualization pixels;
original mode returns the common decoded preview directly. Mask alpha is opaque.
Processed-photo alpha is retained, with conservative bypass of transparent/translucent
neighborhoods. Existing RGBA8 output and working/output color-space policy remain.

MockFaceDetector, MockFaceLandmarkDetector, MockSkinMaskProvider, DebugPhotoProcessing and
the older brightness/face-mask probes remain wholly inside DEBUG guards. Reusable retouch
and mask types now have the explicit BeautyImageProcessor product call site. Scope checks
retain Release isolation and one-context rules. Metal is limited to Core Image texture
presentation; no custom shader, MPS, model, upload, network or third-party SDK was added.

See [CoreImage/README.md](CoreImage/README.md) for the complete formulas, fixed policy,
filter/kernel parameters, adaptive scale tradeoff, DEBUG examples and pixel tests.

## Responsibilities and tone policy

Mask determines allowed coverage; Protection excludes features and detail; Texture
retains the existing frequency reconstruction; Tone adds only a low-frequency neutral
luminance residual; Orchestration selects and orders these components.
**Tone Consistency ≠ Skin Whitening.** There is no fixed lift or target complexion,
no chroma adjustment, no global equalization or camera exposure/white-balance override.

The reference is normalized effective-mask-weighted luminance from this image, using
local radius clamp(0.025 * smallest face short side, 4, 32) and reference radius 3x.
Signed correction is clamp(0.2 * (reference - local), +/-maxLuminanceCorrection),
attenuated for strong lighting, high highlights, deep shadows, low statistical
support, translucency and insufficient channel headroom. Default new settings are
toneConsistencyStrength 0.25 and maxLuminanceCorrection 0.006 in the unchanged extended
linear sRGB working space. Existing intensity remains 0.25; the default pre-rounding
bound is 0.000375. Configuration rejects nonfinite/out-of-range values and caps the
luminance setting at 0.012. There is no maxChromaCorrection because chroma consistency
is deferred. Engineering defaults have not passed real-photo visual acceptance.

NaturalSkinRetouchSteps.make returns a step array; ImageProcessingPipeline remains
the sole worker/admission/loading/detection/error owner. Texture precedes Tone so the
new low-frequency residual is evaluated on the existing texture result, leaving the
texture implementation unchanged. The old fixed CIColorControls step is retained
only for compatibility/testing. No additional legacy kernel is introduced.

## Verification boundaries

- python scripts/check_project.py: project membership, dependency scope and localization.
- python -m unittest discover -s scripts/tests -v: 45 passing script/static tests,
  including Beauty capture, bypass, back-pressure and Release-isolation checks.
- scripts/check_swift_syntax.ps1: 88 Swift sources parse; four pure Swift Domain
  files and three camera control helpers typecheck on the installed host toolchain.
  An additional parser invocation with DEBUG also passed. This is not Apple typecheck.
- Previous host Foundation XCTest/typecheck attempts lacked msvcrt.lib, oldnames.lib,
  msvcprt.lib and errno.h. This task does not retry or repair those known paths.
- Existing Xcode Debug test target now has 24 source files, with 214 test methods by
  static count. New configuration, snapshot, frame-store, coordinate and synthetic-image
  methods are not executed on Apple here. Float formula tests explicitly request RGBAf
  intermediates, separate from public RGBA8 tests.
- git diff --check passed. Apple build, XCTest, Simulator, camera and GPU execution remain pending.

Natural Skin Processing Core Components 已完成代码层基础闭环。
这只代表基础组件代码完成，不代表视觉质量验收完成。
Natural Skin Tone / Illumination 的实际 Core Image 图像行为尚未在 Apple 平台验证。
Mock Skin Mask 不代表真实皮肤语义识别已经完成。
Apple Core Image / XCTest 实际运行验证暂缓，将在基础组件完成后统一执行。
真实 Vision 人脸检测 / landmarks 尚未验证。
真实 Skin Segmentation 尚未实现。
现有 CIColorKernel(source:) deprecated 风险未修改，没有新增 legacy kernel；Apple 验证待统一阶段。
尚未完成 Apple 平台 / 真机验收。
Xcode Build, pixel tests, Simulator, real photos, GPU, memory, thermals and performance
remain pending. Pushing triggers existing iOS CI; observing a trigger is not CI success.
This task stops immediately after trigger confirmation without waiting or polling.
The unified Apple acceptance phase and further beauty capabilities require a new task.
