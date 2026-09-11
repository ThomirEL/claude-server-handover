#!/usr/bin/env bash
# handover-to-server — push this project to the home server and start Claude
# Code there in a detached tmux session, optionally already working on a prompt.
#
#   handover.sh ["prompt for the remote Claude"]
#   handover.sh --status [session]     is the remote session working, idle, or waiting on you?
#
# Config: ~/.claude/handover/server.env (machine) + <launch dir>/.handover.env
# (project; found by walking up from $PWD, or HANDOVER_PROJECT_CONFIG=path).
# Exit 2 = server not set up, exit 3 = project not set up → run /setup-server.
#
# Direction is Mac -> server (a push). Repo + HANDOVER_SYNC_PATHS: Mac is
# canonical. HANDOVER_GUARDED_FILES: backed up on the server first and never
# overwritten when the server copy is newer (HANDOVER_FORCE=1 overrides).
# Knobs: HANDOVER_ATTACH=1 attach at the end (humans only), HANDOVER_SKIP_SETUP=1.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$HERE/../setup-server/lib.sh"
PROMPT="$*"

load_server_config

# ---- --status: read the tmux pane and classify ------------------------------
if [ "${1:-}" = "--status" ]; then
  SESS="${2:-}"
  if [ -z "$SESS" ]; then load_project_config "$PWD"; SESS="$SESSION"; fi
  pane="$("${SSH[@]}" "$SERVER" "tmux capture-pane -t '$SESS' -p 2>/dev/null" || true)"
  [ -n "$pane" ] || die "no tmux session '$SESS' on $SERVER"
  tail="$(printf '%s\n' "$pane" | grep -v '^[[:space:]]*$' | tail -12)"
  waiting=0
  if printf '%s' "$tail" | grep -qE 'Enter to select|\(y/n\)|Do you want to|Allow .* to|❯ 1\.|Yes, and don.t ask again|Type something'; then
    waiting=1; printf '\033[1;33m⚠ WAITING FOR YOU\033[0m — session %s has a question or permission prompt:\n' "$SESS"
  elif printf '%s' "$tail" | grep -qE '^\s*❯\s*$'; then
    printf '\033[1;32m✔ IDLE\033[0m — session %s finished its turn (prompt is empty):\n' "$SESS"
  else
    printf '\033[1;34m▶ WORKING\033[0m — session %s is busy:\n' "$SESS"
  fi
  printf '%s\n' "$tail" | sed 's/^/    /'
  echo
  [ "$waiting" = 1 ] && echo "  Answer it:  ssh -t $SERVER 'tmux attach -t $SESS'   (or on your phone via the Remote Control URL above)"
  echo "  Attach:     ssh -t $SERVER 'tmux attach -t $SESS'"
  exit 0
fi

load_project_config "$PWD"
say "handover -> $SERVER   project: $LAUNCH_DIR   session: $SESSION"

"${SSH[@]}" "$SERVER" "mkdir -p '$REMOTE_REPO' '$REMOTE_LAUNCH' '$REMOTE_HOME/.claude/projects' '$REMOTE_HOME/.handover'"

say "code (repo + .git)…"
rsync -az "${EXCL[@]}" "$LOCAL_REPO/" "$SERVER:$REMOTE_REPO/"
# A fresh server usually has no git identity; without it the remote Claude's
# first commit fails and it stops to ask. Copy ours in, repo-local only.
if [ -d "$LOCAL_REPO/.git" ]; then
  gname="$(git -C "$LOCAL_REPO" config user.name || true)"; gmail="$(git -C "$LOCAL_REPO" config user.email || true)"
  if [ -n "$gname" ] && [ -n "$gmail" ]; then
    "${SSH[@]}" "$SERVER" "cd '$REMOTE_REPO' && git config user.email >/dev/null 2>&1 || { git config user.name '$gname'; git config user.email '$gmail'; echo '  ✓ git identity set (repo-local)'; }"
  fi
fi

for p in ${SYNC_PATHS[@]+"${SYNC_PATHS[@]}"}; do
  [ -e "$p" ] || { warn "$p missing locally — skipped"; continue; }
  say "sync ${p}…"
  if [ -d "$p" ]; then
    "${SSH[@]}" "$SERVER" "mkdir -p '$(remap "$p")'"
    rsync -az "${EXCL[@]}" "$p/" "$SERVER:$(remap "$p")/"
  else
    "${SSH[@]}" "$SERVER" "mkdir -p '$(dirname "$(remap "$p")")'"
    rsync -az "$p" "$SERVER:$(remap "$p")"
  fi
done

for f in ${GUARDED_FILES[@]+"${GUARDED_FILES[@]}"}; do say "guarded ${f}…"; guarded_push "$f" "$(remap "$f")"; done

# Claude context: global CLAUDE.md (opt-out) + this project's memory dir
if [ "${HANDOVER_SYNC_GLOBAL_CLAUDE_MD:-1}" = 1 ] && [ -f "$HOME/.claude/CLAUDE.md" ]; then
  rsync -az "$HOME/.claude/CLAUDE.md" "$SERVER:$REMOTE_HOME/.claude/CLAUDE.md" || true
