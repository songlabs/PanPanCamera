# BeautyEngine

One product pipeline consumes FaceAnalysisResult: Skin -> Makeup -> simple Shape -> Filter.
BeautyPreviewProcessor fits Preview; FinalBeautyProcessor shares fresh native-image analysis for PhotoOutput and Silent Frame. Adaptive Skin uses the original source once per frame; Makeup/Shape consume semantic Vision landmarks. No custom models or third-party SDKs.

See [FaceAnalysisArchitecture](../../docs/FaceAnalysisArchitecture.md) for contracts, sampling, fail-closed behavior, supported controls and pending Apple/device acceptance.
