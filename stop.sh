#!/bin/zsh
# Kill every running perch instance — release bundle, dev bundle, or
# raw SwiftPM binary. Use when you've lost track of which one is up
# (first-run debugging or verification sessions often pile up). Safe
# to run when nothing is running (no-op + "(none running)").
#
#   ./stop.sh

set -e
cd "$(dirname "$0")"

pkill -f '/Contents/MacOS/perch' 2>/dev/null || true
pkill -f '\.build/.*/perch'      2>/dev/null || true

# Confirmation pass: anything still alive?
remaining="$(ps aux \
    | grep -E '/Contents/MacOS/perch|\.build/.*/perch' \
    | grep -v grep || true)"
if [[ -n "$remaining" ]]; then
    echo "warning: some perch instances survived:" >&2
    echo "$remaining" >&2
    exit 1
fi
echo "killed: all perch instances"
