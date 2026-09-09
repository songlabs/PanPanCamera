# Local photo processing pipeline

The camera still previews through AVCaptureVideoPreviewLayer and captures original
encoded data through AVCapturePhotoOutput. Its existing VisionFaceDetector preview
route, CameraFaceFrameProcessor, camera permissions, UI and photo path are unchanged.
That route is not evidence of successful real-face detection or device acceptance.

## Current DEBUG route

    DebugPhotoProcessing.process(CapturedPhoto or Data, output, configuration, skinMaskProvider)
      -> one static ImageProcessingPipeline<JobImage>
         -> admitted background ImageIO orientation/downsample (maximum 2048)
         -> MockFaceDetector<ProcessingImage>
         -> FaceDetectionResult.regions -> FaceRegion
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
      -> ImageProcessingOutput (rendered ProcessingImage + detection result)

Alternate DEBUG outputs are original, faceMask, skinMask, featureProtectionMask,
detailProtectionMask, combinedProtectionMask, effectiveSkinMask and difference.
See the Core Image README for the exact nine output semantics and fallback visualization.
Processed defaults to texture alone; NaturalSkinProcessingStep remains available for
its existing tone tests and is not stacked. Original and processed-at-zero permit
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
dependency. The texture step optionally accepts FaceLandmarkDetecting<ProcessingImage>;
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
Each immutable JobImage carries its output, validated settings and mock skin provider. A/B calls should be
sequential. There is no global mode switch, per-output queue or cached photo history.
CoreImageRendering still has one shared lazy CIContext with intermediate caching off.
All filters/graphs stay in the current call; caller-owned returned images should be
released when inspection finishes.

The processing step returns the exact input CGImage for intensity zero or no faces,
before invoking landmark or skin providers or constructing a CIImage, mask, filter or render. Subpixel/nil coverage also returns
the input. Explicit diagnostic requests intentionally render visualization pixels;
original mode returns the common decoded preview directly. Mask alpha is opaque.
Processed-photo alpha is retained, with conservative bypass of transparent/translucent
neighborhoods. Existing RGBA8 output and working/output color-space policy remain.

MockFaceDetector, MockFaceLandmarkDetector, MockSkinMaskProvider, DebugPhotoProcessing and the brightness/face-mask probes are wholly
inside DEBUG guards. Reusable retouch, mask and rendering types have no product/camera
call sites. Scope checks compile Release redeclaration probes, inspect build conditions,
reject product call sites and guard the one-context/no-new-queue rule. No formal UI,
save hook, upload, network, model, third-party SDK, custom Metal renderer or MPS spike
was added.

See [CoreImage/README.md](CoreImage/README.md) for the complete formulas, fixed policy,
filter/kernel parameters, adaptive scale tradeoff, DEBUG examples and pixel tests.

## Verification boundaries

- python scripts/check_project.py: project membership, dependency scope and localization.
- python -m unittest discover -s scripts/tests -v: 39 passing script/static tests,
  including 12 processing scope/Release-isolation checks and the new mock exclusion probe.
- scripts/check_swift_syntax.ps1: 79 Swift sources parse; four existing pure Swift Domain
  files and three camera control helpers typecheck on the installed host toolchain.
  An additional parser invocation with DEBUG also passed. This is not Apple typecheck.
- Previous host Foundation XCTest/typecheck attempts lacked msvcrt.lib, oldnames.lib,
  msvcprt.lib and errno.h. This task does not retry or repair those known paths.
- Existing Xcode Debug test target now has 21 source files, with 157 test methods by
  static count. This addition prepares 25 XCTest methods across semantic mask,
  effective composer, processing integration and DEBUG output checks; not executed here.
- git diff --check passed. All modifications stay in Rendering, Tests, project
  membership, README and Python processing scope checks.

Skin Semantic Mask Infrastructure v1 及 Natural Skin Processing 基础 Mask 链路已经完成代码实现，
并完成当前环境可执行静态验证。
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
