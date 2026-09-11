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
    APP / 'FaceTracking/MockFaceLandmarkDetector.swift',
    APP / 'Rendering/CoreImage/MockSkinMaskProvider.swift',
    APP / 'Rendering/DebugPhotoProcessing.swift',
    APP / 'Rendering/CoreImage/DebugFaceBrightnessStep.swift',
    APP / 'Rendering/CoreImage/DebugFaceMaskStep.swift',
)
CORE = (
    APP / 'FaceTracking/FaceDetecting.swift',
    APP / 'FaceTracking/FaceRegion.swift',
    APP / 'FaceTracking/FacialLandmarks.swift',
    APP / 'FaceTracking/FaceLandmarkDetecting.swift',
    APP / 'Rendering/ImageProcessingPipeline.swift',
    APP / 'Rendering/CoreImage/SkinMaskProviding.swift',
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
struct MockFaceLandmarkDetector<Image: Sendable> {}
struct MockSkinMaskProvider {}
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
        symbols = r'\b(?:MockFaceDetector|MockFaceLandmarkDetector|MockSkinMaskProvider|DebugPhotoProcessing|DebugFaceBrightnessStep|DebugFaceMaskStep)\b'
        for path in APP.rglob('*.swift'):
            if 'Tests' in path.parts or path in DEVELOPMENT:
                continue
            self.assertIsNone(re.search(symbols, path.read_text(encoding='utf-8')), str(path))

    def test_pipeline_contract_has_no_vision_or_mock_dependency(self):
        for path in CORE:
            # Check code, not explanatory comments about the dependency boundary.
            code = '\n'.join(line.split('//')[0] for line in path.read_text(encoding='utf-8').splitlines())
            self.assertIsNone(re.search(r'\b(?:Vision|VisionFaceDetector|MockFaceDetector|MockFaceLandmarkDetector|MockSkinMaskProvider|VN\w+|DetectedFace)\b', code), str(path))

    def test_new_processing_sources_remain_local_and_without_model_or_camera_apis(self):
        for path in set((*CORE, *DEVELOPMENT, *(APP / 'Rendering').rglob('*.swift'))):
            code = '\n'.join(line.split('//')[0] for line in path.read_text(encoding='utf-8').splitlines())
            self.assertIsNone(re.search(r'\b(?:URLSession|URLRequest|Network|Vision|CoreML|AVCapture\w+|VN\w+)\b', code), str(path))

    def test_metal_is_only_the_core_image_preview_presentation_target(self):
        users = [path for path in APP.rglob('*.swift')
                 if 'Tests' not in path.parts
                 and re.search(r'^import Metal$', path.read_text(encoding='utf-8'), re.M)]
        self.assertEqual(set(users), {
            APP / 'Presentation/Camera/CameraPreview.swift',
            APP / 'Rendering/CoreImage/BeautyPreviewRenderer.swift',
            APP / 'Rendering/CoreImage/CoreImageRendering.swift',
        })
        self.assertFalse(list(APP.rglob('*.metal')), 'No custom shader pipeline is needed for Core Image presentation')

    def test_skin_processing_types_do_not_leak_outside_rendering(self):
        for path in APP.rglob('*.swift'):
            if 'Tests' in path.parts or 'Rendering' in path.parts:
                continue
            self.assertNotRegex(path.read_text(encoding='utf-8'),
                                r'\b(?:NaturalSkinProcessingStep|SoftFaceMaskGenerator|FaceMaskGenerating|'
                                r'TexturePreservingSkinSmoothingStep|DetailProtectionMaskGenerator|'
                                r'NaturalSkinToneAdjustmentStep|NaturalSkinRetouchSteps|SkinToneScale|'
                                r'FeatureProtectionMaskGenerator|ProtectionMaskCombiner|'
                                r'SkinMaskProviding|SkinMaskResult|EffectiveSkinMaskComposer|'
                                 r'SkinRetouchConfiguration|SkinRetouchIntensity)\b', str(path))

    def test_formal_capture_processes_both_native_source_paths_without_preview_screenshot_or_upscale(self):
        session = (APP / 'Camera/Session/CameraSession.swift').read_text(encoding='utf-8')
        final = (APP / 'Rendering/CoreImage/FinalBeautyProcessor.swift').read_text(encoding='utf-8')
        code = '\n'.join(line.split('//')[0] for line in (session + final).splitlines())
        final_code = '\n'.join(line.split('//')[0] for line in final.splitlines())
        self.assertIn('processPhotoData($0, configuration: beauty)', session)
        self.assertIn('processSilentFrame(frame, configuration: beauty)', session)
        self.assertNotRegex(code, r'\b(?:drawHierarchy|snapshotView|UIGraphicsImageRenderer|layer\.render)\b')
        self.assertNotRegex(final_code, r'\b(?:resized|resize|upscale|maximumDimension|maxPhotoDimensions)\b')

    def test_capture_snapshot_and_preview_backpressure_are_explicit(self):
        service = (APP / 'Camera/CameraService.swift').read_text(encoding='utf-8')
        frame_store = (APP / 'Rendering/BeautyPreviewFrameStore.swift').read_text(encoding='utf-8')
        renderer = (APP / 'Rendering/CoreImage/BeautyPreviewRenderer.swift').read_text(encoding='utf-8')
        self.assertIn('let beauty = beautyParameters.processingConfiguration', service)
        self.assertIn('captureSession.capture(flash: state.flash, beauty: beauty)', service)
        self.assertIn('private var latest: BeautyPreviewFrame?', frame_store)
        self.assertNotRegex(frame_store, r'\[(?:BeautyPreviewFrame|CVPixelBuffer)\]')
        self.assertIn('private var inFlight = false', renderer)
        self.assertNotRegex(renderer, r'queue\.asyncAfter|Task\s*[({.]')

    def test_beauty_zero_and_disabled_bypass_before_final_photo_decode(self):
        config = (APP / 'Domain/BeautyParameters.swift').read_text(encoding='utf-8')
        final = (APP / 'Rendering/CoreImage/FinalBeautyProcessor.swift').read_text(encoding='utf-8')
        self.assertIn('!enabled ||', config)
        self.assertIn('var isPhotoBypassed: Bool', config)
        bypass = final.index('guard !configuration.isPhotoBypassed else { return data }')
        decode = final.index('CGImageSourceCreateWithData')
        self.assertLess(bypass, decode)

    def test_face_correction_is_preview_only_bounded_and_local(self):
        geometry = (APP / 'Rendering/CoreImage/FaceCorrectionGeometry.swift').read_text(encoding='utf-8')
        geometry_code = '\n'.join(line.split('//')[0] for line in geometry.splitlines())
        preview = (APP / 'Rendering/CoreImage/BeautyImageProcessor.swift').read_text(encoding='utf-8')
        final = (APP / 'Rendering/CoreImage/FinalBeautyProcessor.swift').read_text(encoding='utf-8')
        self.assertIn('faceCorrection.makeOutput', preview)
        self.assertNotIn('FaceCorrectionPreviewStep', final)
        self.assertNotIn('"CIDisplacementDistortion"', geometry)
        self.assertIn('configuration.isFaceCorrectionBypassed', geometry)
        self.assertNotRegex(geometry_code, r'\b(?:UIImage|CIContext|DispatchQueue|Task|URLSession|Vision)\b')
        self.assertIn('private var cachedMap: CIImage?', geometry)
        self.assertNotRegex(geometry, r'\[(?:CIImage|CVPixelBuffer)\]')

    def test_pipeline_does_not_depend_on_a_mask_algorithm(self):
        code = (APP / 'Rendering/ImageProcessingPipeline.swift').read_text(encoding='utf-8')
        self.assertNotRegex(code, r'\b(?:FaceMaskGenerating|SoftFaceMaskGenerator|NaturalSkinProcessingStep|'
                                 r'SkinMaskProviding|SkinMaskResult|EffectiveSkinMaskComposer|MockSkinMaskProvider|'
                                 r'TexturePreservingSkinSmoothingStep|SkinRetouchConfiguration|CoreImage)\b')
        self.assertNotRegex(code, r'\b(?:NaturalSkinToneAdjustmentStep|NaturalSkinRetouchSteps)\b')

    def test_retouch_reuses_one_renderer_context_without_new_queues_or_tasks(self):
        sources = list((APP / 'Rendering').rglob('*.swift'))
        contexts = [path for path in sources if re.search(r'\bCIContext\s*\(', path.read_text(encoding='utf-8'))]
        self.assertEqual(contexts, [APP / 'Rendering/CoreImage/CoreImageRendering.swift'])
        for name in ('TexturePreservingSkinSmoothingStep', 'DetailProtectionMaskGenerator', 'SkinRetouchConfiguration',
                     'FeatureProtectionMaskGenerator', 'ProtectionMaskCombiner', 'SkinMaskProviding',
                     'MockSkinMaskProvider', 'EffectiveSkinMaskComposer',
                     'NaturalSkinToneAdjustmentStep', 'NaturalSkinRetouchSteps'):
            code = (APP / f'Rendering/CoreImage/{name}.swift').read_text(encoding='utf-8')
            self.assertNotRegex(code, r'\b(?:DispatchQueue|Task)\s*[({.]')

    def test_feature_protection_adds_no_legacy_kernel_or_photo_render(self):
        for name in ('FeatureProtectionMaskGenerator', 'ProtectionMaskCombiner'):
            code = (APP / f'Rendering/CoreImage/{name}.swift').read_text(encoding='utf-8')
            self.assertNotRegex(code, r'\b(?:CIColorKernel|CIKernel|CIContext)\s*\(')
            self.assertNotRegex(code, r'\bCoreImageRendering\.render\s*\(')
            self.assertNotRegex(code, r'\b(?:MockFaceDetector|MockFaceLandmarkDetector)\b')

    def test_debug_default_uses_composition_entry_without_legacy_tone(self):
        code = (APP / 'Rendering/DebugPhotoProcessing.swift').read_text(encoding='utf-8')
        self.assertNotRegex(code, r'\bNaturalSkinProcessingStep\s*\(')
        self.assertEqual(len(re.findall(r'ImageProcessingPipeline<JobImage>\s*\(', code)), 1)
        self.assertIn('NaturalSkinRetouchSteps.make(', code)

    def test_tone_adds_no_kernel_geometry_whitening_or_second_pipeline(self):
        for name in ('NaturalSkinToneAdjustmentStep', 'NaturalSkinRetouchSteps'):
            code = '\n'.join(line.split('//')[0] for line in
                             (APP / f'Rendering/CoreImage/{name}.swift').read_text(encoding='utf-8').splitlines())
            self.assertNotRegex(code, r'\b(?:CIColorKernel|CIKernel|CIContext|ImageProcessingPipeline)\s*[(<]')
            self.assertNotRegex(code, r'\b(?:Metal|MPS|CoreML|Accelerate)\b')
            self.assertNotRegex(code, r'CI(?:ColorControls|ExposureAdjust|HueAdjust|TemperatureAndTint|WhitePointAdjust|AreaHistogram)')
            self.assertNotRegex(code, r'\.transformed\s*\(|\.oriented\s*\(|\.autoAdjustmentFilters\s*\(')

    def test_semantic_masks_add_no_legacy_kernel_or_photo_render(self):
        for name in ('SkinMaskProviding', 'MockSkinMaskProvider', 'EffectiveSkinMaskComposer'):
            code = (APP / f'Rendering/CoreImage/{name}.swift').read_text(encoding='utf-8')
            self.assertNotRegex(code, r'\b(?:CIColorKernel|CIKernel|CIContext)\s*\(')
            self.assertNotRegex(code, r'\bCoreImageRendering\.render\s*\(')
        kernels = [path for path in (APP / 'Rendering').rglob('*.swift')
                   if re.search(r'\bCIColorKernel\s*\(source:', path.read_text(encoding='utf-8'))]
        self.assertCountEqual(kernels, [
            APP / 'Rendering/CoreImage/TexturePreservingSkinSmoothingStep.swift',
            APP / 'Rendering/CoreImage/LocalSkinCorrectionStep.swift',
            APP / 'Rendering/CoreImage/MakeupProcessingStep.swift',
        ])

    def test_local_skin_corrections_share_preview_and_final_pipeline_without_new_workers(self):
        local = (APP / 'Rendering/CoreImage/LocalSkinCorrectionStep.swift').read_text(encoding='utf-8')
        processor = (APP / 'Rendering/CoreImage/BeautyImageProcessor.swift').read_text(encoding='utf-8')
        final = (APP / 'Rendering/CoreImage/FinalBeautyProcessor.swift').read_text(encoding='utf-8')
        code = '\n'.join(line.split('//')[0] for line in local.splitlines())
        self.assertNotRegex(code, r'\b(?:CIContext|CGContext|DispatchQueue|Task|URLSession|UIImage)\s*[(.{]')
        self.assertIn('quality == .preview ? 640 : 1280', local)
        self.assertIn('condition: .notOnQueue(.main)', local)
        self.assertIn('var result = try processFaceEffects(image', processor)
        self.assertIn('let result = try processSkin(source', processor)
        self.assertEqual(final.count('try processor.process(input'), 2)
        self.assertEqual(final.count('quality: .final'), 2)
        self.assertIn('strength: configuration.effectiveBlemish', processor)
        self.assertIn('strength: configuration.effectiveDarkCircles', processor)
        self.assertLess(processor.index('NaturalSkinToneAdjustmentStep'), processor.index('BlemishAttenuationStep'))
        self.assertLess(processor.index('BlemishAttenuationStep'), processor.index('DarkCircleCorrectionStep'))

    def test_color_effects_use_shared_state_and_all_product_output_paths(self):
        view = (APP / 'Presentation/Camera/CameraView.swift').read_text(encoding='utf-8')
        state = (APP / 'Presentation/Camera/CameraToolState.swift').read_text(encoding='utf-8')
        processor = (APP / 'Rendering/CoreImage/BeautyImageProcessor.swift').read_text(encoding='utf-8')
        final = (APP / 'Rendering/CoreImage/FinalBeautyProcessor.swift').read_text(encoding='utf-8')
        frame = (APP / 'Camera/Capture/CameraFaceFrameProcessor.swift').read_text(encoding='utf-8')
        self.assertIn('MakeupPanel(parameters: $camera.beautyParameters)', view)
        self.assertIn('FilterPanel(parameters: $camera.beautyParameters)', view)
        self.assertNotRegex(state, r'var (?:makeupTool|filterPreset)')
        preview = processor.split('func process(_ source:')[0]
        self.assertLess(preview.index('try processFaceEffects(image'), preview.index('try faceCorrection.makeOutput'))
        self.assertLess(preview.index('try faceCorrection.makeOutput'), preview.index('try filter.makeOutput'))
        self.assertIn('configuration: configuration.makeup', processor)
        self.assertEqual(final.count('configuration.requiresFaceDetection'), 2)
        self.assertEqual(final.count('|| !configuration.filter.isBypassed'), 2)
        self.assertEqual(final.count('try processor.process(input'), 2)
        self.assertIn('makeupFaces: makeupFaces', frame)
        for name in ('MakeupProcessingStep', 'FilterProcessingStep'):
            code = (APP / f'Rendering/CoreImage/{name}.swift').read_text(encoding='utf-8')
            self.assertNotRegex(code, r'\b(?:CIContext|DispatchQueue|Task|VisionFaceDetector)\s*\(')
            self.assertIn('condition: .notOnQueue(.main)', code)
        for name in ('Makeup/MakeupPanel', 'Filter/FilterPanel'):
            code = (APP / f'Presentation/{name}.swift').read_text(encoding='utf-8')
            self.assertIn('compact: true', code)
            self.assertNotIn('UnimplementedNotice', code)

    def test_mock_semantics_do_not_read_pixels_or_classify_skin_color(self):
        code = '\n'.join(line.split('//')[0] for line in
                         (APP / 'Rendering/CoreImage/MockSkinMaskProvider.swift').read_text(encoding='utf-8').splitlines())
        self.assertNotRegex(code, r'\b(?:dataProvider|CFDataGetBytePtr|createCGImage|render|CGContext|HSV|YCbCr)\b')
        self.assertNotRegex(code, r'CIImage\s*\(cgImage:|\.features\b|\.imagePoints\b')
        self.assertNotRegex(code, r'CI(?:ColorCube|ColorThreshold|AreaAverage|AreaHistogram|ColorKernel)')


if __name__ == '__main__':
    unittest.main()
