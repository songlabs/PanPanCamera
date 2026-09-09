"""Dependency-free static project/catalog checks. Does not build or execute iOS code."""
from pathlib import Path
import json
import plistlib
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
LOCALES = {'ja', 'zh-Hans', 'zh-Hant', 'en', 'ko'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


class OpenStepParser:
    """Parse dictionaries, arrays and strings used by a conventional pbxproj."""
    def __init__(self, source):
        lexer = re.compile(r'\s+|//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,"/]+', re.S)
        self.tokens = []
        position = 0
        while position < len(source):
            token = lexer.match(source, position)
            require(token is not None, f'Invalid project token at {position}')
            value = token.group()
            position = token.end()
            if not value.isspace() and not value.startswith(('//', '/*')):
                self.tokens.append(value)
        self.index = 0

    def take(self, expected=None):
        require(self.index < len(self.tokens), 'Unexpected end of project')
        value = self.tokens[self.index]
        self.index += 1
        require(expected is None or value == expected, f'Expected {expected}, got {value}')
        return value

    def value(self):
        token = self.take()
        if token == '{':
            result = {}
            while self.tokens[self.index] != '}':
                key = self.value()
                require(key not in result, f'Duplicate project key: {key}')
                self.take('=')
                result[key] = self.value()
                self.take(';')
            self.take('}')
            return result
        if token == '(':
            result = []
            while self.tokens[self.index] != ')':
                result.append(self.value())
                if self.tokens[self.index] != ')':
                    self.take(',')
            self.take(')')
            return result
        return json.loads(token) if token.startswith('"') else token


def check_catalogs():
    catalog_dir = ROOT / 'PanPanCamera/Resources/Localization'
    catalogs = {}
    for path in sorted(catalog_dir.glob('*.xcstrings')):
        catalog = json.loads(path.read_text(encoding='utf-8'))
        require(catalog['sourceLanguage'] == 'ja', f'{path.name}: source language must be ja')
        for key, item in catalog['strings'].items():
            require(set(item['localizations']) == LOCALES, f'{key}: incomplete language set')
            placeholders = []
            for locale, localization in item['localizations'].items():
                unit = localization['stringUnit']
                require(unit['state'] == 'translated' and unit['value'].strip(), f'{locale}/{key}: incomplete')
                placeholders.append(re.findall(r'%(?:\d+\$)?(?:@|lld|ld|d|f|s)', unit['value']))
            require(all(value == placeholders[0] for value in placeholders), f'{key}: placeholder mismatch')
        catalogs[path.stem] = catalog
        print(f'PASS {path.name}: {len(catalog["strings"])} keys x 5 languages')
    require(set(catalogs) == {'Localizable', 'InfoPlist'}, 'Missing required catalog')
    l10n = (ROOT / 'PanPanCamera/Presentation/Shared/L10n.swift').read_text(encoding='utf-8')
    enum_body = l10n.split('extension Text')[0]
    keys = re.findall(r'case\s+\w+\s*=\s*"([^"]+)"', enum_body)
    require(len(keys) == len(set(keys)), 'Duplicate L10n raw key')
    require(set(keys) == set(catalogs['Localizable']['strings']), 'L10n/catalog key mismatch')
    for locale in LOCALES:
        require(catalogs['Localizable']['strings']['app.name']['localizations'][locale]['stringUnit']['value'] == 'PanPan', 'Brand translated')
        require(catalogs['InfoPlist']['strings']['CFBundleDisplayName']['localizations'][locale]['stringUnit']['value'] == 'PanPan', 'Display name translated')
    info = plistlib.loads((ROOT / 'PanPanCamera/Resources/Info.plist').read_bytes())
    require(info['NSCameraUsageDescription'] == catalogs['InfoPlist']['strings']['NSCameraUsageDescription']['localizations']['ja']['stringUnit']['value'], 'Permission fallback differs from Japanese catalog')
    require(not any(key in info for key in ['NSMicrophoneUsageDescription', 'NSPhotoLibraryUsageDescription']), 'Unexpected permission scope')
    require('NSPhotoLibraryAddUsageDescription' in info, 'Missing add-only photo permission')
    require(info['CFBundleDisplayName'] == 'PanPan', 'Incorrect display name')
    print('PASS typed key coverage, placeholders, brand, and localized camera permission')


def check_sources():
    sources = [p for p in (ROOT / 'PanPanCamera').rglob('*.swift') if 'Tests' not in p.parts]
    hardcoded = re.compile(r'\b(?:Text|Button|Label|Toggle|Picker|Slider|ProgressView|Section)\s*\(\s*"|\.(?:navigationTitle|accessibilityLabel|accessibilityHint|accessibilityValue|alert)\s*\(\s*"')
    forbidden_import = re.compile(r'^(?:@preconcurrency )?import\s+(?:Metal|CoreML|PhotosUI)\b', re.M)
    allowed_imports = {'Foundation', 'SwiftUI', 'AVFoundation', 'Combine', 'UIKit', 'ImageIO', 'Vision', 'CoreImage', 'Photos'}
    for path in sources:
        text = path.read_text(encoding='utf-8')
        require(not hardcoded.search(text), f'UI literal outside localization adapter: {path.name}')
        require(not forbidden_import.search(text), f'Out-of-scope rendering/library import: {path.name}')
        imports = set(re.findall(r'^(?:@preconcurrency )?import (\w+)', text, re.M))
        require(imports <= allowed_imports, f'Unexpected dependency: {path.name}: {imports - allowed_imports}')
        module = path.relative_to(ROOT / 'PanPanCamera').parts[0]
        if module in {'Camera', 'FaceTracking'}:
            require('SwiftUI' not in imports and not re.search(r'\b(?:L10n|Presentation)\b', text),
                    f'Camera/FaceTracking must not depend on UI/localization types: {path.name}')
        require('Vision' not in imports or module == 'FaceTracking', f'Vision must stay in FaceTracking: {path.name}')
        require('CoreImage' not in imports or module == 'Rendering', f'Core Image must stay in Rendering: {path.name}')
        require('AVCaptureVideoDataOutput' not in text or module == 'Camera', f'Video acquisition must stay in Camera: {path.name}')
        require(not re.search(r'\b(?:URLSession|WKWebView|AVCaptureMovieFileOutput)\b', text), f'Unexpected network/recording path: {path.name}')
    domain = '\n'.join(p.read_text(encoding='utf-8') for p in (ROOT / 'PanPanCamera/Domain').glob('*.swift'))
    require(not re.search(r'^import ', domain, re.M), 'Domain must remain pure Swift without framework imports')
    session_creations = sum(p.read_text(encoding='utf-8').count('AVCaptureSession()') for p in sources)
    require(session_creations == 1, 'Expected one AVCaptureSession construction site')
    print(f'PASS {len(sources)} app source files: literal/import/scope scan and single session construction site')
    print('NOTE literal scan is a static guard, not a full Swift semantic or rendered UI audit.')


def check_project():
    parser = OpenStepParser((ROOT / 'PanPanCamera.xcodeproj/project.pbxproj').read_text(encoding='utf-8'))
    project = parser.value()
    require(parser.index == len(parser.tokens), 'Trailing project tokens')
    objects = project['objects']
    root = objects[project['rootObject']]
    require(root['developmentRegion'] == 'ja', 'Project development language is not Japanese')
    require(LOCALES <= set(root['knownRegions']), 'Project language list incomplete')
    require(not any(v['isa'] in ['PBXShellScriptBuildPhase', 'XCRemoteSwiftPackageReference', 'XCSwiftPackageProductDependency'] for v in objects.values()), 'Unexpected script/package dependency')
    file_paths = {}

    def walk(key, parent):
        item = objects[key]
        if item['isa'] == 'PBXGroup':
            directory = parent / item.get('path', '')
            for child in item['children']:
                require(child in objects, f'Dangling group reference: {child}')
                walk(child, directory)
        elif item['isa'] == 'PBXFileReference' and item.get('sourceTree') != 'BUILT_PRODUCTS_DIR':
            path = parent / item['path']
            require(path.exists(), f'Missing project file: {path}')
            file_paths[key] = path.resolve()

    walk(root['mainGroup'], ROOT)
    targets = {objects[key]['name']: objects[key] for key in root['targets']}
    require(set(targets) == {'PanPanCamera', 'PanPanCameraTests'}, 'Expected app and unit test targets')
    for target_name, target in targets.items():
        compiled, resources = [], []
        for phase_id in target['buildPhases']:
            phase = objects[phase_id]
            for build_id in phase['files']:
                path = file_paths[objects[build_id]['fileRef']]
                (compiled if phase['isa'] == 'PBXSourcesBuildPhase' else resources).append(path)
        expected = {p.resolve() for p in (ROOT / 'PanPanCamera').rglob('*.swift')
                    if ('Tests' in p.parts) == (target_name == 'PanPanCameraTests')}
        require(set(compiled) == expected and len(compiled) == len(expected), f'{target_name}: source membership mismatch')
        if target_name == 'PanPanCamera':
            expected_resources = {p.resolve() for p in (ROOT / 'PanPanCamera/Resources').rglob('*.xcstrings')}
            expected_resources.add((ROOT / 'PanPanCamera/Resources/Assets.xcassets').resolve())
            require(set(resources) == expected_resources and len(resources) == len(expected_resources), 'App resources mismatch')
        else:
            require(target['dependencies'], 'Test target must depend on app')
        print(f'PASS {target_name}: {len(compiled)} sources and {len(resources)} resources resolve without duplicates')
    for item in objects.values():
        if item['isa'] == 'XCBuildConfiguration':
            settings = item['buildSettings']
            require(not settings.get('DEVELOPMENT_TEAM'), 'Do not commit a personal signing team')
            require(not settings.get('SWIFT_OBJC_BRIDGING_HEADER'), 'Unexpected bridging header')
    scheme = ET.parse(ROOT / 'PanPanCamera.xcodeproj/xcshareddata/xcschemes/PanPanCamera.xcscheme')
    for reference in scheme.findall('.//BuildableReference'):
        require(reference.attrib['BlueprintIdentifier'] in root['targets'], 'Scheme points to missing target')
    testables = scheme.findall('.//TestableReference')
    require(len(testables) == 1 and testables[0].attrib['skipped'] == 'NO', 'Tests are absent or skipped in shared scheme')
    ET.parse(ROOT / 'PanPanCamera.xcodeproj/project.xcworkspace/contents.xcworkspacedata')
    for path in (ROOT / 'PanPanCamera/Resources/Assets.xcassets').rglob('Contents.json'):
        json.loads(path.read_text(encoding='utf-8'))
    print('PASS project syntax/reference graph, shared scheme, workspace XML, and asset JSON')


if __name__ == '__main__':
    try:
        check_catalogs()
        check_sources()
        check_project()
    except (ValueError, KeyError, IndexError, OSError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        sys.exit(1)
    print('STATIC CHECKS PASSED. Xcode build, XCTest, Simulator, and device camera were not run by this script.')
