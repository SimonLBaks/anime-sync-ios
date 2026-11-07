#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This device build requires macOS and Xcode.' >&2
  exit 1
fi
mkdir -p dist
rm -f dist/AnimeSync-for-local-signing.ipa dist/build-receipt.json dist/SHA256SUMS
revision="${CI_SOURCE_REVISION:-local}"
python3 tools/generate-project.py
python3 -m unittest discover -s tools -p 'test_*.py'
plutil -lint AnimeSync.xcodeproj/project.pbxproj AnimeSync/Info.plist
xcodebuild -version > dist/xcode-version.txt
python3 tools/swift-parse.py 2>&1 | tee dist/swift-parse.log
xcrun swift tools/RenderAppIcon.swift \
  AnimeSync/Resources/Assets.xcassets/anime-sync-logo.imageset/anime-sync-logo.png \
  AnimeSync/Resources/Assets.xcassets/AppIcon.appiconset/app-icon.png 2>&1 | tee dist/icon-render.log
python3 tools/validate_icon.py \
  --source AnimeSync/Resources/Assets.xcassets/anime-sync-logo.imageset/anime-sync-logo.png \
  --rendered AnimeSync/Resources/Assets.xcassets/AppIcon.appiconset/app-icon.png > dist/icon-render-validation.json
cp AnimeSync/Resources/Assets.xcassets/AppIcon.appiconset/app-icon.png dist/app-icon.png
python3 tools/run-with-progress.py --timeout 360 --heartbeat 30 -- \
  xcodebuild -project AnimeSync.xcodeproj -scheme AnimeSync \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath DerivedData/Device ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  "APP_SOURCE_REVISION=$revision" build 2>&1 | tee dist/xcodebuild-device.log
app='DerivedData/Device/Build/Products/Release-iphoneos/AnimeSync.app'
test -d "$app"
python3 tools/validate_icon.py \
  --source AnimeSync/Resources/Assets.xcassets/anime-sync-logo.imageset/anime-sync-logo.png \
  --rendered AnimeSync/Resources/Assets.xcassets/AppIcon.appiconset/app-icon.png \
  --app-bundle "$app" > dist/icon-packaged-validation.json
package_dir="$(mktemp -d "${TMPDIR:-/tmp}/anime-iphone-companion.XXXXXX")"
trap 'rm -rf "$package_dir"' EXIT
mkdir -p "$package_dir/Payload"
ditto "$app" "$package_dir/Payload/AnimeSync.app"
candidate="$package_dir/AnimeSync-candidate.ipa"
(cd "$package_dir" && ditto -c -k --keepParent Payload "$candidate")
python3 tools/validate_ipa.py "$candidate" --expected-revision "$revision" > dist/build-receipt.json
mv "$candidate" dist/AnimeSync-for-local-signing.ipa
(cd dist && shasum -a 256 AnimeSync-for-local-signing.ipa > SHA256SUMS)
python3 - <<'PY'
import hashlib, json
from pathlib import Path
paths = sorted(p for base in ['AnimeSync', 'Tests', 'tools', '.github', 'AnimeSync.xcodeproj'] for p in Path(base).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
Path('dist/source-manifest.json').write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}, indent=2) + '\n')
PY
cat dist/build-receipt.json
