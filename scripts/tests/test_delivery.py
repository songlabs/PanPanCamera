"""Behavior checks for the release gates; no Apple credentials or hardware required."""
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from select_simulator import select
from validate_release_configuration import REQUIRED, errors
from validate_signing import validate_entitlements, validate_profile
from verify_ci_gate import verify


class SimulatorSelectionTests(unittest.TestCase):
    def inventory(self, entries):
        return {'devices': {f'com.apple.CoreSimulator.SimRuntime.iOS-{version}': [
            {'name': name, 'udid': f'{version}-{name}', 'isAvailable': available}
            for name, available in devices] for version, devices in entries}}

    def testNewestSupportedRuntimeAndPreferredPhone(self):
        inventory = self.inventory([
            ('26-1', [('iPhone 17 Pro Max', True)]),
            ('26-2', [('iPhone 16 Pro', True), ('iPhone 17 Pro', True), ('iPhone 17 Pro Max', True)]),
            ('27-0', [('iPhone 17 Pro Max', True)])])
        result = select(inventory)
        self.assertEqual(result['IOS_VERSION'], '26.2')
        self.assertEqual(result['SIMULATOR_NAME'], 'iPhone 17 Pro Max')

    def testUnavailableDevicesAndFallback(self):
        result = select(self.inventory([('26-2', [('iPhone 17 Pro Max', False), ('iPhone 16 Pro Max', True),
                                                  ('iPhone 17 Pro', True)])]))
        self.assertEqual(result['SIMULATOR_NAME'], 'iPhone 17 Pro')
        result = select(self.inventory([('26-2', [('iPhone 15', True), ('iPhone 17', True)])]))
        self.assertEqual(result['SIMULATOR_NAME'], 'iPhone 17')

    def testNoSupportedPhoneFailsWithInventory(self):
        for entries in [[('26-2', [('iPad Pro', True)])], [('25-0', [('iPhone 16 Pro', True)])], []]:
            with self.assertRaisesRegex(ValueError, 'inventory'):
                select(self.inventory(entries))


class CIGateTests(unittest.TestCase):
    def run_record(self, **overrides):
        result = dict(head_sha='current', head_branch='main', name='iOS CI', status='completed',
                      conclusion='success', html_url='https://github.com/example/run/1')
        result.update(overrides)
        return result

    def testExactCommitSuccessPasses(self):
        self.assertIn('current', verify({'workflow_runs': [self.run_record()]}, 'current'))

    def testOtherCommitBranchOrWorkflowCannotPass(self):
        for overrides in [dict(head_sha='old'), dict(head_branch='feature'), dict(name='Other CI')]:
            with self.assertRaisesRegex(ValueError, 'No iOS CI run'):
                verify({'workflow_runs': [self.run_record(**overrides)]}, 'current')

    def testMissingFailedAndInProgressStopBeforeSigning(self):
        for runs, reason in [([], 'No iOS CI run'), ([self.run_record(conclusion='failure')], 'did not succeed'),
                             ([self.run_record(status='in_progress', conclusion=None)], 'not completed'),
                             ([self.run_record(conclusion='cancelled')], 'did not succeed')]:
            with self.assertRaisesRegex(ValueError, reason):
                verify({'workflow_runs': runs}, 'current')


class SigningContractTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 9, 8, tzinfo=timezone.utc)
        # This is an opaque test reference, not a certificate or signing material.
        self.reference = b'unit-test-only-certificate-reference'
        self.sha = hashlib.sha1(self.reference).hexdigest()
        self.profile = {
            'UUID': '11111111-2222-3333-4444-555555555555', 'TeamIdentifier': ['TESTTEAM00'],
            'ApplicationIdentifierPrefix': ['TESTTEAM00'], 'Platform': ['iOS'],
            'ExpirationDate': self.now + timedelta(days=1), 'DeveloperCertificates': [self.reference],
            'Entitlements': {'application-identifier': 'TESTTEAM00.com.songlabs.PanPanCamera',
                             'com.apple.developer.team-identifier': 'TESTTEAM00', 'get-task-allow': False,
                             'beta-reports-active': True}}

    def validate(self, profile):
        return validate_profile(profile, 'TESTTEAM00', 'com.songlabs.PanPanCamera', self.sha, self.now)

    def testMatchingFutureProfile(self):
        self.assertEqual(self.validate(self.profile), self.reference)

    def testExpiredAndMalformedDatesAreDistinctFailures(self):
        for value, message in [(self.now - timedelta(seconds=1), 'Expired'), (self.now, 'Expired'),
                               ('invalid date', 'Unable to parse')]:
            profile = copy.deepcopy(self.profile)
            profile['ExpirationDate'] = value
            with self.assertRaisesRegex(ValueError, message):
                self.validate(profile)

    def testWrongTeamBundleCertificateAndProfileTypesFail(self):
        for key, value in [('TeamIdentifier', ['OTHERTEAM0']), ('DeveloperCertificates', []),
                            ('ProvisionedDevices', []), ('ProvisionsAllDevices', True), ('Platform', ['OSX'])]:
            profile = copy.deepcopy(self.profile)
            profile[key] = value
            with self.assertRaises(ValueError):
                self.validate(profile)
        for key, value in [('application-identifier', 'TESTTEAM00.wrong.bundle'), ('get-task-allow', True),
                            ('beta-reports-active', False), ('com.apple.developer.team-identifier', 'OTHERTEAM0')]:
            profile = copy.deepcopy(self.profile)
            profile['Entitlements'][key] = value
            with self.assertRaises(ValueError):
                self.validate(profile)

    def testArchiveEntitlementsMustMatchAndBeAllowed(self):
        actual = copy.deepcopy(self.profile['Entitlements'])
        validate_entitlements(actual, self.profile)
        for key, value in [('get-task-allow', True), ('application-identifier', 'wrong'), ('unexpected', True)]:
            modified = dict(actual, **{key: value})
            with self.assertRaises(ValueError):
                validate_entitlements(modified, self.profile)

    def testMissingConfigurationListsEveryRequiredName(self):
        result = errors({})
        self.assertEqual(result, [f'Missing {name}' for name in REQUIRED])


class UploadFailureTests(unittest.TestCase):
    def testUploaderExitAndRejectionMarkersCannotBeSwallowedByTee(self):
        bash = shutil.which('bash') or r'C:\Program Files\Git\bin\bash.exe'
        for code, output, succeeds in [(0, 'UPLOAD SUCCEEDED with no errors', True),
                                        (1, 'transport failed', False), (0, 'Validation failed (409)', False),
                                        (0, 'Invalid Pre-Release Train', False), (0, 'UPLOAD FAILED', False)]:
            with self.subTest(code=code, output=output), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'bin').mkdir()
                stub = root / 'bin/xcrun'
                stub.write_text('#!/bin/bash\nprintf "%s\\n" "$TEST_UPLOAD_OUTPUT"\nexit "$TEST_UPLOAD_EXIT"\n', newline='\n')
                stub.chmod(0o755)
                environment = dict(os.environ, RUNNER_TEMP='.', ASC_KEY_ID='test', ASC_ISSUER_ID='test',
                                   TEST_UPLOAD_EXIT=str(code), TEST_UPLOAD_OUTPUT=output)
                result = subprocess.run([bash, '-c', 'export PATH="$PWD/bin:$PATH"; bash "$1"',
                                         'upload-check', (SCRIPTS / 'upload_testflight.sh').as_posix()],
                                        cwd=root, env=environment, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
