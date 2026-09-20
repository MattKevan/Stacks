#!/usr/bin/env bash

set -Eeuo pipefail

# Update the headless Stacks server from git: pull, rebuild the `stacks`
# binary, install it, and restart its systemd unit.
#
# Idempotent — safe to run from cron/systemd-timer: when the built binary is
# byte-identical to the installed one the service is left alone unless
# --force is passed.
#
# Useful examples:
#   ./Scripts/update-server.sh --dry-run
#   UNIT=stacks-server REPO_DIR=~/stacks ./Scripts/update-server.sh
#   ./Scripts/update-server.sh --no-pull          # rebuild current checkout
#   ./Scripts/update-server.sh --force            # restart even if unchanged

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_DIR="${REPO_DIR:-$ROOT_DIR}"
BRANCH="${BRANCH:-}"
PRODUCT="${PRODUCT:-stacks}"
BIN_DEST="${BIN_DEST:-}"
UNIT="${UNIT:-stacks-server}"
PORT="${PORT:-}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-20}"
DRY_RUN=0
DO_PULL=1
DO_BUILD=1
DO_RESTART=1
DO_VERIFY=1
FORCE=0

die() {
  echo "error: $*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*"
}

# Echo the command instead of running it in --dry-run mode.
run() {
  if (( DRY_RUN )); then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

usage() {
  cat <<'EOF'
Usage: Scripts/update-server.sh [options]

Pulls the current branch, builds the `stacks` server binary, installs it, and
restarts the systemd unit that runs it.

Options:
  --dry-run       Print the steps without changing anything
  --no-pull       Skip the git pull (build the checkout as it stands)
  --no-build      Skip the build (install the existing binary)
  --no-restart    Skip the systemd restart
  --no-verify     Skip the post-restart HTTP check
  --force         Restart even when the installed binary is unchanged
  -h, --help      Show this help

Environment:
  REPO_DIR            Git checkout to update          (default: this repo)
  BRANCH              Branch to pull                  (default: current)
  PRODUCT             SwiftPM product name            (default: stacks)
  BIN_DEST            Install path for the binary     (default: the unit's
                      ExecStart path, else ~/.local/bin/stacks)
  UNIT                systemd unit to restart         (default: stacks-server)
  PORT                Port for the HTTP check         (default: the unit's
                      --port, else 18080)
  BUILD_CONFIGURATION SwiftPM configuration           (default: release)
  HEALTH_TIMEOUT      Seconds to wait for HTTP        (default: 20)
EOF
}

while (( $# )); do
  case "$1" in
    --dry-run)    DRY_RUN=1 ;;
    --no-pull)    DO_PULL=0 ;;
    --no-build)   DO_BUILD=0 ;;
    --no-restart) DO_RESTART=0 ;;
    --no-verify)  DO_VERIFY=0 ;;
    --force)      FORCE=1 ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

# Only the restart needs root; cat/is-active/show do not, so inspection never
# prompts for a password (matters for --dry-run).
SYSTEMCTL=(systemctl)
RESTART_CMD=(systemctl)
if (( $(id -u) != 0 )) && command -v sudo >/dev/null 2>&1; then
  RESTART_CMD=(sudo systemctl)
fi

unit_exists() {
  "${SYSTEMCTL[@]}" cat "$UNIT" >/dev/null 2>&1
}

# The binary the unit actually launches — installing anywhere else would
# leave the service running the old build.
unit_exec_path() {
  "${SYSTEMCTL[@]}" cat "$UNIT" 2>/dev/null \
    | sed -n 's/^ExecStart=[-@+!]*\([^ ]*\).*/\1/p' \
    | tail -n 1
}

unit_port() {
  "${SYSTEMCTL[@]}" cat "$UNIT" 2>/dev/null \
    | sed -n 's/.*[[:space:]]-p[[:space:]]*\([0-9]\{1,5\}\).*/\1/p; s/.*--port[= ]\{1,\}\([0-9]\{1,5\}\).*/\1/p' \
    | tail -n 1
}

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    cksum "$1"
  fi
}

[[ -d "$REPO_DIR/.git" ]] || die "not a git checkout: $REPO_DIR"
cd "$REPO_DIR"

# ---------------------------------------------------------------- pull ----

if (( DO_PULL )); then
  if [[ -z "$BRANCH" ]]; then
    BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    [[ "$BRANCH" != "HEAD" ]] || die "detached HEAD; set BRANCH=<name> to pull one"
  fi
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] \
    || die "uncommitted changes in $REPO_DIR; commit or stash them (or use --no-pull)"

  BEFORE="$(git rev-parse HEAD)"
  note "→ pulling $BRANCH in $REPO_DIR"
  run git fetch --prune
  run git pull --ff-only origin "$BRANCH"
  AFTER="$(git rev-parse HEAD)"
  if [[ "$BEFORE" == "$AFTER" ]]; then
    note "  already at $(git rev-parse --short HEAD) — no new commits"
  else
    note "  $(git rev-parse --short "$BEFORE") → $(git rev-parse --short "$AFTER")"
    run git --no-pager log --oneline "$BEFORE..$AFTER"
  fi
