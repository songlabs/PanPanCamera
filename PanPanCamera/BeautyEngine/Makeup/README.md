# Makeup

MakeupProcessingStep consumes typed, normalized dense landmark regions and the shared BeautyConfiguration. Lip/blush/eye/brow compose after Skin and before Shape for both Preview and Final. Its cache retains only geometry. No landmarks means bypass. See [architecture and model blocker](../../../docs/FaceAnalysisArchitecture.md).
