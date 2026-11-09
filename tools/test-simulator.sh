#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Simulator tests require macOS and Xcode.' >&2
  exit 1
fi
mkdir -p dist/screenshots dist/xcresult-attachments
# Always select explicit nonempty targets, including with macOS Bash3.2 nounset.
python3 tools/simulator-scope.py --focus "${QA_FOCUS:-}" --output dist
test_selection=()
while IFS= read -r target; do test_selection+=("$target"); done < dist/test-selection.txt
rm -rf dist/AnimeSync-Tests.xcresult
finish() {
  python3 tools/prepare-simulator.py --collect-only --output dist > dist/simulator-collection.log 2>&1 || true
}
trap finish EXIT
xcodebuild -version > dist/xcode-version.txt
python3 tools/generate-project.py
xcrun swift tools/RenderAppIcon.swift \
  AnimeSync/Resources/Assets.xcassets/anime-sync-logo.imageset/anime-sync-logo.png \
  AnimeSync/Resources/Assets.xcassets/AppIcon.appiconset/app-icon.png 2>&1 | tee dist/icon-render-simulator.log
python3 tools/prepare-simulator.py --output dist 2>&1 | tee dist/simulator-preparation.log
simulator_id="$(cat dist/simulator-id.txt)"
# WebKit bug293831 affects iOS18.5 simulator when targeting <=18.3.
# Apple's simulator-only workaround leaves the shipped device minimum at iOS17.
# https://bugs.webkit.org/show_bug.cgi?id=293831
simulator_arch="$(uname -m)"
simulator_minimum=17.0
simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"
if [[ "$simulator_sdk" == 18.5 ]]; then simulator_minimum=18.4; fi
SIMULATOR_ARCH="$simulator_arch" SIMULATOR_MINIMUM="$simulator_minimum" SIMULATOR_SDK="$simulator_sdk" python3 - <<'PY'
import json, os
from pathlib import Path
Path('dist/simulator-build-context.json').write_text(json.dumps({
    'architecture': os.environ['SIMULATOR_ARCH'],
    'minimumOS': os.environ['SIMULATOR_MINIMUM'],
    'sdk': os.environ['SIMULATOR_SDK'],
    'deviceMinimumOS': '17.0',
    'workaround': 'WebKit293831' if os.environ['SIMULATOR_MINIMUM'] == '18.4' else None
}, indent=2) + '\n')
PY
python3 tools/run-with-progress.py --timeout 720 --heartbeat 30 -- \
  xcodebuild -project AnimeSync.xcodeproj -scheme AnimeSync \
  -configuration Debug -sdk iphonesimulator -destination "platform=iOS Simulator,id=$simulator_id" \
  -destination-timeout 60 -derivedDataPath DerivedData/Simulator \
  ONLY_ACTIVE_ARCH=YES "ARCHS=$simulator_arch" "IPHONEOS_DEPLOYMENT_TARGET=$simulator_minimum" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  "APP_SOURCE_REVISION=${CI_SOURCE_REVISION:-local}" build-for-testing 2>&1 | tee dist/xcodebuild-simulator-build.log
python3 tools/prepare-simulator.py --output dist \
  --launch-app DerivedData/Simulator/Build/Products/Debug-iphonesimulator/AnimeSync.app \
  2>&1 | tee dist/simulator-app-launch.log
xcodebuild -project AnimeSync.xcodeproj -scheme AnimeSync \
  -configuration Debug -sdk iphonesimulator -destination "platform=iOS Simulator,id=$simulator_id" \
  -destination-timeout 60 -derivedDataPath DerivedData/Simulator \
  -resultBundlePath dist/AnimeSync-Tests.xcresult \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 300 \
  ONLY_ACTIVE_ARCH=YES "ARCHS=$simulator_arch" "IPHONEOS_DEPLOYMENT_TARGET=$simulator_minimum" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  "APP_SOURCE_REVISION=${CI_SOURCE_REVISION:-local}" "${test_selection[@]}" test-without-building 2>&1 | tee dist/xcodebuild-simulator.log
python3 tools/prepare-simulator.py --collect-only --output dist > dist/simulator-collection.log 2>&1
trap - EXIT
python3 - <<'PY'
import json
from pathlib import Path
summary = json.loads(Path('dist/test-summary.json').read_text())
if summary.get('failedTests') != 0 or summary.get('skippedTests') != 0 or summary.get('passedTests', 0) <= 0:
    raise SystemExit('Required simulator tests did not all pass, or the result summary is unsupported')
tree = Path('dist/test-tree.json').read_text()
scope = json.loads(Path('dist/test-scope.json').read_text())
if scope['focus'] == 'library-resume' and 'AppModelTests' not in tree:
    raise SystemExit('The result bundle must include the focused app model tests')
if scope['focus'] != 'library-resume' and not all(name in tree for name in ['ProtocolTests', 'QAAcceptanceTests']):
    raise SystemExit('The result bundle must include both protocol and native UI acceptance suites')
required = scope['unitMethods'] + scope['selectedUIMethods']
if summary.get('passedTests') != len(required) or not all(name in tree for name in required):
    raise SystemExit('The run must pass every required unit method and selected UI case')
PY
