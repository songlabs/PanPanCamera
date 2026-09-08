"""Fail before signing when release inputs or the existing app icon are missing."""
import json
import os
from pathlib import Path
import re
import sys
from validate_marketing_version import validate as validate_marketing_version

REQUIRED = ['APPLE_TEAM_ID', 'ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_PRIVATE_KEY',
            'APPLE_DISTRIBUTION_P12_BASE64', 'APPLE_DISTRIBUTION_P12_PASSWORD', 'PROFILE_PANPAN_BASE64']


def errors(environment):
    result = [f'Missing {name}' for name in REQUIRED if not environment.get(name, '').strip()]
    for name, pattern in [('APPLE_TEAM_ID', r'[A-Z0-9]{10}'), ('ASC_KEY_ID', r'[A-Z0-9]{10}'),
                          ('ASC_ISSUER_ID', r'[0-9a-fA-F-]{36}')]:
        if environment.get(name) and not re.fullmatch(pattern, environment[name]):
            result.append(f'Invalid {name} format')
    return result


if __name__ == '__main__':
    problems = errors(os.environ)
    try:
        validate_marketing_version(os.environ.get('MARKETING_VERSION'))
    except ValueError as error:
        problems.append(str(error))
    # The scaffold intentionally has no release artwork. Do not invent an icon.
    catalog = Path('PanPanCamera/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json')
    project = Path('PanPanCamera.xcodeproj/project.pbxproj').read_text()
    if not catalog.is_file() or 'ASSETCATALOG_COMPILER_APPICON_NAME' not in project:
        problems.append('Missing release AppIcon asset/configuration; provide the approved app icon before TestFlight')
    else:
        images = json.loads(catalog.read_text()).get('images', [])
        files = [catalog.parent / item['filename'] for item in images if item.get('filename')]
        if not files or any(not path.is_file() or path.stat().st_size == 0 for path in files):
            problems.append('Release AppIcon files are absent or empty')
    for problem in problems:
        print(f'::error::{problem}', file=sys.stderr)
    sys.exit(1 if problems else 0)
