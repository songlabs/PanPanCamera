# Skin

SkinFaceROI defines candidate search bounds including forehead, never coverage. AdaptiveSkinColor samples personal YCbCr chroma; AdaptiveSkinMaskGenerator classifies on GPU at a tunable working resolution, subtracts feathered FeatureProtectionMaskGenerator and DetailProtectionMaskGenerator coverage, and scales the result back. SkinBeautyProcessor shares that one original-source result across smoothing, brightening, tone, blemish and dark-circle effects. Missing features or unreliable color samples bypass skin; the filter remains available.

See [architecture](../../../docs/FaceAnalysisArchitecture.md) for color-space handling, performance limits and pending forehead/hair/device acceptance.
