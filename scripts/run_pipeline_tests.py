"""Run the actual Foundation pipeline XCTest sources with an installed host Swift SDK.

No Apple code is substituted. Core Image/Camera tests remain in the Xcode target.
Requires a complete host Swift toolchain (including the C/Windows SDK on Windows).
All generated files stay in an ignored .verification subdirectory.
"""
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    'FaceTracking/FaceDetecting.swift',
    'FaceTracking/FaceRegion.swift',
    'FaceTracking/MockFaceDetector.swift',
    'Rendering/ImageProcessingPipeline.swift',
    'Rendering/CoreImage/SkinRetouchConfiguration.swift',
)


def main():
    package = ROOT / '.verification/pipeline-tests'
    source_dir = package / 'Sources/PanPanCamera'
    test_dir = package / 'Tests/PanPanCameraTests'
    source_dir.mkdir(parents=True, exist_ok=True)
    test_dir.mkdir(parents=True, exist_ok=True)
    for source in SOURCES:
        shutil.copyfile(ROOT / 'PanPanCamera' / source, source_dir / Path(source).name)
    shutil.copyfile(ROOT / 'PanPanCamera/Tests/ImageProcessingPipelineTests.swift',
                    test_dir / 'ImageProcessingPipelineTests.swift')
    shutil.copyfile(ROOT / 'PanPanCamera/Tests/SkinRetouchConfigurationTests.swift',
                    test_dir / 'SkinRetouchConfigurationTests.swift')
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
        print('PASS host Foundation pipeline/configuration XCTest. Core Image, Vision and Apple/device acceptance were NOT run.')
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
