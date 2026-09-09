#!/usr/bin/env bash
# Shared library for setup-server / handover-to-server / bring-home-from-server.
#
# Two config layers:
#   1. server config  ~/.claude/handover/server.env   (one per machine)
#        HANDOVER_SERVER            ssh target, e.g. you@100.x.y.z
#        HANDOVER_CLAUDE_CONFIG_DIR remote CLAUDE_CONFIG_DIR (default remote ~/.claude)
#        HANDOVER_SYNC_GLOBAL_CLAUDE_MD  push ~/.claude/CLAUDE.md too (default 1)
#   2. project config <launch dir>/.handover.env      (one per project)
#        HANDOVER_REPO          git repo to sync; "." = launch dir (default .)
#        HANDOVER_SYNC_PATHS    extra files/dirs to mirror (space-separated, ~ ok)
#        HANDOVER_GUARDED_FILES irreplaceable files: backup + never overwrite a newer copy
#        HANDOVER_SESSION       tmux session base name (default: launch dir basename)
#        HANDOVER_REMOTE_SETUP  command run in the remote repo before launch (optional)
#        HANDOVER_REMOTE_ENV    KEY=value pairs exported into the remote Claude session;
#                               values under ~ are remapped to the server's home
#        HANDOVER_EXCLUDES      extra rsync --exclude patterns (space-separated)
#
# Exit codes: 2 = no server config, 3 = no project config (callers/skills use these
# to trigger the setup flow).
set -euo pipefail

HANDOVER_HOME="${HANDOVER_HOME:-$HOME/.claude/handover}"
SERVER_ENV="$HANDOVER_HOME/server.env"
PROJECT_ENV_NAME=".handover.env"

say()  { printf '\033[1;34m%s\033[0m %s\n' "${SAY_MARK:-▶}" "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ⚠ %s\n' "$*"; }
die()  { printf '✗ %s\n' "$*" >&2; exit "${2:-1}"; }

slug() { python3 -c "import re,sys;print(re.sub(r'[^a-zA-Z0-9]','-',sys.argv[1]))" "$1"; }
expand_tilde() { case "$1" in "~"|"~/"*) printf '%s' "$HOME${1#\~}";; *) printf '%s' "$1";; esac; }
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
sha_local() { shasum -a 256 "$1" | awk '{print $1}'; }

# ---- server config ---------------------------------------------------------
load_server_config() {
  [ -f "$SERVER_ENV" ] || die "no server config at $SERVER_ENV — run /setup-server first" 2
  # shellcheck disable=SC1090
  . "$SERVER_ENV"
  [ -n "${HANDOVER_SERVER:-}" ] || die "HANDOVER_SERVER missing in $SERVER_ENV — run /setup-server" 2
  SERVER="$HANDOVER_SERVER"
  SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)
  REMOTE_HOME="$("${SSH[@]}" "$SERVER" 'echo $HOME' 2>/dev/null || true)"
  [ -n "$REMOTE_HOME" ] || die "cannot reach $SERVER over key-based SSH (try: ssh-copy-id $SERVER)"
  WORK_PROFILE_DIR="${HANDOVER_CLAUDE_CONFIG_DIR:-$REMOTE_HOME/.claude}"
  WORK_PROFILE_DIR="${WORK_PROFILE_DIR/#\~/$REMOTE_HOME}"
}

# local path -> server path (local $HOME -> remote $HOME)
remap() { printf '%s' "${1/#$HOME/$REMOTE_HOME}"; }

# ---- project config --------------------------------------------------------
# Finds .handover.env walking up from $1 (default $PWD). HANDOVER_PROJECT_CONFIG overrides.
find_project_config() {
  if [ -n "${HANDOVER_PROJECT_CONFIG:-}" ]; then
    [ -f "$HANDOVER_PROJECT_CONFIG" ] && { printf '%s' "$HANDOVER_PROJECT_CONFIG"; return 0; }
    return 1
  fi
  local d; d="$(cd "${1:-$PWD}" && pwd -P)"
  while :; do
    [ -f "$d/$PROJECT_ENV_NAME" ] && { printf '%s' "$d/$PROJECT_ENV_NAME"; return 0; }
    [ "$d" = "/" ] && return 1
    d="$(dirname "$d")"
  done
}

