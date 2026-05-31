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
# run.sh always sets PERCH_DEBUG so /tmp/perch.log is verbose during
# the dev loop; a normal/brew launch sets nothing and stays quiet.
# `open` needs --env because the launched app doesn't inherit the
# shell environment.
open "./$APP" --env PERCH_DEBUG=1
echo "$APP launched. Grant Accessibility on first run."
