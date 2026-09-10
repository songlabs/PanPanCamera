# BeautyEngine — reserved for future effect families

The first production skin path now lives in `Rendering`: CameraService owns shared
`BeautyParameters`, Domain maps them to an immutable `BeautyConfiguration`, and the
same configuration semantics drive the latest-frame preview and native-source final
photo processors. Skin Auto is the overall strength. Smoothing, local brightening and
neutral tone consistency are implemented; processing is entirely on-device.

Future boundaries:

- `Skin/`: future higher-level policy beyond the current Rendering implementation.
- `FaceWarp/`: local face geometry adjustments; future landmarks are a separate input.
- `Makeup/`: local makeup composition.
- `Filters/`: local filter presets.

Face warp, blemish, dark-circle correction, makeup and filters are not implemented.
Do not add a fake pass-through engine, cloud client, speculative protocol tree or
third-party beauty SDK.
