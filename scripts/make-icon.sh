#!/bin/zsh
# Generate assets/Perch.icns from the Swift renderer + macOS iconutil.
# Idempotent — re-run after any edit to make-icon.swift and the
# committed .icns updates.
set -euo pipefail

cd "$(dirname "$0")/.."

tmp=".icon-build"
rm -rf "$tmp"
mkdir -p "$tmp"
pushd "$tmp" > /dev/null

swift ../scripts/make-icon.swift
iconutil -c icns Perch.iconset -o Perch.icns

popd > /dev/null
mkdir -p assets
mv "$tmp/Perch.icns" assets/Perch.icns
rm -rf "$tmp"

echo "wrote assets/Perch.icns ($(stat -f%z assets/Perch.icns) bytes)"
