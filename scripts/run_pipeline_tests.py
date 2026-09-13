"""Run the Foundation FaceAnalysis contract XCTest with an installed host Swift SDK.

No Apple code is substituted. Core Image/Camera tests remain in the Xcode target.
Requires a complete host Swift toolchain (including the C/Windows SDK on Windows).
All generated files stay in an ignored .verification subdirectory.
"""
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    'FaceAnalysis/FaceCoordinates.swift',
    'FaceAnalysis/FaceAnalysisCoordinates.swift',
    'FaceAnalysis/FaceAnalysisResult.swift',
    'FaceAnalysis/FaceAnalysisDelivery.swift',
    'BeautyEngine/Skin/AdaptiveSkinColor.swift',
    'FaceAnalysis/Tracking/FaceAnalysisSmoother.swift',
    'BeautyEngine/Skin/FaceRegion.swift',
    'BeautyEngine/Skin/SkinRetouchConfiguration.swift',
)


def main():
    package = ROOT / '.verification/vision-skin-tests'
    source_dir = package / 'Sources/PanPanCamera'
    test_dir = package / 'Tests/PanPanCameraTests'
    source_dir.mkdir(parents=True, exist_ok=True)
    test_dir.mkdir(parents=True, exist_ok=True)
    for source in SOURCES:
        shutil.copyfile(ROOT / 'PanPanCamera' / source, source_dir / Path(source).name)
    for name in ('FaceAnalysisContractTests.swift', 'SkinRetouchConfigurationTests.swift', 'AdaptiveSkinColorTests.swift'):
        shutil.copyfile(ROOT / 'PanPanCamera/Tests' / name, test_dir / name)
    (package / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "PanPanPipelineHostTests",
    targets: [
        .target(name: "PanPanCamera"),
        .testTarget(name: "PanPanCameraTests", dependencies: ["PanPanCamera"])
    ]
)
''', encoding='utf-8')
    result = subprocess.run(['swift', 'test', '--package-path', str(package), '--configuration', 'debug'])
    if result.returncode == 0:
        print('PASS host Foundation analysis-contract/configuration XCTest. Core Image, Vision and Apple/device acceptance were NOT run.')
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
