#!/bin/zsh
# Build + launch a perch .app bundle locally. Single dev-loop entry
# point — only repo contributors run this; end users `brew install`
# the release.
#
#   ./run.sh                    DEBUG → Perch-dev.app, signed with
#                               the persistent identity, log tail
#                               attached. The everyday dev loop.
#                               (com.perch.perch.dev — TCC isolated
#                                from any brew-installed Perch.app)
#   ./run.sh --no-tail          same as above but skip the tail
#                               (use another pane: `tail -F /tmp/perch.log`)
#   ./run.sh --release          release → Perch.app, single launch,
#                               no tail. For pre-publish verification
#                               that the production bundle still
#                               works.
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

MODE_FLAG="--dev"         # → package.sh debug build, Perch-dev.app
APP="Perch-dev.app"
TAIL=1
for arg in "$@"; do
    case "$arg" in
        --release) MODE_FLAG=""; APP="Perch.app"; TAIL=0 ;;
        --no-tail) TAIL=0 ;;
        *)
            echo "run.sh: unknown flag \"$arg\"" >&2
            echo "usage: ./run.sh [--release] [--no-tail]" >&2
            exit 2
            ;;
    esac
done

./package.sh $MODE_FLAG
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
