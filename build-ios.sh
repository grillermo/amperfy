#!/usr/bin/env bash
# Builds the iOS app ad hoc signed and publishes it over the air to files.chiq.me,
# where the install page (https://files.chiq.me/files/amperfy-install.html) and
# the app's "Install Latest" quick action always install the newest build.
#
# This script makes sure Xcode's iOS tooling is in place, then hands over to
# ./deploy, which bumps the version, builds, publishes, commits, tags and pushes
# to the fork. It runs on any Mac whose Xcode is signed in to the team and that
# has a file_server token (see scripts/deploy/README.md); ./build runs it
# together with build-macos.sh.
#
# Nothing is left on this Mac but the published files: the build lives in
# tmp/ios-ota and is deleted when ./deploy exits, success or failure.
#
# Usage: ./build-ios.sh [patch|minor|major|X.Y.Z] [--yes] [--summary "..."] [--note "..."]...
#        (every argument goes to ./deploy; see its header)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# Before any xcodebuild call: ./deploy deletes what was created in Xcode's and
# SwiftPM's shared caches since this moment (IpaBuilder.clean_up!).
AMPERFY_RUN_STARTED="$(date +%s)"
export AMPERFY_RUN_STARTED

# xcode-select may point at the Command Line Tools; xcodebuild needs full Xcode.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [ ! -d "$DEVELOPER_DIR" ]; then
  echo "Xcode not found at $DEVELOPER_DIR (install Xcode, or set DEVELOPER_DIR)" >&2
  exit 1
fi
if ! xcodebuild -checkFirstLaunchStatus; then
  echo "==> Running Xcode first-launch setup"
  xcodebuild -runFirstLaunch
fi
# Xcode ships without the iOS platform until it is downloaded once.
if ! xcodebuild -showsdks 2>/dev/null | grep -q -- '-sdk iphoneos'; then
  echo "==> Downloading the iOS platform for Xcode"
  xcodebuild -downloadPlatform iOS
fi

exec "$ROOT/deploy" "$@"