fi

# --------------------------------------------------------------- build ----

BIN_SRC="$REPO_DIR/.build/$BUILD_CONFIGURATION/$PRODUCT"

if (( DO_BUILD )); then
  # systemd and non-login ssh shells have a minimal PATH; swiftly installs
  # outside it, so add the usual location before giving up on `swift`.
  if ! command -v swift >/dev/null 2>&1; then
    if [[ -d "$HOME/.local/share/swiftly/bin" ]]; then
      PATH="$HOME/.local/share/swiftly/bin:$PATH"
    fi
    command -v swift >/dev/null 2>&1 \
      || die "swift not found; install a Swift 6 toolchain or fix PATH"
  fi
  note "→ building $PRODUCT ($BUILD_CONFIGURATION)"
  run swift build -c "$BUILD_CONFIGURATION" --product "$PRODUCT"
fi

[[ -x "$BIN_SRC" ]] || die "built binary missing: $BIN_SRC (drop --no-build?)"
(( DRY_RUN )) || BIN_SRC="$(readlink -f "$BIN_SRC")"

# ------------------------------------------------------------- install ----

HAS_UNIT=0
if unit_exists; then
  HAS_UNIT=1
fi

# BIN_DEST set in the environment wins; otherwise the unit's own ExecStart
# path is the only correct target (installing elsewhere would leave the
# service running the old build).
BIN_DEST_EXPLICIT=0
if [[ -n "$BIN_DEST" ]]; then
  BIN_DEST_EXPLICIT=1
elif (( HAS_UNIT )); then
  BIN_DEST="$(unit_exec_path)"
fi
[[ -n "$BIN_DEST" ]] || BIN_DEST="$HOME/.local/bin/$PRODUCT"

if (( HAS_UNIT )) && (( BIN_DEST_EXPLICIT )) && (( ! DRY_RUN )); then
  UNIT_BIN="$(unit_exec_path)"
  if [[ -n "$UNIT_BIN" && "$UNIT_BIN" != "$BIN_DEST" ]]; then
    note "  warning: $UNIT runs $UNIT_BIN; $BIN_DEST will not be the"
    note "  binary the service launches"
  fi
fi

if (( ! DRY_RUN )) && [[ -f "$BIN_DEST" ]] && (( ! FORCE )) \
   && [[ "$(checksum "$BIN_SRC")" == "$(checksum "$BIN_DEST")" ]]; then
  note "→ $BIN_DEST is already up to date — nothing to do"
  exit 0
fi

note "→ installing $BIN_SRC → $BIN_DEST"
run mkdir -p "$(dirname "$BIN_DEST")"
# Install to a sibling temp file and rename: overwriting a running binary in
# place fails with ETXTBSY, while rename swaps it atomically.
run install -m 755 "$BIN_SRC" "$BIN_DEST.tmp.$$"
run mv -f "$BIN_DEST.tmp.$$" "$BIN_DEST"

# ------------------------------------------------------------- restart ----

if (( ! DO_RESTART )); then
  note "→ skipping restart (--no-restart)"
  exit 0
fi

if (( ! HAS_UNIT )); then
  note "warning: systemd unit '$UNIT' not found — skipping restart"
  note "  (set UNIT=<name>, or create the unit per LINUX_SERVER.md)"
  exit 0
fi

note "→ restarting $UNIT"
run "${RESTART_CMD[@]}" restart "$UNIT"
if (( ! DRY_RUN )); then
  systemctl is-active --quiet "$UNIT" \
    || die "$UNIT failed to start; check: journalctl -u $UNIT -n 50"
  note "  $(systemctl is-active "$UNIT") — $(systemctl show -p ActiveEnterTimestamp --value "$UNIT")"
fi

# -------------------------------------------------------------- verify ----

if (( ! DO_VERIFY )); then
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  note "→ skipping HTTP check (curl not installed)"
  exit 0
fi

if [[ -z "$PORT" ]] && (( HAS_UNIT )); then
  PORT="$(unit_port)"
fi
PORT="${PORT:-18080}"

note "→ checking http://127.0.0.1:$PORT/api/identity"
if (( DRY_RUN )); then
  printf '  [dry-run] curl -s -o /dev/null -m 2 -w %%{http_code} http://127.0.0.1:%s/api/identity\n' "$PORT"
  exit 0
fi

# Any status counts as alive (401 when the share requires credentials);
# only a refused/timed-out connection means the server never came up.
CODE=""
for (( i = 0; i < HEALTH_TIMEOUT; i++ )); do
  CODE="$(curl -s -o /dev/null -m 2 -w '%{http_code}' \
    "http://127.0.0.1:$PORT/api/identity" || true)"
  [[ "$CODE" != "000" && -n "$CODE" ]] && break
  sleep 1
done

[[ "$CODE" != "000" && -n "$CODE" ]] \
  || die "no response on port $PORT after ${HEALTH_TIMEOUT}s; check: journalctl -u $UNIT -n 50"
note "  HTTP $CODE — server is up"
