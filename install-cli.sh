#!/bin/zsh
# Put a `perch` command on your PATH. perch then acts as a thin
# client for the running daemon: `perch overlay --activate` / --scroll /
# --search / --menu / --windows / --emoji / --regional / --grid /
# --rgrid / --nudge / --drag / --vision / --cancel and
# `perch daemon --reload` / --quit / --show post a distributed
# notification (or read /tmp/perch.status) and exit.
# Standalone subcommands (`perch config --validate` / --doctor and
# `perch ax --dump` / --tree / --regions) work too — they don't need a
# running daemon.
#
# Launch the daemon via run.sh or `open Perch.app`.
#
#   ./install-cli.sh [--dry-run] [--silent] [--app=<Name>.app]
#   --dry-run     print what would be linked, change nothing
#   --silent      don't tee output to /tmp/install-cli.log (tee on by default)
#   --app=<Name>  link this specific bundle instead of auto-detecting
#                 (run.sh passes the bundle it just built, so the link
#                  always tracks the freshest build).
#
# Without --app, prefers the dev bundle `Perch-dev.app` (./run.sh's
# default — the everyday dev loop), falling back to release `Perch.app`.
# Both share the same client binary — IPC routes to whichever daemon is
# running via DNC, so either link works for client commands.
set -e
cd "$(dirname "$0")"

DRY_RUN=0; SILENT=0; APP_OVERRIDE=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --silent)  SILENT=1 ;;
    --app=*)   APP_OVERRIDE="${arg#--app=}" ;;
    -h|--help) echo "usage: $0 [--dry-run] [--silent] [--app=<Name>.app]"; exit 0 ;;
    *) echo "install-cli: unknown option \"$arg\" (try --dry-run / --silent / --app=<Name>.app)" >&2; exit 2 ;;
  esac
done
if (( ! SILENT )); then exec > >(tee "/tmp/install-cli.log") 2>&1; fi

# Pick the bundle to link. An explicit --app (run.sh passes the one it
# just built) wins; otherwise prefer the dev bundle, then release.
# Dev-first auto-detect (opposite of facet's) matches perch's run.sh
# default so `./run.sh && ./install-cli.sh` Just Works with no re-link.
if [[ -n "$APP_OVERRIDE" ]]; then
  if [[ -x "$PWD/$APP_OVERRIDE/Contents/MacOS/perch" ]]; then
    BIN="$PWD/$APP_OVERRIDE/Contents/MacOS/perch"
    APP="$APP_OVERRIDE"
  else
    echo "install-cli: --app=$APP_OVERRIDE not built at $PWD/$APP_OVERRIDE"
    exit 1
  fi
elif [[ -x "$PWD/Perch-dev.app/Contents/MacOS/perch" ]]; then
  BIN="$PWD/Perch-dev.app/Contents/MacOS/perch"
  APP="Perch-dev.app"
elif [[ -x "$PWD/Perch.app/Contents/MacOS/perch" ]]; then
  BIN="$PWD/Perch.app/Contents/MacOS/perch"
  APP="Perch.app"
else
  echo "build first: ./run.sh (dev) or ./run.sh --release"
  exit 1
fi

# Prefer a dir already on PATH and writable (no dotfile changes):
# Homebrew bin (Apple Silicon, user-owned) → /usr/local/bin → ~/.local/bin.
if [[ -w /opt/homebrew/bin ]]; then
  DIR=/opt/homebrew/bin
elif [[ -w /usr/local/bin ]]; then
  DIR=/usr/local/bin
else
  DIR="$HOME/.local/bin"
fi

if (( DRY_RUN )); then
  echo "[dry-run] would ensure dir exists: $DIR"
  echo "[dry-run] would link: $DIR/perch -> $BIN"
  exit 0
fi

[[ -d "$DIR" ]] || mkdir -p "$DIR"
ln -sf "$BIN" "$DIR/perch"
echo "linked: $DIR/perch -> $BIN ($APP)"
case ":$PATH:" in
  *":$DIR:"*) : ;;
  *) echo "note: add $DIR to PATH (e.g. in ~/.zshrc)";;
esac
echo "usage:"
echo "  perch config --validate / --doctor              diagnostics"
echo "  perch daemon --show / --reload / --quit         daemon lifecycle"
echo "  perch overlay --activate / --cancel             hint mode (client)"
echo "  perch overlay --scroll / --search / --menu / --windows / --emoji"
echo "  perch overlay --regional / --grid / --rgrid / --nudge / --drag / --vision"
