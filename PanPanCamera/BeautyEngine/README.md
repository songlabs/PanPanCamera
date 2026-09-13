# BeautyEngine

One product pipeline consumes FaceAnalysisResult: Skin -> Makeup -> Face Shape -> Filter.
BeautyPreviewProcessor owns preview fitting; FinalBeautyProcessor shares one fresh-analysis path for PhotoOutput and Silent Frame. Parameters retain existing semantics. Skin uses only semantic parsing; Makeup/Shape use typed dense landmarks. No model is bundled: face effects bypass until licensed model integration.

See [FaceAnalysisArchitecture](../../docs/FaceAnalysisArchitecture.md) for licensing, contracts, fallback and Apple/device validation limits.
