#!/usr/bin/env python3
"""Apply a private endpoint profile locally to a validated unsigned public IPA."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import zipfile

from deployment_profile import validate

spec = importlib.util.spec_from_file_location('public_ipa_validator', Path(__file__).with_name('validate_ipa.py'))
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
PROFILE_PATH = 'Payload/AnimeSync.app/Deployment.json'


def personalize(source, profile, destination, expected_revision=None):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('Use a separate output path for the personalized IPA')
    receipt = validator.validate(source, expected_revision)
    checked = validate(profile)
    data = (json.dumps(checked, sort_keys=True, separators=(',', ':')) + '\n').encode('utf-8')
    destination.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix='.personalized-', suffix='.ipa', dir=destination.parent)
    os.close(handle)
    temporary = Path(temporary)
    try:
        with zipfile.ZipFile(source) as original, zipfile.ZipFile(temporary, 'w') as output:
            names = set()
            for entry in original.infolist():
                parts = Path(entry.filename).parts
                if (entry.filename in names or entry.filename.startswith('/') or '..' in parts
                        or '\\' in entry.filename or stat.S_ISLNK(entry.external_attr >> 16)):
                    raise ValueError('Unexpected duplicate or unsafe archive entry')
                names.add(entry.filename)
                output.writestr(entry, original.read(entry.filename))
            if PROFILE_PATH in names:
                raise ValueError('Input IPA already contains a deployment profile')
            output.writestr(PROFILE_PATH, data, compress_type=zipfile.ZIP_DEFLATED)
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return {'version': receipt['version'], 'sourceRevision': receipt['sourceRevision'],
            'publicInputSHA256': receipt['sha256'], 'personalizedSHA256': hashlib.sha256(destination.read_bytes()).hexdigest(),
            'localPersonalization': True, 'requiresLocalSigning': True, 'publicUploadAllowed': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True, type=Path)
    parser.add_argument('--profile', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--expected-revision')
    args = parser.parse_args()
    try:
        profile = json.loads(args.profile.read_text(encoding='utf-8'))
        receipt = personalize(args.input, profile, args.output, args.expected_revision)
    except (ValueError, KeyError, OSError, zipfile.BadZipFile):
        parser.exit(1, 'Personalization failed: check the unsigned artifact and the documented endpoint profile format. No profile values were logged.\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
