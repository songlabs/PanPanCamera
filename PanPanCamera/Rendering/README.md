# Local photo processing pipeline

The camera still displays `AVCaptureVideoPreviewLayer` and captures original encoded
data with `AVCapturePhotoOutput`. Its existing `VisionFaceDetector` analyzes preview
buffers and returns landmark-rich `FaceDetectionFrame` values. That existing route is
unchanged and is not evidence of successful real face detection or device acceptance.
There was no existing still-image processing interface to reuse. This implementation
uses the existing FaceTracking/Rendering directories, without changing camera ownership.

The explicit development/test entry point is:

```swift
#if DEBUG
let output = try await DebugPhotoProcessing.process(photo) // existing CapturedPhoto
// output.image.cgImage is rendered; output.detection.regions are SYNTHETIC.
#endif
```

Synthetic encoded data can also enter through `process(data:)`, without camera access.
There is no automatic capture hook or product UI. Original `CapturedPhoto.data` and its
normal display path are unchanged. Results are returned to the caller in memory only.

```text
CapturedPhoto.data / encoded test photo
  -> background ImageIO decode + EXIF orientation/mirroring (maximum 2048 pixels)
  -> ProcessingImage (immutable, upright CGImage)
  -> ImageProcessingPipeline<ProcessingImage>
     -> any FaceDetecting<ProcessingImage> (injected MockFaceDetector in DEBUG)
     -> FaceDetectionResult.regions -> FaceRegion.boundingBox
     -> ordered ImageProcessingStep values (DebugFaceBrightnessStep in DEBUG)
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
Empty detection is successful: steps receive an empty list; the regional probe returns
the exact input CGImage. An empty step list also returns the original image.

No image is retained in pipeline state. Jobs use an autorelease pool on Apple platforms;
the shared CIContext disables intermediate caching. Debug decoding uses the existing
2048-pixel preview policy to bound this development exercise. This is not a full-size
photo export or a memory/performance result from hardware. The caller owns returned
images and must release them when finished. Metal remains a placeholder; no custom
Metal, Core ML, third-party SDK, file storage or network API is introduced.

`MockFaceDetector`, the brightness probe and the developer entry point are entirely
inside `#if DEBUG`; the production contract has no default detector. Release has no
Mock construction or developer entry point. Static tests also reject product call sites
and compile a Release redeclaration probe to verify that these types are absent.

Validation commands:

- `python scripts/check_project.py`: project membership, dependency scope, localization.
- `python -m unittest discover -s scripts/tests -v`: static/Release isolation and existing script tests.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check_swift_syntax.ps1`: syntax and existing pure Swift checks.
- `python scripts/run_pipeline_tests.py`: actual Foundation XCTest on a complete host Swift SDK; uses unchanged app/test sources in `.verification`.
- Existing Xcode Debug XCTest runs both `ImageProcessingPipelineTests` and `DebugPhotoProcessingTests`.

Windows in this task lacks Xcode and the C/Windows SDK needed by Foundation (`errno.h`
is missing); the host XCTest harness also cannot link its manifest because `msvcrt.lib`,
`oldnames.lib` and `msvcprt.lib` are missing. Static checks are distinct from executing
Foundation/XCTest or Core Image.
The Apple tests cover localized pixel changes, outside-region preservation, alpha,
overlap, image edges, EXIF rotations/mirrors, bounded decoding and the CapturedPhoto bridge.
真实 Vision 人脸检测尚未验证。尚未完成 Apple 平台 / 真机验收。
