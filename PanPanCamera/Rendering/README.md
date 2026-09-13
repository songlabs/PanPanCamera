# Rendering

Rendering owns Core Image/Metal infrastructure, pixel orientation normalization, scalar semantic raster import and vector displacement. Product Skin/Makeup/Shape/Filter policy and orchestration are in BeautyEngine. The only production pipeline is BeautyProcessor, fed by FaceAnalysisResult. Old mock photo pipelines, geometric skin generators and framework adapters were removed.

Contexts and Metal queues remain long-lived. Camera frames and command submission are bounded. No image/network persistence is added. [FaceAnalysisArchitecture](../../docs/FaceAnalysisArchitecture.md) documents the model asset blocker, exact coordinate contract and pending Apple/device validation.
