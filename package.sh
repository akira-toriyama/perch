#!/bin/zsh
# Build a perch binary and assemble the .app bundle.
#
# Modes:
#   ./package.sh           RELEASE → Perch.app     / com.perch.perch
#   ./package.sh --dev     DEBUG   → Perch-dev.app / com.perch.perch.dev
#
# Why two flavors: dev (debug build, ran from the repo) and a
# co-installed brew release would otherwise share the same bundle id,
# so macOS would treat them as one app for TCC and the System
# Settings Accessibility list would show two indistinguishable
# "perch" entries. The dev variant gets its own bundle id + display
# name "perch (dev)" so each side keeps its own grant. The build
# profile also splits along the flag — release is what users
# actually run, debug is what you iterate on (faster swift build +
# verbose -O0 traces if you attach a debugger).
#
# The RELEASE bundle id is com.perch.perch — keep it stable across
# versions: macOS keys the Accessibility (TCC) grant + the
# self-signed cert to it.
#
# TCC: ad-hoc signing is not a stable identity → re-grant on every
# rebuild. Persist with a self-signed cert via
# ./setup-signing-cert.sh (writes .signing-id).
set -e
cd "$(dirname "$0")"

MODE="release"
PLIST="Info.plist"
APP="Perch.app"
BUILD_CFG="release"
BUILD_DIR=".build/release"
if [[ "${1:-}" == "--dev" ]]; then
  MODE="dev"; PLIST="Info.plist.dev"; APP="Perch-dev.app"
  BUILD_CFG="debug"; BUILD_DIR=".build/debug"
fi

if [[ "$BUILD_CFG" == "debug" ]]; then
  swift build
else
  swift build -c release
fi

# Clean up any prior bundle of either flavor before re-assembling.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PLIST" "$APP/Contents/Info.plist"
cp "$BUILD_DIR/perch" "$APP/Contents/MacOS/perch"   # = CFBundleExecutable

# Stamp the bundle's marketing version: the committed Info.plist value is
# only a fallback for a tag-less tarball build, and it said 1.0.0 while
# the tags stood at v4.0.0 — measured 2026-09-25, the v4.0.1 draft's
# Perch.zip carried 1.0.0. The tag this build is FOR arrives as
# RELEASE_TAG (glyph's release.yml states it on the build step): the
# draft's tag exists as a git ref only once a human publishes, so `git
# describe` in CI could only name the PREVIOUS release. Without
# RELEASE_TAG (a local build) `git describe` stamps v4.0.0-3-g1e77545 →
# 4.0.0-3-g1e77545; a clean tagged build is just 4.0.0.
VERSION="${RELEASE_TAG:-$(git describe --tags --dirty 2>/dev/null || true)}"
VERSION="${VERSION#v}"
if [[ -n "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi

# CFBundleIconFile = Perch (set in Info.plist) tells Launch Services
# to look for Perch.icns in Resources/. Committed binary lives in
# assets/; regenerate with scripts/make-icon.sh.
if [[ -f assets/Perch.icns ]]; then
  cp assets/Perch.icns "$APP/Contents/Resources/Perch.icns"
fi

# Identity precedence: $CODESIGN_ID > .signing-id file > ad-hoc ("-").
ID="${CODESIGN_ID:-}"
if [[ -z "$ID" && -f .signing-id ]]; then ID="$(cat .signing-id)"; fi
ID="${ID:--}"
codesign --force --sign "$ID" "$APP"

echo "built $APP  ($MODE, signed: $ID)"
echo "launch: open $APP   |   quit: pkill -f /Contents/MacOS/perch"
