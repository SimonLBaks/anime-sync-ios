import subprocess
import sys
import time
import unittest
from pathlib import Path

RUNNER = Path(__file__).with_name('run-with-progress.py')


class BuildWatchdogTests(unittest.TestCase):
    def execute(self, code, timeout=3, heartbeat=0.02):
        return subprocess.run([sys.executable, str(RUNNER), '--timeout', str(timeout), '--heartbeat', str(heartbeat), '--', sys.executable, '-c', code], capture_output=True, text=True, timeout=8)

    def test_preserves_child_failure_and_both_output_streams(self):
        result = self.execute('import sys; print("compiler stdout", flush=True); print("compiler stderr", file=sys.stderr, flush=True); sys.exit(7)')
        self.assertEqual(result.returncode, 7)
        self.assertIn('compiler stdout', result.stdout)
        self.assertIn('compiler stderr', result.stdout)

    def test_prints_progress_while_child_is_silent(self):
        result = self.execute('import time; time.sleep(0.1)')
        self.assertEqual(result.returncode, 0)
        self.assertIn('Build still running', result.stdout)

    def test_timeout_stops_command_without_masking_failure(self):
        started = time.monotonic()
        result = self.execute('import time; time.sleep(30)', timeout=0.08)
        self.assertEqual(result.returncode, 124)
        self.assertIn('timed out', result.stdout)
        self.assertLess(time.monotonic() - started, 3)

    def test_missing_command_is_a_failure(self):
        result = subprocess.run([sys.executable, str(RUNNER), '--timeout', '2', '--', '/nonexistent/anime-build-command'], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 127)
