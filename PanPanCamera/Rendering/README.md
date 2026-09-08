# Local photo processing pipeline

The camera still displays `AVCaptureVideoPreviewLayer` and captures original encoded
data with `AVCapturePhotoOutput`. Its existing `VisionFaceDetector` analyzes preview
buffers and returns landmark-rich `FaceDetectionFrame` values. That existing route is
unchanged and is not evidence of successful real face detection or device acceptance.
The experimental skin step reuses the existing still-image pipeline and coordinate
contract without changing camera ownership or the pipeline's step interface.

The explicit development/test entry point is:

```swift
#if DEBUG
let output = try await DebugPhotoProcessing.process(photo) // existing CapturedPhoto
// output.image.cgImage is rendered; output.detection.regions are SYNTHETIC.
let mask = try await DebugPhotoProcessing.process(photo, output: .softFaceMask)
// mask.image.cgImage is an opaque black-background, white-coverage preview.
// Inspect it with the debugger's image viewer or a temporary developer/test view.
#endif
```

Synthetic encoded data can also enter through `process(data:output:)`, without camera access.
There is no automatic capture hook or product UI. Original `CapturedPhoto.data` and its
normal display path are unchanged. Results are returned to the caller in memory only.

```text
CapturedPhoto.data / encoded test photo
  -> background ImageIO decode + EXIF orientation/mirroring (maximum 2048 pixels)
  -> ProcessingImage (immutable, upright CGImage)
  -> existing ImageProcessingPipeline (private DEBUG job carries image + output mode)
     -> MockFaceDetector<ProcessingImage> in DEBUG
     -> FaceDetectionResult.regions -> FaceRegion.boundingBox
     -> NaturalSkinProcessingStep
        -> SoftFaceMaskGenerator -> merged soft ellipse mask
        -> CIColorControls -> one CIBlendWithMask -> rendered ProcessingImage
     OR DebugFaceMaskStep -> rendered black/white mask
  -> ImageProcessingOutput (rendered image + detection result)
```

`FaceRegion` validates a finite, positive rectangle within [0, 1], with a bottom-left
origin in the oriented image. It has no ID, confidence, landmarks or frame metadata.
The existing preview model has a different purpose and is not imposed on this API.
No second orientation enum is needed: the loader applies EXIF before detection.
`imageRect(in:)` preserves the image extent origin and clips numerical roundoff.

`FaceDetecting<Image>` has one synchronous throwing method. Image is the only generic
parameter; it permits the same coordination tests to use small Data fixtures on a host
without Core Image. The pipeline holds protocol existentials, never a Mock or Vision
type. In a later task, the existing `VisionFaceDetector` can gain conformance with
`Image = ProcessingImage` and a photo-input method, then replace the injected detector
without editing the pipeline. No new Vision implementation or landmark interface is
part of this change.

The pipeline owns a serial worker queue. A short NSLock admits one job and returns
`ImageProcessingError.busy` for competing calls before decoding/enqueueing. It creates
no Tasks, pending image arrays or main-queue result callbacks. Loading, detection,
steps and Core Image rendering all complete off main before the async call returns.
Loader/detector/step errors propagate unchanged, including the original error object.
Failures release the slot. Cancellation is checked before admission and after successful
work; synchronous work finishes before freeing its slot, and an operation error retains
priority. Steps preserve dimensions/orientation so all steps receive the same regions.
Empty detection is successful: steps receive an empty list; the regional skin/probe step returns
the exact input CGImage. An empty step list also returns the original image.
The explicit mask visualization instead returns opaque black when there is no coverage.

Both DEBUG output modes use one static pipeline and the same admission slot. A private,
immutable job value carries the mode through decoding/detection/processing; there is no
mutable global switch and no second queue for mask previews. The pipeline implementation
and `ImageProcessingStep` contract remain unchanged. Neither depends on a mask algorithm.

No image is retained in pipeline state. Jobs use an autorelease pool on Apple platforms;
the shared CIContext disables intermediate caching. Debug decoding uses the existing
2048-pixel preview policy to bound this development exercise. This is not a full-size
photo export or a memory/performance result from hardware. The caller owns returned
images and must release them when finished. Metal remains a placeholder; no custom
Metal, Core ML, third-party SDK, file storage or network API is introduced.

`MockFaceDetector`, the brightness/mask probes and the developer entry point are entirely
inside `#if DEBUG`; the production contract has no default detector. Release has no
Mock construction or developer entry point. Static tests also reject product call sites
and compile a Release redeclaration probe to verify that these types are absent.
`FaceMaskGenerating`, `SoftFaceMaskGenerator`, `NaturalSkinProcessingStep` and the shared
Core Image renderer are reusable internal types, but have no camera/product call site.
The old rectangular brightness probe remains available only for its existing DEBUG tests;
it is no longer the developer entry point's default processing step.

See [CoreImage/README.md](CoreImage/README.md) for ellipse geometry, feather parameters,
multi-face union, adjustment values, replacement boundary and image tests.

Validation commands:

- `python scripts/check_project.py`: project membership, dependency scope, localization.
- `python -m unittest discover -s scripts/tests -v`: static/Release isolation and existing script tests.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check_swift_syntax.ps1`: syntax and existing pure Swift checks.
- `python scripts/run_pipeline_tests.py`: actual Foundation XCTest on a complete host Swift SDK; uses unchanged app/test sources in `.verification`.
- Existing Xcode Debug XCTest discovers `ImageProcessingPipelineTests`, `DebugPhotoProcessingTests`,
  `SoftFaceMaskTests` and `NaturalSkinProcessingTests` in the shared test target.

Local verification for this change: 34 Python tests passed, including seven processing
scope/Release-isolation tests; project checks passed for 47 app and 12 XCTest source files;
all 59 Swift files parsed both with and without `DEBUG`. The existing four pure Swift
domain files and three camera control helpers passed host typechecking. Parsing emits
Windows-SDK/iPhone-target warnings and is not an Apple SDK typecheck or build.
The host XCTest harness was attempted but could not link its manifest because `msvcrt.lib`,
`oldnames.lib` and `msvcprt.lib` are missing. No host XCTest ran. Xcode, Apple Core Image
pixel tests, Simulator image inspection and device acceptance remain unexecuted here.
Soft Face Mask 和 NaturalSkinProcessingStep 的实际 Core Image 图像效果尚未在 Apple 平台执行验证。
真实 Vision 人脸检测尚未验证。尚未完成 Apple 平台 / 真机验收。
