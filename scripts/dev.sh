#!/bin/zsh
# Dev-loop one-liner: stop every running perch instance, rebuild,
# relaunch, then tail the log so events are visible while you
# iterate. The fastest way to "edit a Swift file, see the daemon
# pick it up" without thinking about which step you forgot.
#
# Modes:
#   ./scripts/dev.sh           release → Perch.app, then tail log
#                              (matches ./run.sh; same as the user
#                              flow but with the log tail attached)
#   ./scripts/dev.sh --debug   foreground PERCH_DEBUG=1 .build/debug/perch
#                              + tail log. Useful when you're
#                              iterating on Swift code and want the
#                              `[debug] ax: …` lines AND the daemon
#                              exits with the script (Ctrl-C kills
#                              both). (--debug here selects the debug
#                              build + foreground; it sets PERCH_DEBUG
#                              in the binary's env, it is not a binary
#                              flag.)
#                              If a persistent signing identity exists
#                              (`./setup-signing-cert.sh` was run
#                              earlier → .signing-id file present), the
#                              debug binary is re-signed with it after
#                              the build so the Accessibility (TCC)
#                              grant survives. Without that the
#                              symptom is `kAXErrorAPIDisabled` /
#                              "hints stopped appearing" after every
#                              rebuild.
#   ./scripts/dev.sh --no-tail just stop + rebuild + run (no tail).
#                              Pair with `tail -f /tmp/perch.log` in
#                              a separate pane.
#
# When the script terminates (you hit Ctrl-C on `tail`), it leaves
# the daemon running in the background — that matches how `./run.sh`
# behaves too. Quit explicitly with `./stop.sh` or `perch --quit`.
set -e
cd "$(dirname "$0")/.."

MODE="release"
TAIL=1
for arg in "$@"; do
    case "$arg" in
        --debug)   MODE="debug" ;;
        --no-tail) TAIL=0 ;;
        *)
            echo "dev.sh: unknown flag \"$arg\"" >&2
            echo "usage: ./scripts/dev.sh [--debug] [--no-tail]" >&2
            exit 2
            ;;
    esac
done

echo "[dev] stopping any running perch …"
./stop.sh

if [[ "$MODE" == "debug" ]]; then
    echo "[dev] swift build (debug) …"
    swift build
    # Sign the debug binary with the persistent identity if one is
    # available. Without this `swift build` ad-hoc re-signs every
    # invocation → TCC sees each build as a new app → Accessibility
    # grant is dropped → hints silently stop working (every AX call
    # returns kAXErrorAPIDisabled = -25211). Falling back to the
    # ad-hoc default preserves the historical behaviour for users
    # who haven't run ./setup-signing-cert.sh yet.
    if [[ -f .signing-id ]]; then
        ID="$(cat .signing-id)"
        codesign --force --sign "$ID" .build/debug/perch > /dev/null 2>&1
        echo "[dev] signed .build/debug/perch with: $ID"
    fi
    : > /tmp/perch.log   # truncate so the tail starts clean
    echo "[dev] launching PERCH_DEBUG=1 .build/debug/perch …"
    # Run in the background; Ctrl-C on `tail` won't kill it. The
    # PERCH_DEBUG=1 env var enables Log.debug.
    PERCH_DEBUG=1 .build/debug/perch > /dev/null 2>&1 &
    sleep 0.5
else
    echo "[dev] rebuilding Perch.app (release) …"
    : > /tmp/perch.log   # truncate so the tail starts clean
    ./run.sh > /dev/null
fi

if [[ "$TAIL" -eq 1 ]]; then
    echo "[dev] tailing /tmp/perch.log (Ctrl-C to detach; daemon keeps running) …"
    echo "---"
    exec tail -F /tmp/perch.log
else
    echo "[dev] running. Tail with: tail -F /tmp/perch.log"
fi
