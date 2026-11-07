#!/usr/bin/env python3
"""Prepare a pinned-SDK iPhone simulator with bounded, file-backed diagnostic stages."""
import argparse
from datetime import datetime, timezone
import json
import os
import plistlib
from pathlib import Path
import re
import signal
import subprocess
import time


def version(value):
    if not re.fullmatch(r'\d+(?:\.\d+){0,2}', value.strip()):
        raise ValueError('Invalid simulator SDK/runtime version: ' + value)
    return tuple((list(map(int, value.strip().split('.'))) + [0, 0, 0])[:3])


def choose_device(state, sdk):
    sdk_version = version(sdk)
    choices = []
    for runtime, devices in state.get('devices', {}).items():
        found = re.fullmatch(r'com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+(?:-\d+){0,2})', runtime)
        if not found:
            continue
        runtime_version = version(found[1].replace('-', '.'))
        if runtime_version > sdk_version:
            continue
        for device in devices:
            if device.get('isAvailable') and device.get('name', '').startswith('iPhone'):
                choices.append((runtime_version == sdk_version, runtime_version, device.get('state') == 'Booted', dict(device, runtime=runtime)))
    if not choices:
        raise ValueError('No available iPhone simulator runtime at or below pinned SDK ' + sdk)
    choices.sort(key=lambda item: item[:3], reverse=True)
    return choices[0][3]


