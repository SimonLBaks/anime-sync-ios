#!/usr/bin/env python3
"""Choose explicit simulator coverage and record every excluded external check."""
import argparse
import json
from pathlib import Path
import re

LIVE = 'testLiveMiruroCatalogueHeroAndSearchExtraction'
FOCUSED_UNIT_CLASSES = {
    'library-resume': ('AppModelTests',),
    'connection-recovery': ('AppModelTests', 'NativePlaybackTests', 'NetworkRoutingTests', 'ProviderTests'),
    'episode-synopsis': ('AppModelTests',),
    'search-suggestions': ('AppModelTests',),
}
FEATURES = [
    'testNativeLibraryFiltersSearchAndReturn',
    'testPaneLabelsLogoOutsideIdleAndLandscapeReachability',
    'testPreviousPageEdgeBackUnwindsVisitedSections',
    'testHomeContinueBelowHeroThreePostersAndSeparateHistoryTen',
    'testEpisodeWindowTitlesRangesWatchedAndNamedMiruroSources',
    'testStandaloneMutedNativeFrameSubtitlesAndClose',
]


def scope(root, focus=''):
    if focus not in ('', 'full', 'features', 'fixtures', *FOCUSED_UNIT_CLASSES):
        raise ValueError('Unknown simulator test scope: ' + focus)
    all_ui = re.findall(r'func (test\w+)\(', (root / 'Tests/QAAcceptanceTests.swift').read_text())
    unit = [name for p in sorted((root / 'Tests').glob('*.swift')) if p.name != 'QAAcceptanceTests.swift'
            for name in re.findall(r'func (test\w+)\(', p.read_text())]
    if not unit or not all_ui or LIVE not in all_ui:
        raise ValueError('Expected app units, UI acceptance and separate live-provider case')
    if focus in FOCUSED_UNIT_CLASSES:
        return focused_unit_scope(root, focus, all_ui)
    selected = FEATURES if focus == 'features' else [name for name in all_ui if focus != 'fixtures' or name != LIVE]
    if not set(selected).issubset(all_ui) or not selected:
        raise ValueError('Required UI case is missing from the source')
    excluded = [name for name in all_ui if name not in selected]
    reason = ('Live Miruro requires external human verification on hosted CI; run separately on the physical iPhone. '
              'This case is not counted as passed by the fixture gate.') if focus == 'fixtures' else 'Explicit focused feature selection'
    return dict(focus=focus or 'full', unitMethods=unit, selectedUIMethods=selected,
                excludedUIMethods=[dict(method=name, reason=reason) for name in excluded])


def focused_unit_scope(root, focus, all_ui):
    classes = FOCUSED_UNIT_CLASSES[focus]
    ui = {
        'episode-synopsis': ['testEpisodeSynopsisScrollsInPortraitAndLandscape'],
        'search-suggestions': ['testLiveSearchSuggestionsAndViewAll'],
    }.get(focus, [])
    if not set(ui).issubset(all_ui):
        raise ValueError('Required UI case is missing from the source')
    methods = []
    for name in classes:
        source = root / 'Tests' / f'{name}.swift'
        # Some files contain several XCTestCase classes. Match the selected
        # class body so the manifest agrees with Xcode's class-level filter.
        case = re.search(rf'^(?:@MainActor\s+)?(?:final\s+)?class\s+{re.escape(name)}\s*:\s*XCTestCase\s*{{(.*?)^}}',
                         source.read_text(), re.MULTILINE | re.DOTALL)
        selected = re.findall(r'func (test\w+)\(', case.group(1)) if case else []
        if not selected:
            raise ValueError(f'Expected tests in {name} for {focus}')
        methods.extend(selected)
    reason = f'Focused {focus.replace("-", " ")} checks'
    return dict(focus=focus, unitClasses=list(classes), unitMethods=methods, selectedUIMethods=ui,
                excludedUIMethods=[dict(method=name, reason=reason) for name in all_ui if name not in ui])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--focus', default='')
    parser.add_argument('--output', type=Path, default=Path('dist'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    selected = scope(root, args.focus)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'test-scope.json').write_text(json.dumps(selected, indent=2) + '\n')
    if 'unitClasses' in selected:
        targets = [f'-only-testing:AnimeSyncTests/{name}' for name in selected['unitClasses']] + [
            '-only-testing:AnimeSyncUITests/QAAcceptanceTests/' + name for name in selected['selectedUIMethods']]
    else:
        targets = ['-only-testing:AnimeSyncTests'] + [
            '-only-testing:AnimeSyncUITests/QAAcceptanceTests/' + name for name in selected['selectedUIMethods']]
    (args.output / 'test-selection.txt').write_text('\n'.join(targets) + '\n')
    print(json.dumps({'scope': selected['focus'], 'units': len(selected['unitMethods']),
                      'ui': len(selected['selectedUIMethods']), 'excludedUI': selected['excludedUIMethods']}))


if __name__ == '__main__':
    main()
