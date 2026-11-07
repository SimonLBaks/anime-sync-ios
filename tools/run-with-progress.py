#!/usr/bin/env python3
"""Run one build command with heartbeat output and a bounded process-group lifetime."""
import argparse
import os
import signal
import subprocess
import sys
import time


def terminate_group(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    # The parent may exit before a compiler descendant; stop the whole owned group.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run(command, timeout, heartbeat):
    started = time.monotonic()
    # Inherit stdout so shell tee receives every compiler diagnostic immediately.
    process = subprocess.Popen(command, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        while True:
            remaining = timeout - (time.monotonic() - started)
            if remaining <= 0:
                print(f'Build timed out after {timeout:g}s; stopping compiler process group.', flush=True)
                terminate_group(process)
                return 124
            try:
                result = process.wait(timeout=min(heartbeat, remaining))
                print(f'Build command exited {result} after {time.monotonic() - started:.0f}s.', flush=True)
                return result if result >= 0 else 128 - result
            except subprocess.TimeoutExpired:
                if time.monotonic() - started < timeout:
                    print(f'Build still running after {time.monotonic() - started:.0f}s.', flush=True)
    except (KeyboardInterrupt, InterruptedError):
        print('Build interrupted; stopping compiler process group.', flush=True)
        terminate_group(process)
        return 130


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=float, required=True)
    parser.add_argument('--heartbeat', type=float, default=30)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if args.timeout <= 0 or args.heartbeat <= 0 or not command:
        parser.error('positive timeout/heartbeat and a build command are required')
    def stop(_signum, _frame):
        raise InterruptedError()
    signal.signal(signal.SIGTERM, stop)
    try:
        return run(command, args.timeout, args.heartbeat)
    except OSError as error:
        print('Could not start build command: ' + str(error), file=sys.stderr)
        return 127

if __name__ == '__main__':
    sys.exit(main())
