# Core Image

CoreImageRendering shares contexts, finite-extent filter/blend helpers, a bounded 18x6 per-face sample readback and the Metal bridge. FaceImageNormalization resolves EXIF once. FaceCorrectionRenderStep caches bounded vector displacement maps. BeautyEngine builds one adaptive mask per frame and composes a lazy effect graph. Final photo materialization/encoding stays at the output boundary. See [architecture](../../../docs/FaceAnalysisArchitecture.md).