def terminate_group(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass  # Keep diagnostics/EXIT collection bounded even for a kernel-stalled child.


class Stages:
    def __init__(self, output, summary_name):
        self.output = Path(output)
        self.output.mkdir(parents=True, exist_ok=True)
        self.summary_path = self.output / summary_name
        self.summary = {'startedAt': datetime.now(timezone.utc).isoformat(), 'commands': {}}

    def save(self):
        self.summary_path.write_text(json.dumps(self.summary, indent=2) + '\n')

    def run(self, name, command, timeout, stdout_path=None, stderr_path=None):
        stdout_path = Path(stdout_path) if stdout_path else self.output / (name + '.stdout.txt')
        stderr_path = Path(stderr_path) if stderr_path else self.output / (name + '.stderr.txt')
        stdout_path.parent.mkdir(parents=True, exist_ok=True)
        stderr_path.parent.mkdir(parents=True, exist_ok=True)
        row = {'status': 'starting', 'timeoutSeconds': timeout, 'stdout': str(stdout_path), 'stderr': str(stderr_path)}
        self.summary['stage'] = name; self.summary['commands'][name] = row; self.save()
        print('START', name, 'timeout', timeout, flush=True)
        started = time.monotonic()
        try:
            with stdout_path.open('w') as stdout, stderr_path.open('w') as stderr:
                # CoreSimulator descendants may inherit output. Never use PIPE/communicate.
                process = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
                try:
                    deadline = started + timeout
                    while True:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            terminate_group(process); row.update(code=124, timedOut=True); break
                        try:
                            code = process.wait(timeout=min(30, remaining))
                            row.update(code=code if code >= 0 else 128-code, timedOut=False); break
                        except subprocess.TimeoutExpired:
                            print(name, 'still running after', round(time.monotonic()-started), 'seconds', flush=True)
                except (KeyboardInterrupt, InterruptedError):
                    terminate_group(process); row.update(code=130, interrupted=True); raise
        except OSError as error:
            row.update(code=127, error=str(error))
        finally:
            row.update(status='finished', seconds=round(time.monotonic()-started, 3))
            self.save(); print('END', name, json.dumps(row), flush=True)
        return row['code'], stdout_path.read_text(errors='replace')

    def require(self, name, command, timeout, **paths):
        code, text = self.run(name, command, timeout, **paths)
        if code:
            raise RuntimeError(name + ' failed with exit ' + str(code) + '; inspect its file logs')
        return text


def prepare(output):
    stages = Stages(output, 'simulator-preparation-summary.json')
    try:
        stages.run('system-xcode-current', ['xcode-select', '-p'], 15)
        sdk = stages.require('simulator-sdk-version', ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], 30).strip()
        stages.summary['sdk'] = sdk; stages.save()
        raw = stages.require('simulator-device-list', ['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], 120, stdout_path=stages.output / 'simulator-devices.json')
        chosen = choose_device(json.loads(raw), sdk)
        stages.summary['simulator'] = chosen; stages.save()
        (stages.output / 'simulator-id.txt').write_text(chosen['udid'] + '\n')
        print('Selected', chosen['name'], chosen['runtime'], 'for SDK', sdk, flush=True)
        stages.run('simulator-runtimes', ['xcrun', 'simctl', 'list', 'runtimes', '-j'], 20, stdout_path=stages.output / 'simulator-runtimes.json')
        if chosen.get('state') != 'Booted':
            stages.require('simulator-boot', ['xcrun', 'simctl', 'boot', chosen['udid']], 30)
        stages.require('simulator-bootstatus', ['xcrun', 'simctl', 'bootstatus', chosen['udid'], '-b'], 420)
        stages.summary.update(stage='ready', ready=True); stages.save()
        return 0
    except (Exception, KeyboardInterrupt) as error:
        stages.summary.update(error=str(error), ready=False); stages.save()
        print('Simulator preparation failed:', error, flush=True)
        return 1


def launch_pid(text, bundle_id):
    found = re.search(r'^' + re.escape(bundle_id) + r':\s*(\d+)\s*$', text, re.MULTILINE)
    if not found or int(found[1]) <= 0:
        raise ValueError('simctl launch did not return the expected application PID')
    return int(found[1])


def launch_app(output, app):
    stages = Stages(output, 'simulator-launch-summary.json')
    bundle_id = None
    device = None
    try:
        app = Path(app).resolve()
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        bundle_id = info.get('CFBundleIdentifier')
        if bundle_id != 'xyz.loibaks.animecompanion.ios':
            raise ValueError('Unexpected simulator application bundle')
        device = (stages.output / 'simulator-id.txt').read_text().strip()
        if not device:
            raise ValueError('No prepared simulator ID')
        executable = app / 'AnimeSync.debug.dylib'
        if not executable.exists():
            executable = app / info['CFBundleExecutable']
        stages.run('simulator-app-dependencies', ['xcrun', 'otool', '-L', str(executable)], 30)
        # The cold hosted runner completed boot after four minutes but still had
        # first-launch system services starting when the old 30-second install
        # deadline expired. Keep this gate bounded without mistaking that for an
        # application failure. No retry can silently bypass the live-PID check.
        stages.require('simulator-app-install', ['xcrun', 'simctl', 'install', device, str(app)], 120)
        text = stages.require('simulator-app-launch', ['xcrun', 'simctl', 'launch', '--terminate-running-process', device, bundle_id, '--qa-fixture'], 60)
        pid = launch_pid(text, bundle_id)
        stages.summary['pid'] = pid; stages.save()
        time.sleep(3)
        process = stages.require('simulator-app-process', ['ps', '-p', str(pid), '-o', 'pid=,stat=,comm='], 10)
        parts = process.strip().split(None, 2)
        if len(parts) != 3 or int(parts[0]) != pid or parts[1].startswith('Z') or Path(parts[2]).name != info['CFBundleExecutable']:
            raise RuntimeError('The fixture application did not remain alive after launch; inspect loader/crash logs')
        stages.summary.update(stage='ready', ready=True); stages.save()
        print('Fixture app launch gate passed with live PID', pid, flush=True)
        return 0
    except (Exception, KeyboardInterrupt) as error:
        stages.summary.update(error=str(error), ready=False); stages.save()
        print('Fixture app launch gate failed:', error, flush=True)
        return 1
    finally:
        if bundle_id and device:
            stages.run('simulator-app-terminate', ['xcrun', 'simctl', 'terminate', device, bundle_id], 10)
        reports = Path.home() / 'Library/Logs/DiagnosticReports'
        latest = sorted(reports.glob('AnimeSync*.ips'), key=lambda path: path.stat().st_mtime, reverse=True)[:2] if reports.exists() else []
        for index, path in enumerate(latest):
            (stages.output / ('simulator-app-crash-' + str(index) + '.ips')).write_bytes(path.read_bytes()[-128000:])


def collect(output):
    stages = Stages(output, 'simulator-collection-summary.json')
    try:
        selected = stages.output / 'simulator-id.txt'
        if selected.exists() and selected.read_text().strip():
            device = selected.read_text().strip()
            screenshot = stages.output / 'screenshots/final-simulator.png'
            screenshot.parent.mkdir(exist_ok=True)
            stages.run('simulator-final-screenshot', ['xcrun', 'simctl', 'io', device, 'screenshot', str(screenshot)], 15)
        stages.run('simulator-final-devices', ['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], 15, stdout_path=stages.output / 'simulator-devices-after.json')
        stages.run('simulator-process-list', ['ps', '-axo', 'pid,ppid,etime,stat,comm'], 10)
        log = Path.home() / 'Library/Logs/CoreSimulator/CoreSimulator.log'
        (stages.output / 'CoreSimulator-tail.log').write_bytes(log.read_bytes()[-64000:] if log.exists() else b'CoreSimulator.log was not present.\n')
        result = stages.output / 'AnimeSync-Tests.xcresult'
        if result.is_dir():
            attachments = stages.output / 'xcresult-attachments'; attachments.mkdir(exist_ok=True)
            stages.run('xcresult-export', ['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result), '--output-path', str(attachments)], 60)
            stages.run('xcresult-summary', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)], 30, stdout_path=stages.output / 'test-summary.json')
            stages.run('xcresult-tree', ['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(result)], 30, stdout_path=stages.output / 'test-tree.json')
    finally:
        stages.summary['stage'] = 'finished'; stages.save()
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', default='dist', type=Path)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument('--collect-only', action='store_true')
    actions.add_argument('--launch-app', type=Path)
    args = parser.parse_args()
    def stop(_signal, _frame):
        raise InterruptedError('Simulator stage interrupted')
    signal.signal(signal.SIGTERM, stop)
    if args.collect_only:
        return collect(args.output)
    if args.launch_app:
        return launch_app(args.output, args.launch_app)
    return prepare(args.output)

if __name__ == '__main__':
    raise SystemExit(main())
