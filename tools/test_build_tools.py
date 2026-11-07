import hashlib
import importlib.util
import plistlib
import struct
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
from validate_ipa import validate

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('project_generator', ROOT / 'tools/generate-project.py')
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class ProjectGenerationTest(unittest.TestCase):
    def test_project_is_deterministic_and_has_all_target_sources(self):
        first, scheme, counts = generator.generate()
        self.assertEqual(generator.generate()[0], first)
        for path in ROOT.glob('AnimeSync/**/*.swift'):
            self.assertIn(path.relative_to(ROOT).as_posix(), first)
        for path in ROOT.glob('Tests/**/*.swift'):
            self.assertIn(path.relative_to(ROOT).as_posix(), first)
        self.assertGreater(counts['appSwift'], 10)
        self.assertGreater(counts['unitSwift'], 0)
        self.assertEqual(counts['uiSwift'], 1)
        tree = ET.fromstring(scheme)
        targets = tree.findall('TestAction/Testables/TestableReference')
        self.assertEqual(len(targets), 2)
        self.assertTrue(all(t.attrib['skipped'] == 'NO' and t.attrib['parallelizable'] == 'NO' for t in targets))
        self.assertIn('--qa-fixture', scheme)

    def test_project_contains_supported_platform_and_all_root_js_resources(self):
        project, _, counts = generator.generate()
        for token in ['IPHONEOS_DEPLOYMENT_TARGET = "17.0"', 'SWIFT_VERSION = "5.0"', 'xyz.loibaks.animecompanion.ios', 'TEST_TARGET_NAME = "AnimeSync"', 'TEST_HOST = "$(BUILT_PRODUCTS_DIR)/AnimeSync.app/AnimeSync"']:
            self.assertIn(token, project)
        self.assertEqual(counts['javascript'], len(list(ROOT.glob('AnimeSync/Provider/Resources/*.js'))))
        self.assertEqual(counts['fonts'],1)
        for name in ['Roboto-Bold.ttf','Roboto-LICENSE.txt','Roboto-source.json']:
            self.assertIn('AnimeSync/Resources/Fonts/' + name,project)


class DeviceArtifactTest(unittest.TestCase):
    def artifact(self, directory, platform=2, cpu=0x0100000c, provisioned=False, revision='fixture-source', minimum='17.0', resources=True, bundle='xyz.loibaks.animecompanion.ios', font_registered=True, font_corrupt=False):
        path = Path(directory) / 'fixture.ipa'
        info = dict(CFBundlePackageType='APPL', CFBundleSupportedPlatforms=['iPhoneOS'], CFBundleExecutable='AnimeSync', CFBundleIdentifier=bundle, MinimumOSVersion=minimum, BuildSourceRevision=revision)
        if font_registered:
            info['UIAppFonts'] = ['Roboto-Bold.ttf']
        binary = struct.pack('<8I', 0xfeedfacf, cpu, 0, 2, 1, 24, 0, 0) + struct.pack('<6I', 0x32, 24, platform, 0, 0, 0)
        with zipfile.ZipFile(path, 'w') as archive:
            prefix = 'Payload/AnimeSync.app/'
            archive.writestr(prefix + 'Info.plist', plistlib.dumps(info)); archive.writestr(prefix + 'AnimeSync', binary)
            if provisioned:
                archive.writestr(prefix + 'embedded.mobileprovision', b'fixture')
            if resources:
                for name in ['provider.js', 'resource-observer.js', 'dashboard.js', 'tv-navigation.js', 'Assets.car']:
                    archive.writestr(prefix + name, b'fixture')
                for name in ['Roboto-Bold.ttf','Roboto-LICENSE.txt','Roboto-source.json']:
                    data = (ROOT / 'AnimeSync/Resources/Fonts' / name).read_bytes()
                    if font_corrupt and name.endswith('.ttf'):
                        data = data[:-1] + bytes([data[-1] ^ 1])
                    archive.writestr(prefix + name,data)
        return path

    def test_accepts_exact_device_revision_and_computes_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.artifact(directory)
            result = validate(path, expected_revision='fixture-source')
            self.assertEqual(result['machOPlatform'], 2)
            self.assertEqual(result['sha256'], hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertTrue(result['requiresLocalSigning'])
            self.assertEqual(result['subtitleFont']['postScriptName'],'Roboto-Bold')

    def test_rejects_simulator_architecture_platform_and_legacy_proof(self):
        for kwargs, expected in [({'platform': 7}, 'simulator'), ({'cpu': 0x01000007}, 'arm64'), ({'bundle': 'xyz.loibaks.animesync.iphoneproof'}, 'identifier')]:
            with self.subTest(kwargs=kwargs), tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(ValueError, expected):
                    validate(self.artifact(directory, **kwargs))

    def test_rejects_stale_revision_missing_resources_profiles_and_wrong_minimum(self):
        for kwargs, expected in [({'revision': 'old'}, 'revision'), ({'resources': False}, 'resource'), ({'provisioned': True}, 'provisioning'), ({'minimum': '16.0'}, 'minimum')]:
            with self.subTest(kwargs=kwargs), tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(ValueError, expected):
                    validate(self.artifact(directory, **kwargs), expected_revision='fixture-source')

    def test_rejects_unregistered_and_corrupted_shared_subtitle_font(self):
        for kwargs, expected in [({'font_registered': False},'UIAppFonts'),({'font_corrupt': True},'pinned source')]:
            with self.subTest(kwargs=kwargs), tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(ValueError,expected):
                    validate(self.artifact(directory,**kwargs))
