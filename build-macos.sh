#!/usr/bin/env bash
# Builds the Mac Catalyst app on this machine, quits the running Amperfy,
# installs the new build to ~/Applications/Amperfy.app and launches it.
#
# Every build artifact lives in tmp/macos and is deleted when the script exits
# (success or failure), so each run is a clean build with no cache left behind.
# ./build runs this together with build-ios.sh (the OTA deploy).
#
# Usage: ./build-macos.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# xcode-select may point at the Command Line Tools; xcodebuild needs full Xcode.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_NAME="Amperfy"
WORK_DIR="$ROOT/tmp/macos"
DEST_DIR="$HOME/Applications"
DEST_APP="$DEST_DIR/$APP_NAME.app"

PRODUCT="$WORK_DIR/DerivedData/Build/Products/Release-maccatalyst/$APP_NAME.app"

# Before any xcodebuild call: on exit, whatever was created in Xcode's and
# SwiftPM's shared caches since this moment is deleted (IpaBuilder's
# clean_shared_caches!, the same cleanup ./deploy does).
AMPERFY_RUN_STARTED="$(date +%s)"
export AMPERFY_RUN_STARTED

cleanup() {
  echo "==> Removing build artifacts"
  rm -rf "$WORK_DIR"
  rmdir "$ROOT/tmp" 2>/dev/null || true
  # SwiftFormat is built by the "applyFormat" build phase into BuildTools/.build
  rm -rf "$ROOT/BuildTools/.build" "$ROOT/BuildTools/.swiftpm"
  ruby -e 'require ARGV[0]; IpaBuilder.clean_shared_caches!' "$ROOT/scripts/deploy/ipa_builder.rb" ||
    echo "warning: could not clean the shared Xcode/SwiftPM caches" >&2
}
trap cleanup EXIT

if [ ! -d "$DEVELOPER_DIR" ]; then
  echo "Xcode not found at $DEVELOPER_DIR (set DEVELOPER_DIR to override)" >&2
  exit 1
fi
if ! xcodebuild -checkFirstLaunchStatus; then
  echo "==> Running Xcode first-launch setup"
  xcodebuild -runFirstLaunch
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/tmp"
# xcodebuild and its tools write temp files to TMPDIR; keep them in the work dir.
export TMPDIR="$WORK_DIR/tmp"

echo "==> Building $APP_NAME (Mac Catalyst, Release, $(uname -m))"
xcodebuild \
  -project Amperfy.xcodeproj \
  -scheme Amperfy \
  -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$WORK_DIR/DerivedData" \
  -clonedSourcePackagesDirPath "$WORK_DIR/SourcePackages" \
  -packageCachePath "$WORK_DIR/PackageCache" \
  ARCHS="$(uname -m)" \
  ONLY_ACTIVE_ARCH=YES \
  COMPILER_INDEX_STORE_ENABLE=NO \
  DEBUG_INFORMATION_FORMAT=dwarf \
  CODE_SIGNING_ALLOWED=NO \
  AMPERFY_SKIP_SWIFTFORMAT=YES \
  -quiet \
  build

if [ ! -d "$PRODUCT" ]; then
  echo "Build finished but $PRODUCT is missing" >&2
  exit 1
fi

# The project signs with the upstream team and CarPlay/Siri entitlements, which need
# provisioning profiles we don't have. Sign ad hoc with only what the Mac app needs.
echo "==> Signing ad hoc"
ENTITLEMENTS="$WORK_DIR/adhoc.entitlements"
cat >"$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$PRODUCT"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$PRODUCT"
codesign --verify --deep --strict "$PRODUCT"

echo "==> Quitting running $APP_NAME"
if pgrep -x "$APP_NAME" >/dev/null; then
  pkill -x "$APP_NAME" || true
  for _ in $(seq 1 20); do
    pgrep -x "$APP_NAME" >/dev/null || break
    sleep 0.5
  done
  pkill -9 -x "$APP_NAME" 2>/dev/null || true
fi

echo "==> Installing to $DEST_APP"
mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP"
ditto "$PRODUCT" "$DEST_APP"

echo "==> Launching"
open "$DEST_APP"
