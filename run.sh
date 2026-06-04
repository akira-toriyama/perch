#!/bin/zsh
# Build + launch a perch .app bundle locally. Single dev-loop entry
# point — same shape as facet's run.sh (one script, one flag).
#
#   ./run.sh                    release → Perch.app, background launch
#                               (com.perch.perch — the bundle a brew
#                                install would assemble)
#   ./run.sh --dev              DEBUG   → Perch-dev.app, signed with
#                               the persistent identity, with the log
#                               tail attached.
#                               com.perch.perch.dev keeps its own TCC
#                               grant alongside any brew-installed
#                               Perch.app — useful for "edit Swift,
#                               see daemon pick it up" iteration.
#   ./run.sh --dev --no-tail    same as --dev but skip the tail (use
#                               another pane: `tail -F /tmp/perch.log`)
#
# Always kills any currently-running perch first (via ./stop.sh) so
# the new bundle takes over cleanly. Quit later: ./stop.sh or
# `perch --quit`.
#
# PERCH_DEBUG=1 is set on the launched app so /tmp/perch.log stays
# verbose during the dev loop. A normal / brew launch sets nothing
# and stays quiet.
set -e
cd "$(dirname "$0")"

MODE=""
APP="Perch.app"
TAIL=0
for arg in "$@"; do
    case "$arg" in
        --dev)     MODE="--dev"; APP="Perch-dev.app"; TAIL=1 ;;
        --no-tail) TAIL=0 ;;
        *)
            echo "run.sh: unknown flag \"$arg\"" >&2
            echo "usage: ./run.sh [--dev] [--no-tail]" >&2
            exit 2
            ;;
    esac
done

./package.sh $MODE
./stop.sh
sleep 0.5
# Truncate the log only when tailing so the visible stream starts
# clean. Outside the dev loop we leave history in place.
if [[ "$TAIL" -eq 1 ]]; then : > /tmp/perch.log; fi

# `open` needs --env because the launched app doesn't inherit the
# shell environment.
open "./$APP" --env PERCH_DEBUG=1
echo "$APP launched. Grant Accessibility on first run."

if [[ "$TAIL" -eq 1 ]]; then
    echo "[dev] tailing /tmp/perch.log (Ctrl-C to detach; daemon keeps running) …"
    echo "---"
    exec tail -F /tmp/perch.log
fi
