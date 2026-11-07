#!/usr/bin/env python3
"""Create a fresh, scanned source export with no history or device evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
ROOT_FILES = {'.gitignore', 'Package.swift', 'README.md', 'THIRD_PARTY_NOTICES.md'}
DIRECTORIES = {'AnimeSync', 'Tests', 'tools', '.github', 'AnimeSync.xcodeproj'}
SKIP_PARTS = {'.git', '.private', '__pycache__', 'xcuserdata', 'DerivedData', 'dist', 'artifacts', '.build', '.swiftpm'}
TEXT_SUFFIXES = {'.swift', '.js', '.json', '.svg', '.plist', '.pbxproj', '.xcscheme', '.py', '.ps1', '.sh', '.yml', '.md', '.txt'}
BINARY_SUFFIXES = {'.png', '.ttf'}
PRIVATE_FILE = 'AnimeSync/Resources/Deployment.json'
SECRET_PATTERNS = [r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
                   r'\bgh[pousr]_[A-Za-z0-9]{30,}', r'\bgithub_pat_[A-Za-z0-9_]{30,}', r'\bsk-[A-Za-z0-9]{30,}']
PUBLIC_QA = '''# Validation

Run `python3 -m unittest discover -s tools -p 'test_*.py'` for build/export/profile checks.
On macOS, run `bash tools/test-simulator.sh` for the exact app-hosted unit and UI test selection.
`QA_FOCUS=fixtures` excludes the separately reported live public website check; it does not count that check as passed.
The result gate requires every selected test method, zero failures and zero skips.

Public CI uses disposable fixture preferences and fake transports. Personal accounts, device recordings and watch-history evidence are not included.
External providers can change or require human verification; confirm real playback separately on a device.
'''


def private_values(profile):
    if profile is None:
        return []
    from deployment_profile import validate
    value = validate(json.loads(Path(profile).read_text(encoding='utf-8')))
    from urllib.parse import urlsplit
    values = [value['homeURL'], value['tailnetURL'], value['defaultTVHost'],
              urlsplit(value['homeURL']).hostname, urlsplit(value['tailnetURL']).hostname]
    values += list(value['connectOverrides']) + list(value['connectOverrides'].values())
    return list({text for item in values if item for text in (item, item.replace('.', r'\.'))})


def candidates():
    for path in sorted(ROOT.rglob('*')):
        relative = path.relative_to(ROOT)
        if (not path.is_file() or path.is_symlink() or any(part in SKIP_PARTS for part in relative.parts)
                or relative.as_posix() == PRIVATE_FILE or path.name == 'app-icon.png'):
            continue
        if len(relative.parts) == 1:
            if path.name in ROOT_FILES:
                yield path
        elif relative.parts[0] in DIRECTORIES and path.suffix in TEXT_SUFFIXES | BINARY_SUFFIXES:
            yield path


def export(destination, profile=None):
    destination = Path(destination).resolve()
    if destination == ROOT or not destination.is_relative_to(ROOT / 'artifacts'):
        raise ValueError('Choose a new output directory under artifacts/')
    if destination.exists():
        raise ValueError('Choose a new empty output directory; existing files are never removed')
    values = private_values(profile)
    files = list(candidates())
    problems = []
    for path in files:
        if path.suffix in BINARY_SUFFIXES:
            continue
        text = path.read_text(encoding='utf-8')
        if any(re.search(pattern, text) for pattern in SECRET_PATTERNS):
            problems.append({'path': path.relative_to(ROOT).as_posix(), 'kind': 'credential pattern'})
        if any(value in text for value in values):
            problems.append({'path': path.relative_to(ROOT).as_posix(), 'kind': 'personal endpoint'})
    if problems:
        raise ValueError('Export stopped: ' + json.dumps(problems))
    destination.mkdir(parents=True)
    manifest = {}
    for path in files:
        relative = path.relative_to(ROOT)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        if path.suffix in {'.py', '.sh'}:
            target.chmod(0o755)
        manifest[relative.as_posix()] = hashlib.sha256(target.read_bytes()).hexdigest()
    (destination / 'QA.md').write_text(PUBLIC_QA, encoding='utf-8')
    manifest['QA.md'] = hashlib.sha256((destination / 'QA.md').read_bytes()).hexdigest()
    report = {'files': len(manifest), 'historyIncluded': False, 'personalProfileIncluded': False,
              'deviceEvidenceIncluded': False, 'credentialPatterns': 0, 'personalEndpointMatches': 0,
              'manifest': manifest}
    destination.with_suffix('.audit.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', required=True, type=Path)
    parser.add_argument('--private-profile', type=Path)
    args = parser.parse_args()
    try:
        result = export(args.destination, args.private_profile)
    except (ValueError, OSError, UnicodeError) as error:
        parser.exit(1, str(error) + '\n')
    print(json.dumps({key: value for key, value in result.items() if key != 'manifest'}, indent=2))


if __name__ == '__main__':
    main()
