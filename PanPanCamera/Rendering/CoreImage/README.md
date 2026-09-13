# Core Image infrastructure

CoreImageRendering shares contexts, finite-extent filter/blend helpers and the Metal presentation bridge. FaceImageNormalization resolves EXIF once; FaceSemanticRaster imports scalar data with explicit row order, no color transfer, and the shared analysis-to-render transform. FaceCorrectionRenderStep creates/caches a bounded vector displacement map and samples original pixels.

Effect policy and retained texture/tone/local-repair implementations are in BeautyEngine. There is no geometric fallback Skin Mask or parallel DEBUG processing pipeline. See [FaceAnalysisArchitecture](../../../docs/FaceAnalysisArchitecture.md) for source contracts, licenses, masks, tests and limitations. Apple build, Core Image pixel tests, Core ML and device acceptance are pending.
