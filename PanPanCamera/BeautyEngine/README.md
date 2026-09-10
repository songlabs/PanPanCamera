# BeautyEngine — reserved for future effect families

The first production skin path now lives in `Rendering`: CameraService owns shared
`BeautyParameters`, Domain maps them to an immutable `BeautyConfiguration`, and the
same configuration semantics drive the latest-frame preview and native-source final
photo processors. Skin Auto batch-sets every skin parameter, then multiplies each
concrete strength for processing. Smoothing, local brightening and
neutral tone consistency are implemented; processing is entirely on-device.

Current and future boundaries:

- `Skin/`: future higher-level policy beyond the current Rendering implementation.
- `FaceWarp/`: five conservative landmark-driven adjustments are implemented for Preview;
  final-photo geometry and the remaining face controls are future work.
- `Makeup/`: local makeup composition.
- `Filters/`: local filter presets.

Final-photo face warp, eye/nose/mouth warp, blemish, dark-circle correction, makeup and
filters are not implemented.
Do not add a fake pass-through engine, cloud client, speculative protocol tree or
third-party beauty SDK.
