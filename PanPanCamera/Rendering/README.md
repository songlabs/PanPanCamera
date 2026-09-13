# Rendering

Rendering owns Core Image/Metal contexts, normalization, tiny skin-sampling readback, filter primitives and vector displacement. BeautyEngine owns skin classification, protection and effect policy. FaceAnalysis owns Vision and the common DTO. No model adapters or semantic raster imports remain.

Contexts/Metal queues stay long-lived; frame and command submission stay bounded. No diagnostic persistence or network access. [Architecture and pending Apple/device validation](../../docs/FaceAnalysisArchitecture.md).
