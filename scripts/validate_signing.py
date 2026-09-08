"""Validate Apple's decoded profile contract for this single app; no secret values logged."""
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_profile(profile, team, bundle_id, certificate_sha1, now=None):
    now = now or datetime.now(timezone.utc)
    require(profile.get('TeamIdentifier') == [team], 'Wrong TeamIdentifier in provisioning profile')
    prefixes = profile.get('ApplicationIdentifierPrefix', [])
    require(len(prefixes) == 1 and re.fullmatch(r'[A-Z0-9]{10}', prefixes[0]), 'Invalid App ID prefix')
    entitlements = profile.get('Entitlements', {})
    require(entitlements.get('application-identifier') == f'{prefixes[0]}.{bundle_id}', 'Wrong Bundle ID in profile')
    require(entitlements.get('com.apple.developer.team-identifier') == team, 'Wrong entitlement Team ID')
    require(entitlements.get('get-task-allow') is False, 'Development or missing get-task-allow entitlement rejected')
    require(entitlements.get('beta-reports-active') is True, 'Profile is not for App Store distribution')
    require('ProvisionedDevices' not in profile, 'Development/Ad Hoc profile rejected')
    require('ProvisionsAllDevices' not in profile, 'Enterprise profile rejected')
    require('iOS' in profile.get('Platform', []), 'Profile is not for iOS')
    expiration = profile.get('ExpirationDate')
    require(isinstance(expiration, datetime), 'Unable to parse profile expiration date')
    require(expiration.replace(tzinfo=timezone.utc) > now, 'Expired profile rejected')
    require(re.fullmatch(r'[0-9A-Fa-f-]{36}', profile.get('UUID', '')), 'Invalid profile UUID')
    certificates = profile.get('DeveloperCertificates', [])
    certificate = next((data for data in certificates
                        if hashlib.sha1(data).hexdigest().upper() == certificate_sha1.upper()), None)
    require(certificate is not None, 'Distribution certificate is not included in the profile')
    return certificate


def validate_entitlements(actual, profile):
    allowed = profile['Entitlements']
    for name in ['application-identifier', 'com.apple.developer.team-identifier', 'get-task-allow', 'beta-reports-active']:
        require(name in actual and actual[name] == allowed[name], f'Archive entitlement mismatch: {name}')

    def permitted(value, allowance):
        if isinstance(value, list):
            return isinstance(allowance, list) and all(any(permitted(item, other) for other in allowance) for item in value)
        if isinstance(value, dict):
            return isinstance(allowance, dict) and all(key in allowance and permitted(item, allowance[key]) for key, item in value.items())
        if isinstance(value, str) and isinstance(allowance, str):
            # Provisioning profiles use terminal '*' to allow a prefix, not arbitrary regex/globs.
            return value.startswith(allowance[:-1]) if allowance.endswith('*') else value == allowance
        return type(value) is type(allowance) and value == allowance

    for name, value in actual.items():
        require(name in allowed and permitted(value, allowed[name]), f'Archive entitlement not allowed by profile: {name}')


def main():
    directory = Path(os.environ['RUNNER_TEMP']) / 'panpan-signing'
    profile = plistlib.loads((directory / 'profile.plist').read_bytes())
    fingerprint = os.environ['SIGNING_CERTIFICATE_SHA1']
    cert = validate_profile(profile, os.environ['APPLE_TEAM_ID'], os.environ['APP_BUNDLE_ID'], fingerprint)
    cert_path = directory / 'distribution.cer'
    cert_path.write_bytes(cert)
    subprocess.run(['openssl', 'x509', '-inform', 'DER', '-in', str(cert_path), '-checkend', '0', '-noout'], check=True)
    subject = subprocess.check_output(['openssl', 'x509', '-inform', 'DER', '-in', str(cert_path),
                                       '-subject', '-nameopt', 'sep_multiline', '-noout'], text=True)
    require(re.search(r'^\s*OU\s*=\s*' + re.escape(os.environ['APPLE_TEAM_ID']) + r'\s*$', subject, re.M),
            'Distribution certificate Team ID mismatch')
    require(re.search(r'^\s*CN\s*=\s*Apple Distribution:', subject, re.M), 'Not an Apple Distribution certificate')
    if len(sys.argv) > 1:
        app = Path(sys.argv[1])
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        for key, expected in [('CFBundleIdentifier', os.environ['APP_BUNDLE_ID']),
                              ('CFBundleShortVersionString', os.environ['MARKETING_VERSION']),
                              ('CFBundleVersion', os.environ['BUILD_NUMBER'])]:
            require(info.get(key) == expected, f'Archive {key} does not match requested value')
        embedded = plistlib.loads((directory / 'embedded.plist').read_bytes())
        validate_profile(embedded, os.environ['APPLE_TEAM_ID'], os.environ['APP_BUNDLE_ID'], fingerprint)
        require(embedded == profile, 'Archive provisioning profile differs from installed profile')
        validate_entitlements(plistlib.loads((directory / 'entitlements.plist').read_bytes()), profile)
        leaf = (directory / 'archive-certificate0').read_bytes()
        require(hashlib.sha1(leaf).hexdigest().upper() == fingerprint.upper(), 'Archive signing certificate mismatch')
        print(f'Archive verified: {info["CFBundleIdentifier"]} {info["CFBundleShortVersionString"]} ({info["CFBundleVersion"]})')
    else:
        with open(os.environ['GITHUB_ENV'], 'a') as env_file:
            env_file.write(f'PANPAN_PROFILE_UUID={profile["UUID"]}\n')
        print(f'App Store profile validated; expires {profile["ExpirationDate"].isoformat()} UTC')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
