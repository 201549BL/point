"""Exercise the installer gate against real macOS code signatures.

Run: python3 Tests/InstallSigningTests.py
Certificate-dependent cases skip when the development keychain is unavailable.
"""
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
GATE = ROOT / 'Scripts/check-install-signing.sh'


class InstallSigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which('codesign'):
            raise unittest.SkipTest('Requires macOS codesign')
        cls.directory = tempfile.TemporaryDirectory(prefix='point-signing-tests-')
        cls.folder = pathlib.Path(cls.directory.name)
        source = cls.folder / 'main.c'
        source.write_text('int main(void) { return 0; }\n')
        cls.binary = cls.folder / 'Point'
        subprocess.run(['cc', str(source), '-o', str(cls.binary)], check=True, capture_output=True)
        identities = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                                    check=True, capture_output=True, text=True).stdout
        cls.identities = {name: digest for digest, name in re.findall(r'([A-F0-9]{40}) "([^"]+)"', identities)}

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def app(self, name, identity, bundle_id='com.eirikbjorndal.point'):
        app = self.folder / (name + '.app')
        contents = app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'Point', 'CFBundlePackageType': 'APPL',
            'CFBundleVersion': '1',
        }))
        shutil.copy2(self.binary, contents / 'MacOS/Point')
        subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none', str(app)],
                       check=True, capture_output=True)
        return app

    def identity(self, prefix):
        for name, digest in self.identities.items():
            if name.startswith(prefix) and ('DNPD2D9266' in name or 'Eirik' in name):
                return digest
        self.skipTest('Point signing certificate unavailable: ' + prefix)

    def gate(self, *apps):
        return subprocess.run([str(GATE), *map(str, apps)], capture_output=True, text=True)

    def test_adhoc_production_build_is_rejected(self):
        app = self.app('adhoc', '-')
        self.assertNotEqual(self.gate(app).returncode, 0)

    def test_apple_development_cannot_replace_production(self):
        app = self.app('development', self.identity('Apple Development:'))
        self.assertNotEqual(self.gate(app).returncode, 0)

    def test_separate_dev_identifier_cannot_replace_production(self):
        app = self.app('dev-identifier', self.identity('Developer ID Application:'), 'com.eirikbjorndal.point.dev')
        self.assertNotEqual(self.gate(app).returncode, 0)

    def test_release_identity_survives_binary_changes(self):
        identity = self.identity('Developer ID Application:')
        previous = self.app('previous', identity)
        candidate = self.app('candidate', identity)
        source = self.folder / 'changed.c'
        source.write_text('int main(void) { return 1; }\n')
        subprocess.run(['cc', str(source), '-o', str(candidate / 'Contents/MacOS/Point')],
                       check=True, capture_output=True)
        subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none', str(candidate)],
                       check=True, capture_output=True)
        result = self.gate(candidate, previous)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_signing_migration_is_rejected_before_replacement(self):
        previous = self.app('old-development', self.identity('Apple Development:'))
        candidate = self.app('new-release', self.identity('Developer ID Application:'))
        original = (previous / 'Contents/MacOS/Point').read_bytes()
        result = self.gate(candidate, previous)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--repair-permissions', result.stderr)
        self.assertEqual((previous / 'Contents/MacOS/Point').read_bytes(), original)


if __name__ == '__main__':
    unittest.main(verbosity=2)
