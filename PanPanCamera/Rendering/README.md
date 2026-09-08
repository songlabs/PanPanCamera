# Local photo processing pipeline

The camera still previews through AVCaptureVideoPreviewLayer and captures original
encoded data through AVCapturePhotoOutput. Its existing VisionFaceDetector preview
route, CameraFaceFrameProcessor, camera permissions, UI and photo path are unchanged.
That route is not evidence of successful real-face detection or device acceptance.

## Current DEBUG route

    DebugPhotoProcessing.process(CapturedPhoto or Data, output, configuration)
      -> one static ImageProcessingPipeline<JobImage>
         -> admitted background ImageIO orientation/downsample (maximum 2048)
         -> MockFaceDetector<ProcessingImage>
         -> FaceDetectionResult.regions -> FaceRegion
         -> TexturePreservingSkinSmoothingStep
            -> SoftFaceMaskGenerator (max union)
            -> DetailProtectionMaskGenerator (image gradients)
            -> two spatial bases / low-base noise reduction
            -> signed original-detail reconstruction
            -> intensity * face coverage * detail protection weight
            -> one masked blend -> shared CoreImageRendering
      -> ImageProcessingOutput (rendered ProcessingImage + detection result)

Alternate DEBUG outputs are original, faceMask, detailProtectionMask and difference.
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
dependency. No second rendering architecture or future detector abstraction is added.

The pipeline's short NSLock admits one job; competing calls throw busy before decoding
or enqueueing. Loading, detection, steps and rendering run on its serial worker queue,
with an Apple autorelease pool. There are no Tasks or pending image lists. Errors keep
their original identity and release admission. Cancellation is checked before admission
and after successful work; synchronous work finishes before releasing its slot, and an
operation failure retains priority over racing cancellation.

All DEBUG output modes and configurations use that same static pipeline/admission slot.
Each immutable JobImage carries its output and validated settings. A/B calls should be
sequential. There is no global mode switch, per-output queue or cached photo history.
CoreImageRendering still has one shared lazy CIContext with intermediate caching off.
All filters/graphs stay in the current call; caller-owned returned images should be
released when inspection finishes.

The processing step returns the exact input CGImage for intensity zero or no faces,
before constructing a CIImage, mask, filter or render. Subpixel/nil coverage also returns
the input. Explicit diagnostic requests intentionally render visualization pixels;
original mode returns the common decoded preview directly. Mask alpha is opaque.
Processed-photo alpha is retained, with conservative bypass of transparent/translucent
neighborhoods. Existing RGBA8 output and working/output color-space policy remain.

MockFaceDetector, DebugPhotoProcessing and the brightness/face-mask probes are wholly
inside DEBUG guards. Reusable retouch, mask and rendering types have no product/camera
call sites. Scope checks compile Release redeclaration probes, inspect build conditions,
reject product call sites and guard the one-context/no-new-queue rule. No formal UI,
save hook, upload, network, model, third-party SDK, custom Metal renderer or MPS spike
was added.

See [CoreImage/README.md](CoreImage/README.md) for the complete formulas, fixed policy,
filter/kernel parameters, adaptive scale tradeoff, DEBUG examples and pixel tests.

## Verification boundaries

- python scripts/check_project.py: project membership, dependency scope and localization.
- python -m unittest discover -s scripts/tests -v: 36 passing script/static tests, including
  nine processing scope/Release-isolation checks.
- scripts/check_swift_syntax.ps1: 65 Swift sources parse; four existing pure Swift domain
  files and three camera control helpers typecheck on the installed host toolchain.
  An additional parser invocation with DEBUG also passed. This is not Apple typecheck.
- python scripts/run_pipeline_tests.py: same actual Foundation pipeline/configuration
  sources and XCTest files in an ignored host package. Attempted here but blocked before
  test execution by missing msvcrt.lib, oldnames.lib and msvcprt.lib. Separate Foundation
  typecheck/module emission also hit missing errno.h. No host XCTest ran.
- Existing Xcode Debug test target now has 15 source files, including the three new
  configuration/texture/protection suites and expanded DebugPhotoProcessingTests.
  Twenty new XCTest methods are registered; none ran in the Windows environment.

Texture-Preserving Natural Skin Retouch v1 已完成代码实现和当前环境可执行验证，
但实际 Core Image 图像效果尚未在 Apple 平台验证。
真实 Vision 人脸检测尚未验证。尚未完成 Apple 平台 / 真机验收。
Xcode Build, Apple pixel tests, Simulator, real photos, GPU, memory, thermals and
device performance remain pending. Pushing triggers existing iOS CI; observing a
trigger is not CI success. This task stops after trigger confirmation.
