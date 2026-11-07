#!/usr/bin/env python3
"""Validate this full companion's unsigned arm64 device IPA before local signing."""
import argparse
import hashlib
import json
import plistlib
import struct
import zipfile
from pathlib import Path

ROBOTO_SHA256 = '070615f757a610d4042a0330402f7df76d9627f1b857ebfbfb76e00a5b00d865'
ROBOTO_LICENSE_SHA256 = '061402327a96aadb0bfb694a960ed289ecd38d383e396243831ab81feb109c41'


def device_binary(data):
    if len(data) < 32:
        raise ValueError('Missing Mach-O executable header')
    magic, cpu, _, kind, count, size, _, _ = struct.unpack_from('<8I', data)
    if magic != 0xfeedfacf or cpu != 0x0100000c or kind != 2:
        raise ValueError('Expected a thin arm64 Mach-O executable')
    if size > len(data) - 32 or count > size // 8:
        raise ValueError('Invalid Mach-O load command table')
    offset, platform = 32, None
    for _ in range(count):
        command, length = struct.unpack_from('<II', data, offset)
        if length < 8 or offset + length > 32 + size:
            raise ValueError('Invalid Mach-O load command')
        if command == 0x32:
            if length < 24:
                raise ValueError('Missing LC_BUILD_VERSION payload')
            platform = struct.unpack_from('<I', data, offset + 8)[0]
        offset += length
    if platform != 2:
        raise ValueError('Expected the iOS device platform (2); simulator builds cannot install on iPhone')
    return {'architecture': 'arm64', 'platform': 'iOS device', 'machOPlatform': platform}


def validate(path, expected_revision=None):
    prefix = 'Payload/AnimeSync.app/'
    resources = ['provider.js', 'resource-observer.js', 'dashboard.js', 'tv-navigation.js', 'Assets.car', 'Roboto-Bold.ttf', 'Roboto-LICENSE.txt', 'Roboto-source.json']
    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())
        if any(name.rsplit('/', 1)[-1].casefold() == 'deployment.json' for name in names):
            raise ValueError('A public build artifact must not contain a private deployment profile')
        info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        if info.get('CFBundlePackageType') != 'APPL' or info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
            raise ValueError('Expected an iPhoneOS application bundle')
        if info.get('CFBundleIdentifier') != 'xyz.loibaks.animecompanion.ios':
            raise ValueError('Unexpected full companion application bundle identifier')
        if expected_revision is not None and info.get('BuildSourceRevision') != expected_revision:
            raise ValueError('Source revision does not match the requested build')
        minimum = str(info.get('MinimumOSVersion', ''))
        if minimum not in ['17.0', '17.0.0']:
            raise ValueError('Expected iOS17.0 minimum deployment target')
        executable = info.get('CFBundleExecutable')
        if executable != 'AnimeSync':
            raise ValueError('Unexpected executable filename')
        result = device_binary(archive.read(prefix + executable))
        if prefix + 'embedded.mobileprovision' in names:
            raise ValueError('The unsigned artifact must not embed an Apple provisioning profile')
        for resource in resources:
            if prefix + resource not in names or len(archive.read(prefix + resource)) == 0:
                raise ValueError('Missing required app resource: ' + resource)
        if info.get('UIAppFonts') != ['Roboto-Bold.ttf']:
            raise ValueError('The shared subtitle font is not registered in UIAppFonts')
        font_hash = hashlib.sha256(archive.read(prefix + 'Roboto-Bold.ttf')).hexdigest()
        license_hash = hashlib.sha256(archive.read(prefix + 'Roboto-LICENSE.txt')).hexdigest()
        if font_hash != ROBOTO_SHA256 or license_hash != ROBOTO_LICENSE_SHA256:
            raise ValueError('The packaged shared subtitle font or license does not match its pinned source')
        provenance = json.loads(archive.read(prefix + 'Roboto-source.json'))
        if provenance.get('fontSHA256') != font_hash or provenance.get('licenseSHA256') != license_hash or provenance.get('postScriptName') != 'Roboto-Bold':
            raise ValueError('The subtitle font provenance does not match the packaged font')
        result.update(bundleId=info['CFBundleIdentifier'], minimumOS=minimum, version=info.get('CFBundleShortVersionString'), sourceRevision=info.get('BuildSourceRevision', 'unknown'), resources=resources)
        result['subtitleFont'] = {'postScriptName': 'Roboto-Bold', 'sha256': font_hash, 'licenseSHA256': license_hash}
    result.update(sha256=hashlib.sha256(Path(path).read_bytes()).hexdigest(), requiresLocalSigning=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('ipa', type=Path); parser.add_argument('--expected-revision'); args = parser.parse_args()
    print(json.dumps(validate(args.ipa, args.expected_revision), indent=2))

if __name__ == '__main__':
    main()
