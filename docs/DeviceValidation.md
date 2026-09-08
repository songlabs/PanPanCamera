# Apple build and device acceptance — pending

No steps on this page have been executed for the initial Windows-authored scaffold. Record device/OS, Xcode version, commit SHA, observed results, and actual logs when running them. Source inspection is not hardware evidence.

## Xcode / Simulator

1. Open `PanPanCamera.xcodeproj` in Xcode 15 or later with an iOS 17+ SDK. Select the shared PanPanCamera scheme and an installed iPhone Simulator.
2. Build and run the PanPanCameraTests target (12 test methods). Check compiled catalog resolution in all five locales. Preserve the `.xcresult` outside tracked files.
3. Launch in `ja`, `zh-Hans`, `zh-Hant`, `en`, and `ko` using scheme language options. Confirm no raw localization keys or untranslated permission text. Confirm the brand remains PanPan.
4. Check a small iPhone and a large iPhone, default and accessibility text sizes, VoiceOver labels/selection/slider values, safe areas, panel scrolling, and long Korean/English text. Do not count a source-only layout review as visual validation.
5. Simulator may exercise the unavailable/permission UI and editing panels; it does not prove live camera preview, flash, photo capture, or camera switching.

## Real iPhone

| Scenario | Expected result | Status |
| --- | --- | --- |
| Fresh install, permission granted | One camera prompt, live AVFoundation preview, no microphone/Photos prompt | Pending |
| Permission denied | Localized explanation and Settings link; shutter disabled | Pending |
| Camera restricted by device controls | Restriction explanation; no misleading permission-grant button | Pending |
| Revoke/restore permission in Settings | Foreground return reflects current authorization | Pending |
| Front/rear switching, repeated fast taps | One active input; preview changes; shutter/switch guarded while switching | Pending |
| Supported rear flash modes | Off/Auto/On update real AVCapturePhotoSettings; no torch stand-in | Pending |
| Front camera without hardware flash | Flash disabled; selection resets to Off | Pending |
| Flash temporarily unavailable | UI availability follows device; capture rechecks capability | Pending |
| Shutter, repeated fast taps | One capture, original photo Data, result preview; no duplicate capture | Pending |
| Portrait / landscape left / landscape right / upside down | UI remains portrait; captured content upright relative to physical orientation | Pending |
| Front photo containing text / asymmetrical object | Preview and photo have matching mirror policy | Pending |
| Rear photo and aspect-fill preview | Rear unmirrored; complete native photo may include edges cropped by preview | Pending |
| Result dismissal | Photo discarded, same camera session resumes | Pending |
| Home / lock / permission prompt / foreground loops | No stuck black preview, no duplicate session or permission request | Pending |
| Capture while app becomes inactive | Capture finishes or localized failure; shutter can recover after return | Pending |
| Camera interruption / media-services reset where reproducible | Explanation/recovery follows active state; capture busy state clears on runtime error | Pending |
| All 6 skin and 13 face controls | Independent 0–100 values; retained after panel/category switching | Pending |
| Beauty / filter / makeup selections | Notices visible; preview and captured pixels have no app beauty/filter effects | Pending |
| Video / portrait / album / timer / ratio | Explicit unavailable state or explanation; no simulated recording, crop or delay | Pending |
| Privacy | No upload/network client/library save; only current in-memory capture retained | Pending |

Use actual hardware capability results. Some interruption, flash-temperature, or media-reset scenarios may remain unexercised; label them individually.
