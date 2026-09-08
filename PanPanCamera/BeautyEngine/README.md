# BeautyEngine — reserved, not implemented

Version 0.1 does not process pixels. `Domain/BeautyParameters.swift` stores independent UI draft values only. CameraService has no reference to those values, and selecting Auto does not run an automatic adjustment algorithm.

Future boundaries:

- `Skin/`: local skin processing consuming a value snapshot.
- `FaceWarp/`: local face geometry adjustments; future landmarks are a separate input.
- `Makeup/`: local makeup composition.
- `Filters/`: local filter presets.

Define an engine contract once the first real processing requirement is known. Do not add a fake pass-through engine, cloud client, speculative protocol tree, or an implicit Core Image demo to this version.
