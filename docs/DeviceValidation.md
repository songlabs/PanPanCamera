# Simulator evidence and real-device acceptance

GitHub Simulator execution and real iPhone acceptance are separate. Record the actual commit SHA, run ID/link, Xcode, device/OS, results and artifacts. Obtain current-SHA evidence using the Last verified baseline section in [README](../README.md); this document does not embed its own SHA or predict successful runs.

## GitHub Simulator — actual run evidence

The [iOS CI](https://github.com/songlabs/PanPanCamera/actions/workflows/ci.yml?query=branch%3Amain) and [Simulator Screenshot](https://github.com/songlabs/PanPanCamera/actions/workflows/simulator-screenshot.yml?query=branch%3Amain) pages hold execution records. Check `head_sha` against the checkout and require both workflows to finish successfully. An older successful run does not complete acceptance for a new SHA.

| Verification | Current suite / required evidence |
| --- | --- |
| Debug XCTest | 33 methods: BeautyParameters 5, CameraState 6, Localization 1, ScreenshotConfiguration 5, CameraService 7, CameraSessionControl 5, PhotoCaptureLifecycle 4. Read actual passed/failed/skipped totals from PanPanCameraTests.xcresult summary. |
| Release Screenshot isolation XCTest | 5 methods; read ReleaseScreenshotTests.xcresult summary, not the Debug result. |
| Release Simulator Build | Require the dedicated xcodebuild build step to succeed. This is not a device Archive. |
| Delivery scripts | 27 Python tests, including strict three-part versions and dynamically generated PNG corruption cases. |
| Screenshot output | Exactly 10 PNGs: five-language camera screens plus ja beauty/reshape/filter/makeup/settings. Read actual device/iOS and native resolution from that run. |
| PNG validation | Require IDAT, valid complete zlib data, IHDR-consistent scanlines, filters, CRC, file coverage and native resolution; also require macOS sips reads. |
| Artifact review | Download panpan-simulator-screenshots; open all images and check target screens, languages, black frames, permission dialogs and visible text overflow. Record that inspection separately from workflow success. |

Only rows with actual matching-SHA run/step evidence are completed. Diagnostics retain test result bundles, exported summaries, Xcode/Simulator logs and screenshot inventory for 7 days. The workflow implementation, source test count and a green historical badge alone are not execution evidence for the current checkout.

## Test coverage is not hardware acceptance

Permission tests deterministically suspend authorization across inactivity and reread permission after Settings. Input replacement tests execute the production transaction helper for success, rollback and failed rollback. Photo tests use the production processor transitions and registry, including weak-reference cleanup and stale IDs after reset. Recovery tests exercise the production wantsRunning policy and inactive handling of delayed running events. These tests do not create camera hardware or prove AVFoundation notification timing.

## Additional Xcode / Simulator checks

1. Open PanPanCamera.xcodeproj and the shared scheme. The deployment target is iOS 17; CI pins Xcode 26.3 and selects an available iOS 26.x iPhone. Running on iOS 17 and building with the minimum documented Xcode toolchain remain separate, unexecuted checks.
2. Run the current 33-method Debug suite and 5 Release isolation methods, preserving the .xcresult outside tracked files.
3. Check ja, zh-Hans, zh-Hant, en and ko compiled resources; confirm PanPan is untranslated. System permission dialogs and every panel in every language still need visual acceptance.
4. Check small and large iPhones, default/accessibility text sizes, VoiceOver, safe areas, scrolling and long English/Korean text. Screenshot Mode uses large sheets; separately inspect ordinary medium sheets.
5. Simulator Screenshot uses a Debug-only SwiftUI testing background and bypasses CameraSession creation and permission requests. It cannot validate real preview, flash, captures or switching. Release/TestFlight ignore screenshot arguments.

## Real Device Validation Pending

Every checklist item below is currently **Pending**. Use a real iPhone and record model, OS, commit and observation for each executed item.

### Camera Permission

- [ ] Pending — first launch and grant: one camera prompt, live preview, no microphone/Photos prompt.
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

- [ ] Pending — rear capture returns original Data and an in-memory result preview.
- [ ] Pending — front capture uses the same mirror policy as front preview.
- [ ] Pending — portrait, landscape left, landscape right and upside down: check original metadata and displayed orientation independently.
- [ ] Pending — mirrored text/asymmetrical-object test on front and rear; rear stays unmirrored.
- [ ] Pending — full photo keeps native sensor edges that the aspect-fill preview crops.
- [ ] Pending — repeated shutter taps produce one active capture.
- [ ] Pending — dismissing the result discards the photo and resumes the same camera session; no library write.

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

- [ ] Pending — six skin and thirteen face controls retain independent 0–100 draft values across panel changes.
- [ ] Pending — beauty/filter/makeup notices remain visible; current selections do not alter pixels.
- [ ] Pending — video/portrait/album/timer/ratio remain explicitly unavailable; no simulated effects.
- [ ] Pending — no camera/photo upload or Photos-library save; only the current in-memory capture is retained.

## TestFlight — Pending

TestFlight signing / device Archive / IPA Export / Upload have not been executed or validated. The workflow is infrastructure only, requires Environment `testflight`, Variable `APPLE_TEAM_ID`, the six secrets listed in README, an approved AppIcon and matching com.songlabs.PanPanCamera Apple configuration. Simulator Release builds and script tests do not validate distribution credentials or Apple acceptance. No TestFlight run is part of this repair.
