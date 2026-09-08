"""One strict marketing-version rule shared by preflight and archive validation."""
import re
import sys

PATTERN = r'^[0-9]+\.[0-9]+\.[0-9]+$'


def validate(value):
    if not isinstance(value, str) or re.fullmatch(PATTERN, value) is None:
        raise ValueError('marketing_version must contain exactly three numeric components (e.g. 0.1.0)')
    return value


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('Usage: validate_marketing_version.py VERSION')
        print(f'Marketing version validated: {validate(sys.argv[1])}')
    except ValueError as error:
        sys.exit(str(error))
