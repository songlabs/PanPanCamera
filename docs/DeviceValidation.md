# Simulator evidence and real-device acceptance

GitHub Simulator execution and real iPhone acceptance are separate. Record the actual commit SHA, run ID/link, Xcode, device/OS, results and artifacts. Obtain current-SHA evidence using the Last verified baseline section in [README](../README.md); this document does not embed its own SHA or predict successful runs.

## GitHub Simulator — actual run evidence

The [iOS CI](https://github.com/songlabs/PanPanCamera/actions/workflows/ci.yml?query=branch%3Amain) and [Simulator Screenshot](https://github.com/songlabs/PanPanCamera/actions/workflows/simulator-screenshot.yml?query=branch%3Amain) pages hold execution records. Check `head_sha` against the checkout and require both workflows to finish successfully. An older successful run does not complete acceptance for a new SHA.

| Verification | Current suite / required evidence |
| --- | --- |
| Debug XCTest | 210 methods are statically declared across 24 test sources, including Face Correction parameter/geometry/bypass/mirror tests. Read actual executed totals from PanPanCameraTests.xcresult. |
| Release Screenshot isolation XCTest | 5 methods; read ReleaseScreenshotTests.xcresult summary, not the Debug result. |
| Release Simulator Build | Require the dedicated xcodebuild build step to succeed. This is not a device Archive. |
| Delivery scripts | 45 Python tests, including strict three-part versions, Face Correction scope and dynamically generated PNG corruption cases. |
| Screenshot output | Exactly 10 PNGs: five-language camera screens plus ja beauty/reshape/filter/makeup/settings. Read actual device/iOS and native resolution from that run. |
| PNG validation | Require IDAT, valid complete zlib data, IHDR-consistent scanlines, filters, CRC, file coverage and native resolution; also require macOS sips reads. |
| Artifact review | Download panpan-simulator-screenshots; open all images and check target screens, languages, black frames, permission dialogs and visible text overflow. Record that inspection separately from workflow success. |

Only rows with actual matching-SHA run/step evidence are completed. Diagnostics retain test result bundles, exported summaries, Xcode/Simulator logs and screenshot inventory for 7 days. The workflow implementation, source test count and a green historical badge alone are not execution evidence for the current checkout.

## Test coverage is not hardware acceptance

Permission tests deterministically suspend authorization across inactivity and reread permission after Settings. Input replacement tests execute the production transaction helper for success, rollback and failed rollback. Photo tests use the production processor transitions and registry, including weak-reference cleanup and stale IDs after reset. Recovery tests exercise the production wantsRunning policy and inactive handling of delayed running events. These tests do not create camera hardware or prove AVFoundation notification timing.

## Additional Xcode / Simulator checks

1. Open PanPanCamera.xcodeproj and the shared scheme. The deployment target is iOS 17; CI pins Xcode 26.3 and selects an available iOS 26.x iPhone. Running on iOS 17 and building with the minimum documented Xcode toolchain remain separate, unexecuted checks.
2. Run the current 210-method Debug suite and 5 Release isolation methods, preserving the .xcresult outside tracked files.
3. Check ja, zh-Hans, zh-Hant, en and ko compiled resources; confirm PanPan is untranslated. System permission dialogs and every panel in every language still need visual acceptance.
4. Check small and large iPhones, default/accessibility text sizes, VoiceOver, safe areas, scrolling and long English/Korean text. Screenshot Mode uses large sheets; separately inspect ordinary medium sheets.
5. Simulator Screenshot uses a Debug-only SwiftUI testing background and bypasses CameraSession creation and permission requests. It cannot validate real preview, flash, captures or switching. Release/TestFlight ignore screenshot arguments.

## Real Device Validation Pending

Every checklist item below is currently **Pending**. Use a real iPhone and record model, OS, commit and observation for each executed item.

### Camera Permission

- [ ] Pending — first launch and grant: one camera prompt, live preview, no microphone prompt; add-only Photos prompt occurs only after capture/save.
- [ ] Pending — deny: localized explanation and Settings link, shutter disabled.
- [ ] Pending — Settings return: revoke/restore access and confirm foreground reflects current authorization.
- [ ] Pending — restricted: where device controls permit testing, show restriction explanation without a misleading grant button.

### Preview

- [ ] Pending — rear camera live preview.
- [ ] Pending — front camera live preview.
- [ ] Pending — physically rotate the device while the UI stays portrait; check preview rotation and aspect-fill cropping.

### Camera Switch

- [ ] Pending — repeated front/rear switching retains one working input.
- [ ] Pending — become inactive during switching, then return; state and actual input agree.
- [ ] Pending — rapid taps cannot submit competing switch/capture operations.
- [ ] Pending — where a failure can be induced, restored input works; failed rollback exposes retryable failure.

### Flash

- [ ] Pending — rear Off uses no flash.
- [ ] Pending — rear Auto follows actual scene/capability.
- [ ] Pending — rear On uses supported hardware flash through photo settings.
- [ ] Pending — front camera without hardware flash disables flash and resets Off.
- [ ] Pending — temporary flash unavailability updates controls and is rechecked at capture.

### Photo

- [ ] Pending — rear capture saves the final full-resolution Data and presents its result preview.
- [ ] Pending — front capture uses the same mirror policy as front preview.
- [ ] Pending — portrait, landscape left, landscape right and upside down: check original metadata and displayed orientation independently.
- [ ] Pending — mirrored text/asymmetrical-object test on front and rear; rear stays unmirrored.
- [ ] Pending — full photo keeps native sensor edges that the aspect-fill preview crops.
- [ ] Pending — repeated shutter taps produce one active capture.
- [ ] Pending — saved photo appears in Photos; dismissing the result releases its in-memory object and resumes the same camera session.

### Lifecycle

- [ ] Pending — Home then reopen.
- [ ] Pending — lock then unlock.
- [ ] Pending — system permission popup while activation is pending.
- [ ] Pending — switch to another app and return repeatedly.
- [ ] Pending — capture then background; completion/failure clears busy state and the shutter recovers.

### Interruption / Reset

- [ ] Pending — induce camera interruption where possible; present status and resume only while active.
- [ ] Pending — induce media services reset where possible; verify recovery and eventual processor cleanup.
- [ ] Pending — verify capture A invalidation, capture B and late A completion on hardware if reproducible.

If these conditions cannot be produced, retain Pending rather than treating unit tests as device evidence.

### Parameters and privacy

- [ ] Pending — six skin and thirteen face controls retain independent 0–100 values across panel changes.
- [ ] Pending — Face Correction notice names the five live Preview controls and accurately says the remaining controls/photo application are pending.
- [ ] Pending — blemish, dark-circle, eye/nose/mouth, filter and makeup controls do not alter pixels.
- [ ] Pending — video/portrait/album/timer/ratio remain explicitly unavailable; no simulated effects.
- [ ] Pending — add-only Photos save works; no camera/photo/face upload, network request or face-data persistence occurs.

### Beauty Preview and Final Photo

For the skin-only retouch check, use the same front-facing subject, camera, distance,
lighting and parameter values on the parent commit and the candidate commit. Save the
two PhotoOutput results as `before` and `after`, then run the DEBUG
`DebugPhotoProcessing.beautyMaskOverlay` output on the candidate source. Cyan marks the
beauty ROI, green is the final effective skin coverage, and red is excluded non-skin or
protected detail. These three images are the required comparison artifact; do not use a
preview screenshot as the PhotoOutput result.

- [ ] Pending — the cyan ROI is the face box expanded 15% at the top and 5% on each side,
      clamped at image edges.
- [ ] Pending — green covers the central forehead and the skin immediately below the
      hairline; red/no coverage remains on hair, eyes, eyebrows, lips, nostril detail and
      visible glasses frames.
- [ ] Pending — compare Preview, PhotoOutput and silent frame: mask boundaries and effect
      direction agree after accounting for resolution, orientation and front-camera mirror.
- [ ] Pending — inspect the feathered green/red transition at 200% for hard edges or halos.

- [ ] Pending — overall strength 0 reveals the original preview path; 0 to 100 changes the live face result without reopening the panel.
- [ ] Pending — Face Auto scales the same five local effects; Slim narrows the lower face without shrinking eyes/nose/mouth.
- [ ] Pending — Width changes the side contour only; Chin remains subtle without a sharp V-face result.
- [ ] Pending — Forehead changes only when stable eyebrow/face geometry exists; inspect hairline, brows, glasses and hair edges.
- [ ] Pending — Cheekbones stay local and do not produce dents; rapidly scrub every Face Correction slider.
- [ ] Pending — move near/far and left/right, wear glasses, leave/re-enter the frame, and compare front/rear cameras.
- [ ] Pending — in multi-face scenes, the largest face wins, with nearest-center tie-breaking; selection does not oscillate visibly.
- [ ] Pending — Face Correction affects Preview only; captured-photo pixels do not acquire these five geometry changes.
- [ ] Pending — smoothing retains texture and protects eyes, lips, brows, hair/background and text from visible blur or halos.
- [ ] Pending — brightening and tone stay subtle across different skin tones and lighting, without clipping or global color/gamma shifts.
- [ ] Pending — zero/one/multiple faces, profile, occlusion and rapid movement do not freeze or black out preview.
- [ ] Pending — front/rear, camera switching, foreground/background and physical rotations preserve aspect fill, orientation and one front mirror.
- [ ] Pending — PhotoOutput and silent-frame captures use the shutter-time parameter snapshot and match preview direction.
- [ ] Pending — PhotoOutput retains its native maximum dimensions; silent capture retains its native VideoDataOutput dimensions without upscale.
- [ ] Pending — force/observe a preview processing failure and confirm the underlying original preview continues; final failure must not save damaged data.
- [ ] Pending — profile FPS, preview latency, shutter latency, CPU/GPU, memory, thermal behavior and repeated Beauty captures on real devices.

## Vision face detection — all device checks Pending

Use the current TestFlight or Debug build; `FaceGeometryDebugMode.isEnabled` makes the
diagnostic visible without a launch argument. Green is the production-fitted primary
face box, yellow is the accepted face contour, cyan circles are the exact small-face
radii, pink crosses are the centers and orange arrows are the applied visible offsets.
The text block shows detection, strength, fitted width, displacement, orientation and
mirror state. These values come from the same renderer-space geometry result sent to the
production displacement step; do not log/export face coordinates or images.

- [ ] Front and rear: zero, one and multiple faces; all faces returned without primary-face selection.
- [ ] Boxes and eye/eyebrow/nose/noseCrest/lip/contour points align at center and each cropped preview edge.
- [ ] Front mirror: move an identifiable feature to each side and confirm exactly one reflection.
- [ ] Portrait plus physical landscape left/right and upside down on both cameras. UI remains portrait;
      this check exercises physical camera rotation, including horizon tilt and face-up/down transitions.
- [ ] Face enters/leaves, turns/profile/occlusion, rapid motion and optional/absent landmarks.
- [ ] Repeated lens switches and rotation during an active request do not display old-camera results.
- [ ] First permission prompt, denied/restricted access, Settings return, Home/lock and foreground return.
- [ ] Session interruption, stop/resume and media-services reset; no new Vision work while stopped.
- [ ] Shutter, front-photo mirror, back-photo orientation, flash and result dismissal still work.
- [ ] Profile Preview FPS, main-thread responsiveness, Vision durations, CPU, allocations/RSS,
      frame drops, switch latency and thermal state on a supported older iPhone and a current iPhone.
      Compare the previous commit with this commit under the same scene/light/camera for at least
      five minutes; repeat with multiple faces. Record device, OS, SHA, duration and measurements.
- [ ] With Instruments, confirm one Vision request at a time, cooldown between requests, no increasing
      frame/result queue, and memory reaches a plateau over repeated background/switch cycles.
- [ ] After this investigation, set `FaceGeometryDebugMode.isEnabled = false` and confirm the
      production App Store candidate has no diagnostic overlay or debug-only frame handoff.

**尚未完成 Apple 平台 / 真机验收。** Simulator and pure-logic tests cannot satisfy these checks.
The implementation and known validation limits are described in [FaceDetection.md](FaceDetection.md).

## TestFlight — Pending

TestFlight signing / device Archive / IPA Export / Upload have not been executed or validated. The workflow is infrastructure only, requires Environment `testflight`, Variable `APPLE_TEAM_ID`, the six secrets listed in README, an approved AppIcon and matching com.songlabs.PanPanCamera Apple configuration. Simulator Release builds and script tests do not validate distribution credentials or Apple acceptance. No TestFlight run is part of this repair.