fi
LOCAL_MEM="$HOME/.claude/projects/$(slug "$LAUNCH_DIR")/memory"
if [ -d "$LOCAL_MEM" ]; then
  say "Claude memory…"
  REMOTE_MEM_DIR="$REMOTE_HOME/.claude/projects/$(slug "$REMOTE_LAUNCH")"
  "${SSH[@]}" "$SERVER" "mkdir -p '$REMOTE_MEM_DIR'"
  rsync -az "$LOCAL_MEM" "$SERVER:$REMOTE_MEM_DIR/"
fi

if [ -n "$REMOTE_SETUP" ] && [ "${HANDOVER_SKIP_SETUP:-0}" != 1 ]; then
  say "remote setup: $REMOTE_SETUP"
  printf 'cd %q || exit 1\n%s\n' "$REMOTE_REPO" "$REMOTE_SETUP" | "${SSH[@]}" "$SERVER" "cat > '$REMOTE_HOME/.handover/$SESSION.setup.sh'"
  "${SSH[@]}" "$SERVER" "bash -lc 'bash \"\$HOME/.handover/$SESSION.setup.sh\"'" || warn "remote setup reported errors — finish it in the session"
fi

# Pre-accept the trust dialog for the launch dir in the chosen profile, otherwise a
# first launch stalls on "Is this a project you trust?" and the prompt never runs.
say "pre-accepting folder trust…"
"${SSH[@]}" "$SERVER" "python3 - '$WORK_PROFILE_DIR/.claude.json' '$REMOTE_LAUNCH'" <<'PY'
import json, os, sys
cfg, proj = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(cfg), exist_ok=True)
try: d = json.load(open(cfg))
except Exception: d = {}
e = d.setdefault("projects", {}).setdefault(proj, {})
if not e.get("hasTrustDialogAccepted"):
    e["hasTrustDialogAccepted"] = True
    json.dump(d, open(cfg, "w"), indent=2); print("  ✓ trust pre-accepted")
else: print("  ✓ already trusted")
PY

# Prompt goes through a file (no shell-quoting games); launcher bakes in paths + env.
say "launching Claude…"
RC="${HANDOVER_REMOTE_CONTROL:-1}"
if [ -n "$PROMPT" ] && [ "${HANDOVER_UNATTENDED_NOTE:-1}" = 1 ]; then
  PROMPT="You are running unattended on a remote server; the user handed this work over and is not watching. Make reasonable assumptions instead of stopping to ask. If something truly needs the user's decision, write it to HANDOVER-QUESTIONS.md in the project root and continue with everything that does not depend on it. Commit your work as you go.

TASK:
$PROMPT"
fi
printf '%s' "$PROMPT" | "${SSH[@]}" "$SERVER" "cat > '$REMOTE_HOME/.handover/$SESSION.prompt'"
{
  printf '#!/usr/bin/env bash\ncd %q || exit 1\nexport CLAUDE_CONFIG_DIR=%q\n' "$REMOTE_LAUNCH" "$WORK_PROFILE_DIR"
  for kv in ${REMOTE_ENV[@]+"${REMOTE_ENV[@]}"}; do
    k="${kv%%=*}"; v="${kv#*=}"; v="$(remap "$(expand_tilde "$v")")"
    printf 'export %s=%q\n' "$k" "$v"
  done
  printf 'ARGS=(%s)\n' "${HANDOVER_CLAUDE_ARGS:-}"
  [ "$RC" = 1 ] && printf 'ARGS+=(--remote-control %q)\n' "$SESSION"
  printf 'P="$HOME/.handover/%s.prompt"\nif [ -s "$P" ]; then exec claude "${ARGS[@]}" "$(cat "$P")"; else exec claude "${ARGS[@]}"; fi\n' "$SESSION"
} | "${SSH[@]}" "$SERVER" "cat > '$REMOTE_HOME/.handover/$SESSION.launch.sh'; chmod +x '$REMOTE_HOME/.handover/$SESSION.launch.sh'"

SESS="$("${SSH[@]}" "$SERVER" "
  s='$SESSION'; i=1
  while tmux has-session -t \"\$s\" 2>/dev/null; do i=\$((i+1)); s='$SESSION'-\$i; done
  tmux new-session -d -s \"\$s\" -x 220 -y 50 \"bash -lc '\$HOME/.handover/$SESSION.launch.sh'\"
  printf '%s' \"\$s\"
")"

echo
printf '\033[1;32m✔ Claude is running on %s in tmux session '\''%s'\''.\033[0m\n' "$SERVER" "$SESS"
[ -n "$PROMPT" ] && echo "  It has already started on your prompt."
echo "  Attach from your terminal:"
echo "      ssh -t $SERVER 'tmux attach -t $SESS'"
if [ "$RC" = 1 ]; then
  url=""
  for _ in $(seq 1 20); do
    url="$("${SSH[@]}" "$SERVER" "tmux capture-pane -t '$SESS' -p -S -200 2>/dev/null" | grep -oE 'https://claude\.ai/code/[A-Za-z0-9_-]+' | head -1 || true)"
    [ -n "$url" ] && break; sleep 1
  done
  if [ -n "$url" ]; then echo "  Or from your phone / browser (Remote Control):"; echo "      $url"
  else echo "  (Remote Control URL not visible yet — run: $0 --status $SESS)"; fi
fi
echo "  Check on it later:  $0 --status $SESS"
[ "${HANDOVER_ATTACH:-0}" = 1 ] && exec ssh -t "$SERVER" "tmux attach -t '$SESS'"
exit 0
