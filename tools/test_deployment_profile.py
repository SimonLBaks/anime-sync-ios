import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

import test_build_tools as artifact_fixtures
from deployment_profile import validate
from validate_ipa import validate as validate_public_ipa

spec = importlib.util.spec_from_file_location('personalize_ipa_tool', Path(__file__).with_name('personalize-ipa.py'))
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


def profile():
    return {'homeURL': 'https://home.example', 'tailnetURL': 'https://remote.example:8443',
            'connectOverrides': {'home.example': '10.0.0.10'}, 'defaultTVHost': '10.0.0.20'}


class DeploymentProfileTest(unittest.TestCase):
    def test_rejects_credential_fields_noncanonical_origins_and_unsafe_routes(self):
        cases = [dict(profile(), password='not-accepted'), dict(profile(), homeURL='http://home.example'),
                 dict(profile(), homeURL='https://user:pass@home.example'), dict(profile(), homeURL='https://home.example/path'),
                 dict(profile(), homeURL='https://home.example?'), dict(profile(), homeURL='https://home.example#'),
                 dict(profile(), homeURL='https://home.example:8765'), dict(profile(), tailnetURL='https://home.example'),
                 dict(profile(), homeURL='https://-bad.example'), dict(profile(), homeURL='https://' + 'x' * 64 + '.example'),
                 dict(profile(), connectOverrides={'unrelated.example': '10.0.0.10'}),
                 dict(profile(), connectOverrides={'home.example': '8.8.8.8'}),
                 dict(profile(), connectOverrides={'home.example': '127.0.0.1'}),
                 dict(profile(), connectOverrides={'home.example': '169.254.1.1'}),
                 dict(profile(), defaultTVHost='10.00.0.20')]
        for value in cases:
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate(value)
        self.assertEqual(validate(profile()), profile())

    def test_local_personalization_preserves_public_input_and_omits_profile_from_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            source = artifact_fixtures.DeviceArtifactTest().artifact(directory)
            original = source.read_bytes()
            target = Path(directory) / 'personalized.ipa'
            receipt = tool.personalize(source, profile(), target, 'fixture-source')
            self.assertEqual(source.read_bytes(), original)
            with zipfile.ZipFile(source) as public, zipfile.ZipFile(target) as private:
                self.assertEqual(set(private.namelist()) - set(public.namelist()), {tool.PROFILE_PATH})
                for name in public.namelist():
                    self.assertEqual(private.read(name), public.read(name))
                self.assertEqual(json.loads(private.read(tool.PROFILE_PATH)), profile())
            self.assertTrue(receipt['localPersonalization'])
            self.assertFalse(receipt['publicUploadAllowed'])
            self.assertNotIn('home.example', json.dumps(receipt))
            self.assertNotIn('10.0.0.10', json.dumps(receipt))
            with self.assertRaisesRegex(ValueError, 'private deployment profile'):
                validate_public_ipa(target)

    def test_invalid_profile_creates_no_output_and_source_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            source = artifact_fixtures.DeviceArtifactTest().artifact(directory)
            original = source.read_bytes()
            target = Path(directory) / 'personalized.ipa'
            with self.assertRaises(ValueError):
                tool.personalize(source, dict(profile(), token='not-accepted'), target)
            self.assertFalse(target.exists())
            with self.assertRaises(ValueError):
                tool.personalize(source, profile(), source)
            self.assertEqual(source.read_bytes(), original)
