#!/usr/bin/env bash
# setup-server — one-time configuration for the handover skills.
#
#   setup-server.sh server  --host user@host [--claude-config-dir ~/.claude]
#                           [--no-remote-control] [--claude-args "--permission-mode acceptEdits"]
#   setup-server.sh project [--dir <launch dir>] [--repo .] [--sync "p1 p2"]
#                           [--guarded "f1 f2"] [--session name] [--remote-setup "cmd"]
#                           [--remote-env "K=v K2=v2"] [--excludes "pat1 pat2"] [--force]
#   setup-server.sh status  [--dir <dir>]     show what would be used from here
#
# 'server' writes ~/.claude/handover/server.env and verifies ssh/tmux/claude.
# 'project' writes <launch dir>/.handover.env (refuses to overwrite without --force).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$HERE/lib.sh"

cmd="${1:-}"; shift || true
[ -n "$cmd" ] || { sed -n '2,12p' "$0"; exit 1; }

q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

case "$cmd" in
server)
  HOST=""; CFGDIR=""; RC=1; CARGS=""
  while [ $# -gt 0 ]; do case "$1" in
    --host) HOST="$2"; shift 2;; --claude-config-dir) CFGDIR="$2"; shift 2;;
    --no-remote-control) RC=0; shift;; --claude-args) CARGS="$2"; shift 2;;
    *) die "unknown flag $1";; esac; done
  [ -n "$HOST" ] || die "--host user@host is required"
  say "checking key-based ssh to ${HOST}…"
  rh="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" 'echo $HOME' 2>/dev/null || true)"
  [ -n "$rh" ] || die "cannot reach $HOST without a password. Run: ssh-copy-id $HOST   then retry"
  ok "ssh ok (remote home $rh)"
  for t in tmux rsync python3 claude; do
    if ssh -o BatchMode=yes "$HOST" "bash -lc 'command -v $t'" >/dev/null 2>&1; then ok "$t on server"
    else warn "$t NOT found on server (login shell) — install it before handing over"; fi
  done
  mkdir -p "$HANDOVER_HOME"
  {
    echo "# handover server config — written by setup-server $(date +%F)"
    echo "HANDOVER_SERVER=$(q "$HOST")"
    [ -n "$CFGDIR" ] && echo "HANDOVER_CLAUDE_CONFIG_DIR=$(q "$CFGDIR")" || echo "#HANDOVER_CLAUDE_CONFIG_DIR='~/.claude'"
    echo "HANDOVER_SYNC_GLOBAL_CLAUDE_MD=1"
    echo "# 1 = remote session starts with --remote-control: questions and permission prompts"
    echo "#     reach your phone / claude.ai/code instead of stalling in tmux."
    echo "HANDOVER_REMOTE_CONTROL=$RC"
    echo "# extra flags for the remote claude, e.g. '--permission-mode acceptEdits'"
    echo "HANDOVER_CLAUDE_ARGS=$(q "$CARGS")"
    echo "# 1 = prepend an 'you are running unattended' preamble to every handover prompt"
    echo "HANDOVER_UNATTENDED_NOTE=1"
  } > "$SERVER_ENV"
  ok "wrote $SERVER_ENV"
  ;;
project)
  DIR="$PWD"; REPO="."; SYNC=""; GUARDED=""; SESSION_NAME=""; RSETUP=""; RENV=""; EXCLUDES=""; FORCE=0
  while [ $# -gt 0 ]; do case "$1" in
    --dir) DIR="$2"; shift 2;; --repo) REPO="$2"; shift 2;; --sync) SYNC="$2"; shift 2;;
    --guarded) GUARDED="$2"; shift 2;; --session) SESSION_NAME="$2"; shift 2;;
    --remote-setup) RSETUP="$2"; shift 2;; --remote-env) RENV="$2"; shift 2;;
    --excludes) EXCLUDES="$2"; shift 2;; --force) FORCE=1; shift;;
    *) die "unknown flag $1";; esac; done
  DIR="$(cd "$(expand_tilde "$DIR")" && pwd -P)"
  case "$DIR" in "$HOME"/*) ;; *) die "launch dir must be under \$HOME";; esac
  cfg="$DIR/$PROJECT_ENV_NAME"
  [ -f "$cfg" ] && [ "$FORCE" != 1 ] && die "$cfg exists — use --force to overwrite"
  r="$(expand_tilde "$REPO")"; case "$r" in /*) ;; *) r="$DIR/$r";; esac
  [ -d "$r" ] || die "repo dir $r does not exist"
  [ -d "$r/.git" ] || warn "$r has no .git — it will still be mirrored, just without branches"
  for p in $SYNC $GUARDED; do [ -e "$(expand_tilde "$p")" ] || warn "$p does not exist locally (yet)"; done
  {
    echo "# handover project config — written by setup-server $(date +%F)"
    echo "# launch dir = the directory holding this file. Paths may use ~ ."
    echo "HANDOVER_REPO=$(q "$REPO")"
    echo "HANDOVER_SYNC_PATHS=$(q "$SYNC")"
    echo "HANDOVER_GUARDED_FILES=$(q "$GUARDED")"
    [ -n "$SESSION_NAME" ] && echo "HANDOVER_SESSION=$(q "$SESSION_NAME")" || echo "#HANDOVER_SESSION='name'   # default: launch dir basename"
    echo "HANDOVER_REMOTE_SETUP=$(q "$RSETUP")"
    echo "HANDOVER_REMOTE_ENV=$(q "$RENV")"
    echo "HANDOVER_EXCLUDES=$(q "$EXCLUDES")"
  } > "$cfg"
  ok "wrote $cfg"
  if [ -d "$r/.git" ] && ! git -C "$r" check-ignore -q "$cfg" 2>/dev/null && [ "$(git -C "$r" rev-parse --show-toplevel 2>/dev/null)" = "$DIR" ]; then
    warn "$PROJECT_ENV_NAME is inside the repo and not git-ignored — it holds local paths; consider adding it to .gitignore"
  fi
  ;;
status)
  DIR="$PWD"; while [ $# -gt 0 ]; do case "$1" in --dir) DIR="$2"; shift 2;; *) die "unknown flag $1";; esac; done
  if [ -f "$SERVER_ENV" ]; then ok "server config: $SERVER_ENV"; sed 's/^/      /' "$SERVER_ENV"; else warn "no server config ($SERVER_ENV) — run: setup-server.sh server --host user@host"; fi
  if cfg="$(find_project_config "$DIR")"; then ok "project config: $cfg"; sed 's/^/      /' "$cfg"; else warn "no $PROJECT_ENV_NAME from $DIR upward — run: setup-server.sh project --dir <launch dir> …"; fi
  ;;
*) die "unknown command $cmd (server|project|status)";;
esac
