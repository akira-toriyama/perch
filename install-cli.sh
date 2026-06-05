#!/bin/zsh
# Put a `perch` command on your PATH. perch then acts as a thin
# client for the running daemon: `perch --activate` / `--scroll` /
# `--search` / `--menu` / `--windows` / `--emoji` / `--regional` /
# `--grid` / `--rgrid` / `--nudge` / `--drag` / `--vision` /
# `--cancel` / `--reload` / `--quit` / `--status` post a
# distributed notification (or read /tmp/perch.status) and exit.
# Standalone subcommands (`--validate` / `--doctor` / `--dump-ax*`)
# work too — they don't need a running daemon.
#
# Launch the daemon via run.sh or `open Perch.app`.
#
#   ./install-cli.sh [--dry-run] [--silent]
#   --dry-run  print what would be linked, change nothing
#   --silent   don't tee output to /tmp/install-cli.log (tee on by default)
#
# Prefers `Perch.app` (release) if it exists, falls back to
# `Perch-dev.app` (the dev bundle ./run.sh produces). Both share
# the same client binary — IPC routes to whichever daemon is
# running via DNC, so either link works for client commands.
set -e
cd "$(dirname "$0")"

DRY_RUN=0; SILENT=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --silent)  SILENT=1 ;;
    -h|--help) echo "usage: $0 [--dry-run] [--silent]"; exit 0 ;;
    *) echo "install-cli: unknown option \"$arg\" (try --dry-run / --silent)" >&2; exit 2 ;;
  esac
done
if (( ! SILENT )); then exec > >(tee "/tmp/install-cli.log") 2>&1; fi

# Prefer the dev bundle (./run.sh's default — the everyday dev
# loop), fall back to release. Opposite preference from facet's
# install-cli.sh because perch's run.sh defaults to dev too;
# matching that here means `./run.sh && ./install-cli.sh` Just
# Works without a re-link after every dev rebuild.
if [[ -x "$PWD/Perch-dev.app/Contents/MacOS/perch" ]]; then
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
echo "  perch --validate / --doctor / --status     diagnostics"
echo "  perch --activate / --cancel                hint mode (client)"
echo "  perch --scroll / --search / --menu / --windows / --emoji"
echo "  perch --regional / --grid / --rgrid / --nudge / --drag / --vision"
echo "  perch --reload / --quit"
