import importlib.util
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('simulator_scope', ROOT / 'tools/simulator-scope.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SimulatorScopeTests(unittest.TestCase):
    def test_default_full_scope_keeps_every_live_and_fixture_case(self):
        full = module.scope(ROOT)
        self.assertIn(module.LIVE, full['selectedUIMethods'])
        self.assertFalse(full['excludedUIMethods'])
        self.assertGreater(len(full['unitMethods']), 90)

    def test_fixture_gate_excludes_only_external_live_check_without_calling_it_passed(self):
        full, fixture = module.scope(ROOT), module.scope(ROOT, 'fixtures')
        self.assertEqual(fixture['unitMethods'], full['unitMethods'])
        self.assertEqual(set(full['selectedUIMethods']) - set(fixture['selectedUIMethods']), {module.LIVE})
        self.assertEqual([entry['method'] for entry in fixture['excludedUIMethods']], [module.LIVE])
        self.assertIn('not counted as passed', fixture['excludedUIMethods'][0]['reason'])

    def test_focused_scope_is_exact_and_unknown_mode_fails_before_spending_runner_time(self):
        self.assertEqual(module.scope(ROOT, 'features')['selectedUIMethods'], module.FEATURES)
        with self.assertRaises(ValueError):
            module.scope(ROOT, 'typo')

    def test_library_resume_selects_only_app_model_methods(self):
        focused = module.scope(ROOT, 'library-resume')
        self.assertIn('testCompletedLibraryCheckpointOpensAdvertisedNumericNextEpisode', focused['unitMethods'])
        self.assertIn('testContinueDoesNotOpenOldEpisodeWhenAnotherDeviceChangesTheSeriesHead', focused['unitMethods'])
        source = (ROOT / 'Tests/AppModelTests.swift').read_text()
        self.assertEqual(focused['unitMethods'], re.findall(r'func (test\w+)\(', source))
        self.assertFalse(focused['selectedUIMethods'])
        self.assertTrue(focused['excludedUIMethods'])
