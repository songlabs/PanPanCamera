# Preview strength investigation

Investigated baseline: `4a760d0e67e509e64247a369321e609399424520`, clean `main`,
equal to `origin/main` and the remote main ref before changes. Windows host; no
Xcode, Core Image runtime, iPhone, or new device recording was available.

## Confirmed cause and limits

`FaceCorrectionPreviewStep.displacementMap` placed every encoded radial field over
the previous map with `CISourceOverCompositing`. This is image-layer compositing,
not vector addition. For a later field with coverage `a`, the decoded movement
became `later * a + earlier * (1 - a)`. At `a = 1`, the earlier effect vanished.
[Apple's filter reference](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/index.html#//apple_ref/doc/filter/ci/CISourceOverCompositing)
documents this source-over operation.

Slim and Chin use the same lower-contour anchors. Their center insets are 1.8%
and 2.5% of face width: separation 0.7%. Chin's opaque inner radius is
`30% * 17% = 5.1%` of face width. Consequently its later field completely
overwrote Slim at the Slim anchor. Width and Cheekbones can also share an anchor;
later Cheekbones fields similarly suppress earlier Width fields. Feathered
overlap elsewhere also attenuates previous vectors. The last effect's coverage
was independent of its strength, so even a small admitted effect could erase a
larger earlier one. Existing pixel fixtures isolated Slim and missed this case.

For face width 600 px, Face Auto 0.5, Chin UI 50, the old map immediately after
Chin at the Slim center was:

| Slim UI, normalized | Effective Slim | Requested Slim dx | Old dx after Chin | Correct sum at that point, Slim + Chin only |
| --- | --- | --- | --- | --- |
| 0 | 0 | 0 px | 1.5 px | 1.5 px |
| 0.25 | 0.125 | 4.5 px | 1.5 px | 6 px |
| 0.5 | 0.25 | 9 px | 1.5 px | 10.5 px |
| 0.75 | 0.375 | 13.5 px | 1.5 px | 15 px |
| 1 | 0.5 | 18 px | 1.5 px | 19.5 px |

Signs reverse on the other side. Other overlapping fields contribute according
to their own support; these are source-derived arithmetic values, not device
measurements. An overlay reporting a 10 px request could not detect this loss.

This confirms a shared multi-effect composition defect. It does not prove that
every isolated effect, skin retouch, or every reported device symptom has the
same cause. Forehead and the skin effects also use deliberately small design
coefficients. Real-face visibility, render success/fallback frequency and device
performance still need measurement.

## Parameter chain and actual code values

1. `ParameterSlider` binds 0...100 directly into `BeautyParameters.setValue`.
   Each panel mutates the shared `$camera.beautyParameters` binding.
2. `CameraService.beautyParameters` is `@Published`; its `didSet` synchronously
   calls `CameraSession.setBeautyConfiguration` after each mutation.
3. `processingConfiguration` divides each UI value by 100 exactly once; the
   initializer bounds finite values to 0...1. In-range values are unchanged.
4. `CameraSession` replaces the same lock-protected `BeautyConfigurationStore`.
   The frame delegate retains that store reference, not its initial value.
5. `CameraFaceFrameProcessor.publishPreview` snapshots the store on every
   delivered buffer before the Vision throttle, and again after detection when
   applicable. Vision result reuse does not freeze strength updates.
6. `BeautyPreviewFrameStore` keeps only the newest immutable frame/configuration.
   `BeautyPreviewRenderer` takes that frame for one in-flight rendering operation.
7. `BeautyImageProcessor.previewResult` uses `frame.configuration` for skin and
   geometry. `effectiveFaceX = faceOverallStrength * faceXStrength` is applied once
   when calculating the warp vector. No extra Preview strength exists.
8. Cache identity includes every warp's kind, center, radius and offset plus the
   target extent. Strength changes that alter a vector rebuild the map. Empty
   warps clear the cache; no temporal blending or stale processor configuration
   was found. An already in-flight frame can contain a prior immutable snapshot;
   the queue does not hold an accumulating backlog.
9. The sampling kernel consumes the composed map in CI pixel coordinates. The
   renderer submits it to the Metal destination and displays only successful
   results. Configuration changes invalidate prior renderer generations. The
   fallback remains the original camera layer; overlay data alone is not proof
   of successful Metal presentation.

For single UI 50 with default Auto 50: normalized input **0.5**, store **0.5**,
frame **0.5**, processor raw input **0.5**, effective/Preview geometry strength
**0.25**. At Auto 100 the effective strength is **0.5**. With Auto 100 and UI 100,
the effective strength is **1.0**. Tests retain both sets of semantics.

At UI/Auto 50, with fitted face width `W` and height `H`, each geometry input is:

| Effect | Effective strength | Individual requested visible movement | Radius |
| --- | --- | --- | --- |
| Slim | 0.25 | left/right `+/- 0.030 W` | `0.22 W` |
| Width | 0.25 | left/right `+/- 0.011 W` | `0.18 W` |
| Chin sides | 0.25 | left/right `+/- 0.005 W` | `0.17 W` |
| Chin center | 0.25 | upward `0.009 H` | `0.20 W` |
| Forehead | 0.25 | downward `0.006 H` | `0.19 W` |
| Cheekbones | 0.25 | left/right `+/- 0.0075 W` | `0.16 W` |

All use the same inner-radius fraction 0.30 and outer-radius falloff. The final
map is the sum of these vectors times their local coverage, with inverse signs
for source sampling. There is no single per-effect final pixel displacement
independent of the other enabled effects; diagnostics distinguish the two.

## Halving, scaling, and Preview/Photo differences

- Both Auto controls default to 50 and intentionally multiply their category.
  Skin semantics entered in `142f23c`; Face semantics entered in `271aa31`.
  Their current comments, tests and architecture document this user-controlled
  multiplier. No additional fixed Preview-wide `* 0.5`, stale parameter cache,
  repeated UI normalization, or performance-driven strength-halving was found.
  Auto remains functional; removing its multiplication would change its meaning.
- `previewScale` limits drawable resolution to a 1280-pixel long edge. Image and
  landmarks are fitted once; displacement/radius use that fitted face's pixel
  dimensions. There is no second multiplication by resolution scale. Cropped
  face boxes and unavailable anchors still have the existing geometry limits.
- RG's neutral `0.5`, encoding division by map scale, matching decode
  multiplication and the ROI's `scale / 2` are coordinate representation and
  sampling bounds, not strength attenuation.
- Five geometry effects exist: Slim, Width, Chin, Forehead, Cheekbones. Eyes,
  eye spacing/height, nose and mouth controls have no processor. Face geometry
  is intentionally Preview-only; Photo does not run a second, weaker warp.
- Three skin effects exist: smoothing, brightening and tone. They share the
  shutter/live configuration semantics but Preview uses these lighter settings:

| Skin setting | Preview | Photo |
| --- | --- | --- |
| Detail retention for smoothing | 0.88 | 0.80 |
| Smoothing noise reduction | 0.006 | 0.015 |
| Local brightening candidate | 0.06 | 0.06 |
| Tone consistency coefficient | 0.40 | 0.50 |
| Tone luminance correction cap | 0.004 | 0.006 |

The effective skin mask includes intensity once, plus region/feature/detail
protection. Tone removes intensity for reference-support estimation, then applies
it once in its final blend. Smoothing detail attenuation (`1 - retention`), the
brightening candidate, tone blend coefficient and every geometry displacement
ratio are now twice the investigated baseline. The mid-frequency coefficient `0.5` is a
frequency-retention policy, and tone's `0.5` arithmetic bias cancels on decoding.
Neither halves all effects. At UI/Auto 50 the tone correction upper bound before
additional protection is `0.25 * 0.40 * 0.004 = 0.0004` linear luminance in Preview
versus `0.00075` in Photo. The correction cap is unchanged, so this mapping
amplifies the final adjustment only once.

## Minimal repair and validation boundary

The common map now adds each signed inverse displacement weighted by the same
radial falloff. Neutral bias is added only once. Encoding scale bounds the sum
of vector magnitudes, ensuring 0...1 RG without clipping, and cancels in decoding.
The composition repair did not alter isolated amplitudes. The subsequent product
mapping update doubles only each implemented effect's candidate amplitude; radius,
falloff, Auto semantics, masks, camera acquisition, Vision, UI layout, saving and
lifecycle remain unchanged.

New tests cover all eight implemented UI strengths at 0/0.25/0.5/0.75/1, direct
CameraService publication for all five geometry controls, the configuration/frame
stores and actual Preview geometry at two resolutions, all five effects' fixed
Preview pixels at 0/0.5/1, combined effects with other controls at default values,
cache updates back to zero, vector overlap/order/cancellation, and actual sampled
X/Y displacement. Existing Metal and locality tests remain in place.

Opt-in DEBUG argument: `-PanPanBeautyStrengthDiagnostics`. Configuration changes
log at most once per second; continuous dragging eventually logs the latest value.
Logs report each UI/effective/Preview/processor strength, face dimensions, each
active warp radius and requested vector, and a working-space sample of the actual
combined production map. Combined map vectors include other effects at that point.
Renderer success/fallback transitions are logged separately. Readback reuses the
existing bitmap context and does not run in Release or ordinary DEBUG launches.
Face availability transitions are also eligible for a throttled report, so a
first frame without landmarks cannot suppress later map measurements.

Executed locally after the repair:

- `python -B scripts/check_project.py`: passed project/source/scope/localization checks.
- `python -B -m unittest discover -s scripts/tests -p test_image_processing_scope.py -q`:
  18 existing scope tests passed.
- `scripts/check_swift_syntax.ps1`: 89 Swift files parsed; pure Swift domain and
  camera helper typechecks passed. Changed Swift files also parsed with `-D DEBUG`.
- `git diff --check`: passed.
- Independent Python arithmetic oracle: 400 cases across five strength levels,
  two Auto values, two resolutions and mixed falloff weights; encoded vectors
  stayed bounded and decoded without an extra strength scale. The old Slim/Chin
  overwrite counterexample was reproduced. This is not an execution of Core Image.

Attempted Swift host execution was blocked: Foundation compilation could not find
`errno.h`; a separate pure-Swift interpreter attempt could not load the Windows
standard library. No host Swift execution or XCTest result is claimed.

Windows source checks and host numerical checks are not Apple pixel evidence.
The new XCTest/Core Image/Metal tests, visible CAMetalLayer output, true SwiftUI
dragging and iPhone appearance/performance require Apple execution.
**尚未完成 Apple 平台 / 真机验收。**
