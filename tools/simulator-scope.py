#!/usr/bin/env python3
"""Choose explicit simulator coverage and record every excluded external check."""
import argparse
import json
from pathlib import Path
import re

LIVE = 'testLiveMiruroCatalogueHeroAndSearchExtraction'
FEATURES = [
    'testNativeLibraryFiltersSearchAndReturn',
    'testPaneLabelsLogoOutsideIdleAndLandscapeReachability',
    'testEpisodeWindowTitlesRangesWatchedAndNamedMiruroSources',
    'testStandaloneMutedNativeFrameSubtitlesAndClose',
]


def scope(root, focus=''):
    if focus not in ('', 'full', 'features', 'fixtures'):
        raise ValueError('Unknown simulator test scope: ' + focus)
    all_ui = re.findall(r'func (test\w+)\(', (root / 'Tests/QAAcceptanceTests.swift').read_text())
    unit = [name for p in sorted((root / 'Tests').glob('*.swift')) if p.name != 'QAAcceptanceTests.swift'
            for name in re.findall(r'func (test\w+)\(', p.read_text())]
    if not unit or not all_ui or LIVE not in all_ui:
        raise ValueError('Expected app units, UI acceptance and separate live-provider case')
    selected = FEATURES if focus == 'features' else [name for name in all_ui if focus != 'fixtures' or name != LIVE]
    if not set(selected).issubset(all_ui) or not selected:
        raise ValueError('Required UI case is missing from the source')
    excluded = [name for name in all_ui if name not in selected]
    reason = ('Live Miruro requires external human verification on hosted CI; run separately on the physical iPhone. '
              'This case is not counted as passed by the fixture gate.') if focus == 'fixtures' else 'Explicit focused feature selection'
    return dict(focus=focus or 'full', unitMethods=unit, selectedUIMethods=selected,
                excludedUIMethods=[dict(method=name, reason=reason) for name in excluded])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--focus', default='')
    parser.add_argument('--output', type=Path, default=Path('dist'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    selected = scope(root, args.focus)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'test-scope.json').write_text(json.dumps(selected, indent=2) + '\n')
    targets = ['-only-testing:AnimeSyncTests'] + [
        '-only-testing:AnimeSyncUITests/QAAcceptanceTests/' + name for name in selected['selectedUIMethods']]
    (args.output / 'test-selection.txt').write_text('\n'.join(targets) + '\n')
    print(json.dumps({'scope': selected['focus'], 'units': len(selected['unitMethods']),
                      'ui': len(selected['selectedUIMethods']), 'excludedUI': selected['excludedUIMethods']}))


if __name__ == '__main__':
    main()
