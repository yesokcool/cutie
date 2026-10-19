#!/bin/zsh
# Builds Cutie (Release) and installs it as /Applications/Cutie.app.
# A running copy is quit first; the new one is not launched.
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED="${TMPDIR:-/tmp}/cutie-release-dd"
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project cutie.xcodeproj -scheme "cutie RELEASE" -configuration Release \
  -derivedDataPath "$DERIVED" build -quiet
pkill -f "/Applications/Cutie.app/Contents/MacOS/Cutie" || true
rm -rf /Applications/Cutie.app
ditto "$DERIVED/Build/Products/Release/Cutie.app" /Applications/Cutie.app
echo "Installed /Applications/Cutie.app"
