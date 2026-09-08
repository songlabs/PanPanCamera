# Development Core Image probe

`ProcessingImage` is an immutable, display-oriented CGImage. The DEBUG-only
`DebugFaceBrightnessStep` applies `CIColorControls` with brightness +0.01, unions white
rectangles into a black regional mask, blends with the source using `CIBlendWithMask`,
and eagerly renders a CGImage on the pipeline worker queue. Face rectangles are rounded
inward to whole pixels and clipped to the image extent; subpixel-only regions are no-ops.
Overlapping faces are adjusted once. The original image is not overwritten, so removing
the step or retaining the input reverses the development effect without an inverse filter.

The CIContext is initialized on first worker use and reused with intermediate caching
disabled. Filters and CIImage graphs are job-local. There is no skin smoothing, whitening
algorithm, reshape, landmarks, AI, model or product beauty control. No Mock or probe type
exists in Release. See the parent README for wiring, tests and platform evidence limits.
