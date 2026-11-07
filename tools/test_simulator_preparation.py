import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location('prepare_simulator', Path(__file__).with_name('prepare-simulator.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def device(identifier, available=True, state='Shutdown'):
    return dict(name='iPhone 16 Pro', udid=identifier, isAvailable=available, state=state)


def runtime(value):
    return 'com.apple.CoreSimulator.SimRuntime.iOS-' + value


class SimulatorSelectionTests(unittest.TestCase):
    def test_exact_sdk_beats_first_newer_runtime(self):
        state = {'devices': {runtime('18-6'): [device('wrong-first')], runtime('26-1'): [device('future')], runtime('18-5'): [device('right')], runtime('18-4'): [device('older')]}}
        self.assertEqual(module.choose_device(state, '18.5')['udid'], 'right')

    def test_normalizes_patch_version_and_uses_latest_compatible_fallback(self):
        exact = {'devices': {runtime('18-5-0'): [device('exact')]}}
        self.assertEqual(module.choose_device(exact, '18.5')['udid'], 'exact')
        older = {'devices': {runtime('18-3'): [device('old')], runtime('18-4'): [device('newer')]}}
        self.assertEqual(module.choose_device(older, '18.5')['udid'], 'newer')

    def test_rejects_only_future_or_unavailable_devices(self):
        for devices in [{runtime('26-1'): [device('future')]}, {runtime('18-5'): [device('off', available=False)]}]:
            with self.assertRaises(ValueError):
                module.choose_device({'devices': devices}, '18.5')

    def test_booted_device_on_matching_sdk_is_reused(self):
        state = {'devices': {runtime('18-5'): [device('cold'), device('warm', state='Booted')]}}
        self.assertEqual(module.choose_device(state, '18.5')['udid'], 'warm')


class SimulatorStageTests(unittest.TestCase):
    def test_regular_files_capture_both_streams_and_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            stages = module.Stages(directory, 'summary.json')
            code, output = stages.run('fixture', [sys.executable, '-c', 'import sys; print("out"); print("err",file=sys.stderr); sys.exit(7)'], 2)
            self.assertEqual(code, 7); self.assertEqual(output.strip(), 'out')
            self.assertEqual((Path(directory) / 'fixture.stderr.txt').read_text().strip(), 'err')
            self.assertEqual(json.loads((Path(directory) / 'summary.json').read_text())['commands']['fixture']['code'], 7)

    def test_timeout_is_bounded_and_preserves_stage_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            started = time.monotonic()
            stages = module.Stages(directory, 'summary.json')
            code, _ = stages.run('fixture', [sys.executable, '-c', 'import time; time.sleep(30)'], 0.08)
            self.assertEqual(code, 124); self.assertLess(time.monotonic()-started, 2)
            self.assertTrue(json.loads((Path(directory) / 'summary.json').read_text())['commands']['fixture']['timedOut'])

class SimulatorLaunchPIDTests(unittest.TestCase):
    def test_accepts_only_the_named_app_positive_pid(self):
        self.assertEqual(module.launch_pid('xyz.loibaks.animecompanion.ios: 12345\n', 'xyz.loibaks.animecompanion.ios'), 12345)
        self.assertEqual(module.launch_pid('diagnostic line\nxyz.loibaks.animecompanion.ios: 12345\n', 'xyz.loibaks.animecompanion.ios'), 12345)

    def test_rejects_wrong_app_missing_pid_and_zero(self):
        for output in ['other.app: 12345', 'xyz.loibaks.animecompanion.ios: 0', 'Application does not have a process ID', 'xyz.loibaks.animecompanion.ios: 12345 invalid']:
            with self.subTest(output=output), self.assertRaises(ValueError):
                module.launch_pid(output, 'xyz.loibaks.animecompanion.ios')
