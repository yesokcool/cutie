#!/bin/zsh
# Builds a Cutie anyone can download: signed with Developer ID, notarized by
# Apple and zipped, ready to attach to a GitHub release.
#
# Needs: your team and bundle id in Config/Local.xcconfig, and Xcode signed in
# to that team (Xcode ▸ Settings ▸ Accounts). Xcode creates the Developer ID
# certificate if there isn't one yet, and sends the app to Apple's notary
# service under that same sign-in, so no passwords are needed here.
#
# Prints the version and the path of the finished zip. Takes a few minutes,
# mostly waiting for Apple.
set -euo pipefail
cd "$(dirname "$0")/.."

XCODEBUILD=/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
WORK="${TMPDIR:-/tmp}/cutie-release"
ARCHIVE="$WORK/Cutie.xcarchive"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "Archiving…"
"$XCODEBUILD" -project cutie.xcodeproj -scheme "cutie RELEASE" -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates -quiet archive

cat > "$WORK/ExportOptions.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF

echo "Signing with Developer ID and sending to Apple for notarization…"
"$XCODEBUILD" -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$WORK/ExportOptions.plist" \
  -exportPath "$WORK/upload" -allowProvisioningUpdates

echo "Waiting for Apple (usually a few minutes)…"
for attempt in {1..60}; do
  if "$XCODEBUILD" -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$WORK/export" >"$WORK/notarized.log" 2>&1; then
    break
  fi
  if (( attempt == 60 )); then
    echo "Apple hasn't finished after 30 minutes. Last answer:" >&2
    cat "$WORK/notarized.log" >&2
    exit 1
  fi
  sleep 30
done

APP="$WORK/export/Cutie.app"
xcrun stapler validate "$APP" >/dev/null 2>&1 || xcrun stapler staple "$APP"
spctl --assess --type execute "$APP"

# Always named Cutie.zip, so releases/latest/download/Cutie.zip stays a working link.
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
ZIP="$WORK/Cutie.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Cutie $VERSION: $ZIP"
