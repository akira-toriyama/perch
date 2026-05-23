#!/bin/zsh
# Build + launch a perch .app bundle locally. Defaults to release
# (Perch.app, com.perch.perch) — the bundle you'd actually use day
# to day. ``--dev`` builds the parallel Perch-dev.app
# (com.perch.perch.dev) for verification alongside a Homebrew install
# without TCC grant collisions.
#
#   ./run.sh             release → Perch.app
#   ./run.sh --dev       dev     → Perch-dev.app
#
# Always kills any currently-running perch first (via stop.sh) so the
# new bundle takes over cleanly. Quit later: ``./stop.sh`` or
# ``perch --quit``.
set -e
cd "$(dirname "$0")"

MODE=""
APP="Perch.app"
if [[ "${1:-}" == "--dev" ]]; then
    MODE="--dev"
    APP="Perch-dev.app"
fi

./package.sh $MODE
./stop.sh
sleep 0.5
open "./$APP"
echo "$APP launched. Grant Accessibility on first run."
