"""Static architecture gates, not Apple/ML/image runtime validation."""
from pathlib import Path
import re
import sys
import unittest
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from check_project import OpenStepParser
APP = ROOT / 'PanPanCamera'

def source(path):
    return (APP / path).read_text(encoding='utf-8')

def code(path):
    return '\n'.join(line.split('//')[0] for line in source(path).splitlines())

class ImageProcessingScopeTests(unittest.TestCase):
    def test_production_has_no_retired_analysis_or_network_pipeline(self):
        retired = r'\b(?:Vision|VNFace\w*|VNDetect\w*|visionFailed|VisionFaceDetector|DetectedFace|SoftFaceMaskGenerator|BeautySkinMaskGenerator|MockFaceDetector|DebugPhotoProcessing)\b'
        for path in APP.rglob('*.swift'):
            if 'Tests' in path.parts:
                continue
            text = path.read_text(encoding='utf-8')
            self.assertNotRegex(text, retired, str(path))
            self.assertNotRegex(text, r'\b(?:URLSession|URLRequest|NWConnection|WKWebView|AVCaptureMovieFileOutput)\b', str(path))

    def test_contract_is_framework_independent_and_identity_bound(self):
        paths = ['FaceAnalysis/FaceAnalysisResult.swift', 'FaceAnalysis/FaceAnalysisCoordinates.swift',
                 'FaceAnalysis/Parsing/FaceSemanticMask.swift', 'FaceAnalysis/Tracking/FaceAnalysisSmoother.swift']
        for path in paths:
            self.assertNotRegex(code(path), r'\b(?:CoreML|CoreImage|AVFoundation|CoreVideo|MLModel|CIImage|CVPixelBuffer)\b')
        contract = source(paths[0])
        self.assertIn('let trackingID: UUID', contract)
        self.assertIn('let semanticMasks: FaceSemanticMasks?', contract)
        self.assertIn('let landmarks: DenseFaceLandmarks', contract)

    def test_models_are_explicitly_blocked_without_unapproved_binary(self):
        for suffix in ('*.mlmodel', '*.mlpackage', '*.mlmodelc', '*.tflite', '*.onnx'):
            self.assertFalse(list(APP.rglob(suffix)), suffix)
        self.assertIn('static let bundled: Self? = nil', source('FaceAnalysis/CoreMLFaceAnalyzer.swift'))
        for path in (APP / 'BeautyEngine').rglob('*.swift'):
            self.assertNotRegex(path.read_text(encoding='utf-8'), r'^import CoreML$', str(path))

    def test_skin_never_uses_geometry_as_coverage_or_missing_semantic_fallback(self):
        text = code('BeautyEngine/Skin/SemanticSkinMaskComposer.swift')
        self.assertIn('masks.skinFoundation()', text)
        self.assertNotRegex(text, r'faceContour|jawline|1\.15|makeMask\(regions:|semantic\s*\?\?\s*white')
        skin = source('BeautyEngine/Skin/SkinBeautyProcessor.swift')
        self.assertEqual(skin.count('SemanticSkinMaskComposer().makeMask'), 1)
        self.assertNotIn('BeautySkinMaskGenerator', skin)
        self.assertIn('strength: configuration.effectiveBlemish', skin)
        self.assertIn('strength: configuration.effectiveDarkCircles', skin)

    def test_product_order_and_final_source_unification(self):
        beauty = source('BeautyEngine/BeautyProcessor.swift')
        order = ['"skin_graph"', '"makeup_graph"', '"face_graph"', '"filter_graph"']
        self.assertEqual([beauty.index(item) for item in order], sorted(beauty.index(item) for item in order))
        final = source('BeautyEngine/FinalBeautyProcessor.swift')
        self.assertEqual(final.count('try processSource('), 2)
        self.assertEqual(final.count('engine.analyze('), 1)
        self.assertEqual(final.count('try processor.process('), 1)
        self.assertNotRegex(code('BeautyEngine/FinalBeautyProcessor.swift'), r'BeautyPreviewFrame|\.transformed\s*\(|resized|resize|upscale')
        self.assertLess(final.index('guard !configuration.isPhotoBypassed'), final.index('CGImageSourceCreateWithData'))

    def test_capture_still_uses_native_sources_and_bounded_save_queue(self):
        worker = source('Camera/Capture/PhotoProcessingQueue.swift')
        session = source('Camera/Session/CameraSession.swift')
        self.assertIn('processPhotoData(input, configuration: job.configuration', worker)
        self.assertIn('processSilentFrame(frame, configuration: job.configuration', worker)
        self.assertIn('submitPhoto(.photoData(data)', session)
        self.assertIn('submitPhoto(.silentFrame(frame)', session)
        self.assertNotRegex(session + worker, r'\b(?:drawHierarchy|snapshotView|UIGraphicsImageRenderer|layer\.render)\b')
        native = session.split('let processor = PhotoCaptureProcessor(diagnostics:')[1].split('captures.register')[0]
        self.assertLess(native.index('captures.finish(id:'), native.index('submitPhoto(.photoData(data)'))

    def test_preview_is_latest_only_and_analysis_does_not_block_camera(self):
        frame = source('Camera/Capture/CameraFaceFrameProcessor.swift')
        self.assertIn('scheduler.submit(', frame)
        self.assertNotRegex(frame, r'engine\.analyze|\.prediction\(|queue\.sync|semaphore\.wait')
        scheduler = source('FaceAnalysis/Tracking/FaceAnalysisScheduler.swift')
        self.assertIn('!busy', scheduler)
        self.assertIn('1.0 / 12.0', scheduler)
        self.assertNotRegex(scheduler, r'\[(?:CVPixelBuffer|CMSampleBuffer|CIImage)\]')
        store = source('Rendering/BeautyPreviewFrameStore.swift')
        self.assertIn('private var latest: BeautyPreviewFrame?', store)
        self.assertNotRegex(store, r'\[(?:BeautyPreviewFrame|CVPixelBuffer)\]')
        self.assertIn('private var inFlight = false', source('Rendering/CoreImage/BeautyPreviewRenderer.swift'))

    def test_debug_modes_are_off_in_release_and_have_no_persistence(self):
        mode = source('BeautyEngine/BeautyFrame.swift')
        self.assertRegex(mode, r'#if DEBUG[\s\S]*arguments.contains\(flag\)[\s\S]*#else\s+false')
        for flag in ('FaceBoxes', 'DenseLandmarks', 'SkinMask', 'HairMask', 'FaceParsing'):
            self.assertIn('-PanPan' + flag, mode)
        for path in ['Presentation/Camera/FaceDebugOverlay.swift', 'BeautyEngine/BeautyPreviewProcessor.swift']:
            self.assertNotRegex(code(path), r'\.write\(|FileManager|URLSession|print\(')

    def test_release_project_configurations_do_not_define_debug(self):
        project = OpenStepParser((ROOT / 'PanPanCamera.xcodeproj/project.pbxproj').read_text(encoding='utf-8')).value()
        release = [item for item in project['objects'].values() if item['isa'] == 'XCBuildConfiguration' and item['name'] == 'Release']
        self.assertEqual(len(release), 3)
        for item in release:
            for key in ('SWIFT_ACTIVE_COMPILATION_CONDITIONS', 'OTHER_SWIFT_FLAGS'):
                self.assertNotRegex(str(item['buildSettings'].get(key, '')), r'\bDEBUG\b')

    def test_contexts_models_and_camera_session_are_long_lived(self):
        beauty = '\n'.join(p.read_text(encoding='utf-8') for p in (APP / 'BeautyEngine').rglob('*.swift'))
        self.assertNotRegex(beauty, r'\b(?:CIContext|MLModel|MTLCreateSystemDefaultDevice|DispatchQueue)\s*\(')
        adapter = source('FaceAnalysis/CoreMLFaceAnalyzer.swift')
        self.assertIn('private lazy var model:', adapter)
        self.assertIn('private lazy var context = CIContext', adapter)
        all_source = '\n'.join(p.read_text(encoding='utf-8') for p in APP.rglob('*.swift') if 'Tests' not in p.parts)
        self.assertEqual(all_source.count('AVCaptureSession()'), 1)

    def test_only_adapter_owns_raw_landmark_topology(self):
        for path in (APP / 'BeautyEngine').rglob('*.swift'):
            self.assertNotRegex(path.read_text(encoding='utf-8'), r'landmarks\.points\s*\[\s*\d+', str(path))
        geometry = code('BeautyEngine/FaceShape/FaceCorrectionGeometry.swift')
        self.assertNotRegex(geometry, r'CIContext|CIKernel|URLSession|MLModel')
        self.assertIn('faces.filter', geometry)

if __name__ == '__main__':
    unittest.main()
