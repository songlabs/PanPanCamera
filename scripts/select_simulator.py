"""Select an available iPhone on the newest supported iOS 26.x runtime."""
import json
import os
from pathlib import Path
import re
import sys

PREFERRED = ['iPhone 17 Pro Max', 'iPhone 17 Pro', 'iPhone 16 Pro Max', 'iPhone 16 Pro']


def select(inventory):
    candidates = []
    for runtime, devices in inventory['devices'].items():
        match = re.search(r'SimRuntime\.iOS-(26(?:-\d+)*)$', runtime)
        if not match:
            continue
        version = tuple(int(part) for part in match[1].split('-'))
        for device in devices:
            if not device.get('isAvailable', False) or not device['name'].startswith('iPhone'):
                continue
            name = device['name']
            generation = re.search(r'iPhone (\d+)', name)
            rank = len(PREFERRED) - PREFERRED.index(name) if name in PREFERRED else 0
            candidates.append((version, rank, int(generation[1]) if generation else 0, name, device))
    if not candidates:
        raise ValueError('No available iPhone simulator on iOS 26.x. Simulator inventory follows:\n'
                         + json.dumps(inventory, indent=2))
    version, _, _, _, device = max(candidates, key=lambda item: item[:4])
    return {'SIMULATOR_ID': device['udid'], 'SIMULATOR_NAME': device['name'],
            'IOS_VERSION': '.'.join(map(str, version))}


if __name__ == '__main__':
    try:
        result = select(json.loads(Path(sys.argv[1]).read_text()))
        output = ''.join(f'{key}={value}\n' for key, value in result.items())
        with open(os.environ['GITHUB_ENV'], 'a') as destination:
            destination.write(output)
        print(output, end='')
    except (ValueError, KeyError, OSError) as error:
        sys.exit(str(error))