load_project_config() {
  local cfg
  cfg="$(find_project_config "${1:-$PWD}")" \
    || die "no $PROJECT_ENV_NAME found from ${1:-$PWD} upward — run /setup-server project (or setup-server.sh project --dir <launch dir>)" 3
  PROJECT_CONFIG="$cfg"
  LAUNCH_DIR="$(dirname "$cfg")"
  # shellcheck disable=SC1090
  . "$cfg"
  local repo="${HANDOVER_REPO:-.}"
  repo="$(expand_tilde "$repo")"
  case "$repo" in /*) LOCAL_REPO="$repo";; *) LOCAL_REPO="$(cd "$LAUNCH_DIR/$repo" && pwd -P)";; esac
  [ -d "$LOCAL_REPO" ] || die "HANDOVER_REPO '$LOCAL_REPO' does not exist"
  case "$LOCAL_REPO" in "$HOME"/*) ;; *) die "HANDOVER_REPO must live under \$HOME ($HOME) so it can be mirrored onto the server";; esac

  SESSION="${HANDOVER_SESSION:-$(basename "$LAUNCH_DIR" | tr -c 'a-zA-Z0-9\n' '-')}"
  SYNC_PATHS=(); GUARDED_FILES=(); REMOTE_ENV=(); EXCL=(--exclude node_modules --exclude .venv --exclude __pycache__ --exclude '*.pyc' --exclude .pytest_cache --exclude .DS_Store)
  local p
  for p in ${HANDOVER_SYNC_PATHS:-};    do SYNC_PATHS+=("$(expand_tilde "$p")"); done
  for p in ${HANDOVER_GUARDED_FILES:-}; do GUARDED_FILES+=("$(expand_tilde "$p")"); done
  for p in ${HANDOVER_REMOTE_ENV:-};    do REMOTE_ENV+=("$p"); done
  for p in ${HANDOVER_EXCLUDES:-};      do EXCL+=(--exclude "$p"); done
  REMOTE_SETUP="${HANDOVER_REMOTE_SETUP:-}"

  REMOTE_REPO="$(remap "$LOCAL_REPO")"
  REMOTE_LAUNCH="$(remap "$LAUNCH_DIR")"
}

# ---- guarded file transfer (both directions) -------------------------------
# guarded_push <local> <remote>   never overwrite a NEWER remote unless HANDOVER_FORCE=1
guarded_push() {
  local l="$1" r="$2" lm rm
  [ -f "$l" ] || { warn "$l not present locally — skipped"; return 0; }
  lm=$(mtime "$l"); rm=$("${SSH[@]}" "$SERVER" "stat -c %Y '$r' 2>/dev/null || echo 0")
  if [ "$rm" -gt "$lm" ] && [ "${HANDOVER_FORCE:-0}" != 1 ]; then
    warn "server copy of $(basename "$r") is NEWER — not overwriting (HANDOVER_FORCE=1 to override)"
    return 0
  fi
  "${SSH[@]}" "$SERVER" "mkdir -p '$(dirname "$r")'; [ -f '$r' ] && cp -a '$r' '$r.bak-'\$(date +%Y%m%d-%H%M%S) || true"
  rsync -az "$l" "$SERVER:$r"
  [ "$(sha_local "$l")" = "$("${SSH[@]}" "$SERVER" "sha256sum '$r' | cut -d' ' -f1")" ] \
    && ok "$(basename "$r") pushed, sha256 verified" || die "checksum mismatch for $r"
}

# guarded_pull <remote> <local>   never overwrite a NEWER local unless HANDOVER_FORCE=1
guarded_pull() {
  local r="$1" l="$2" lm rm
  "${SSH[@]}" "$SERVER" "[ -f '$r' ]" || { warn "$r not present on server — skipped"; return 0; }
  lm=$( [ -f "$l" ] && mtime "$l" || echo 0 ); rm=$("${SSH[@]}" "$SERVER" "stat -c %Y '$r'")
  if [ "$lm" -gt "$rm" ] && [ "${HANDOVER_FORCE:-0}" != 1 ]; then
    warn "local copy of $(basename "$l") is NEWER — not overwriting (HANDOVER_FORCE=1 to override)"
    return 0
  fi
  mkdir -p "$(dirname "$l")"
  [ -f "$l" ] && cp -a "$l" "$l.bak-$(date +%Y%m%d-%H%M%S)"
  rsync -az "$SERVER:$r" "$l"
  [ "$(sha_local "$l")" = "$("${SSH[@]}" "$SERVER" "sha256sum '$r' | cut -d' ' -f1")" ] \
    && ok "$(basename "$l") pulled, sha256 verified" || die "checksum mismatch for $l"
}
