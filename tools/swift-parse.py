#!/usr/bin/env python3
"""Fail Swift syntax quickly, before asset rendering or full Xcode type checking."""
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
paths = sorted([*root.glob('AnimeSync/**/*.swift'), *root.glob('Tests/**/*.swift')])
if not paths:
    raise SystemExit('No Swift sources found for syntax preflight')
print(f'Parsing {len(paths)} Swift app/test sources before the full build.', flush=True)
subprocess.run(['xcrun', 'swiftc', '-frontend', '-parse', '-swift-version', '5', '-D', 'DEBUG', *map(str, paths)], cwd=root, check=True)
