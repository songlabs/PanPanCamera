"""Executable static/compile gates; these are NOT image processing runtime tests."""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from check_project import OpenStepParser
APP = ROOT / 'PanPanCamera'
DEVELOPMENT = (
    APP / 'FaceTracking/MockFaceDetector.swift',
    APP / 'Rendering/DebugPhotoProcessing.swift',
    APP / 'Rendering/CoreImage/DebugFaceBrightnessStep.swift',
    APP / 'Rendering/CoreImage/DebugFaceMaskStep.swift',
)
CORE = (
    APP / 'FaceTracking/FaceDetecting.swift',
    APP / 'FaceTracking/FaceRegion.swift',
    APP / 'Rendering/ImageProcessingPipeline.swift',
)


class ImageProcessingScopeTests(unittest.TestCase):
    def test_release_compiler_excludes_all_development_implementations(self):
        """Redeclarations would fail if a development type survived compilation."""
        swiftc = shutil.which('swiftc')
        if not swiftc:
            self.skipTest('Swift compiler unavailable; this isolation gate was not executed')
        with tempfile.TemporaryDirectory(prefix='panpan-release-') as directory:
            probe = Path(directory) / 'ReleaseIsolation.swift'
            probe.write_text('''struct MockFaceDetector<Image: Sendable> {}
struct DebugPhotoProcessing {}
struct DebugFaceBrightnessStep {}
struct DebugFaceMaskStep {}
''', encoding='utf-8')
            result = subprocess.run([swiftc, '-typecheck', '-swift-version', '5',
                                     *map(str, DEVELOPMENT), str(probe)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_release_project_configurations_do_not_define_debug(self):
        project = OpenStepParser((ROOT / 'PanPanCamera.xcodeproj/project.pbxproj').read_text(encoding='utf-8')).value()
        release = [item for item in project['objects'].values()
                   if item['isa'] == 'XCBuildConfiguration' and item['name'] == 'Release']
        self.assertEqual(len(release), 3, 'Project, app and test Release configurations must be checked')
        for item in release:
            settings = item['buildSettings']
            for key in ('SWIFT_ACTIVE_COMPILATION_CONDITIONS', 'OTHER_SWIFT_FLAGS'):
                self.assertNotRegex(str(settings.get(key, '')), r'\bDEBUG\b')

    def test_mock_and_probe_have_no_product_call_sites(self):
        symbols = r'\b(?:MockFaceDetector|DebugPhotoProcessing|DebugFaceBrightnessStep|DebugFaceMaskStep)\b'
        for path in APP.rglob('*.swift'):
            if 'Tests' in path.parts or path in DEVELOPMENT:
                continue
            self.assertIsNone(re.search(symbols, path.read_text(encoding='utf-8')), str(path))

    def test_pipeline_contract_has_no_vision_or_mock_dependency(self):
        for path in CORE:
            # Check code, not explanatory comments about the dependency boundary.
            code = '\n'.join(line.split('//')[0] for line in path.read_text(encoding='utf-8').splitlines())
            self.assertIsNone(re.search(r'\b(?:Vision|VisionFaceDetector|MockFaceDetector|VN\w+|DetectedFace)\b', code), str(path))

    def test_new_processing_sources_remain_local_and_without_model_or_camera_apis(self):
        for path in set((*CORE, *DEVELOPMENT, *(APP / 'Rendering').rglob('*.swift'))):
            code = '\n'.join(line.split('//')[0] for line in path.read_text(encoding='utf-8').splitlines())
            self.assertIsNone(re.search(r'\b(?:URLSession|URLRequest|Network|Vision|CoreML|Metal|AVCapture\w+|VN\w+)\b', code), str(path))

    def test_experimental_skin_step_has_no_camera_or_product_call_sites(self):
        for path in APP.rglob('*.swift'):
            if 'Tests' in path.parts or 'Rendering' in path.parts:
                continue
            self.assertNotRegex(path.read_text(encoding='utf-8'),
                                r'\b(?:NaturalSkinProcessingStep|SoftFaceMaskGenerator|FaceMaskGenerating|'
                                r'TexturePreservingSkinSmoothingStep|DetailProtectionMaskGenerator|'
                                r'SkinRetouchConfiguration|SkinRetouchIntensity)\b', str(path))

    def test_pipeline_does_not_depend_on_a_mask_algorithm(self):
        code = (APP / 'Rendering/ImageProcessingPipeline.swift').read_text(encoding='utf-8')
        self.assertNotRegex(code, r'\b(?:FaceMaskGenerating|SoftFaceMaskGenerator|NaturalSkinProcessingStep|'
                                 r'TexturePreservingSkinSmoothingStep|SkinRetouchConfiguration|CoreImage)\b')

    def test_retouch_reuses_one_renderer_context_without_new_queues_or_tasks(self):
        sources = list((APP / 'Rendering').rglob('*.swift'))
        contexts = [path for path in sources if re.search(r'\bCIContext\s*\(', path.read_text(encoding='utf-8'))]
        self.assertEqual(contexts, [APP / 'Rendering/CoreImage/CoreImageRendering.swift'])
        for name in ('TexturePreservingSkinSmoothingStep', 'DetailProtectionMaskGenerator', 'SkinRetouchConfiguration'):
            code = (APP / f'Rendering/CoreImage/{name}.swift').read_text(encoding='utf-8')
            self.assertNotRegex(code, r'\b(?:DispatchQueue|Task)\s*[({.]')

    def test_debug_default_does_not_stack_tone_and_texture(self):
        code = (APP / 'Rendering/DebugPhotoProcessing.swift').read_text(encoding='utf-8')
        self.assertNotRegex(code, r'\bNaturalSkinProcessingStep\s*\(')
        self.assertEqual(len(re.findall(r'ImageProcessingPipeline<JobImage>\s*\(', code)), 1)


if __name__ == '__main__':
    unittest.main()
