# Face Shape

[FaceShape/FaceCorrectionGeometry.swift](../FaceShape/FaceCorrectionGeometry.swift) consumes Vision semantic regions. Slim/width/chin reuse contour geometry; gentle eyes uses eye contours and a bounded Core Image bump effect. Preview smoothing stays in FaceAnalysisSmoother; Final uses fresh analysis. Forehead/cheekbone shaping bypasses, and eye spacing/height, nose and mouth shaping remain parameter-only. See [architecture](../../../docs/FaceAnalysisArchitecture.md).
