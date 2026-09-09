#!/usr/bin/env bash
# bring-home-from-server — the reverse of handover-to-server. Pulls the project
# back from the home server: repo (+ .git, so server branches travel),
# HANDOVER_SYNC_PATHS, HANDOVER_GUARDED_FILES, Claude memory and the newest
# server session transcript so you can `claude --resume` locally.
#
#   bring-home.sh
#
# Same config files as handover.sh. Server is canonical on the pull (no
# --delete). Guarded files: local backed up first, never overwritten when the
# LOCAL copy is newer (HANDOVER_FORCE=1 overrides). BRINGHOME_SKIP_GUARDED=1
# leaves them alone. BRINGHOME_DEST_PREFIX=/dir writes under a scratch prefix.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SAY_MARK="◀"
. "$HERE/../setup-server/lib.sh"
DEST="${BRINGHOME_DEST_PREFIX:-}"

load_server_config
load_project_config "$PWD"
say "bring-home <- $SERVER   project: $LAUNCH_DIR   into ${DEST:-real local paths}"

say "code (repo + .git)…"
mkdir -p "$DEST$LOCAL_REPO"
rsync -az "${EXCL[@]}" "$SERVER:$REMOTE_REPO/" "$DEST$LOCAL_REPO/"

for p in "${SYNC_PATHS[@]}"; do
  r="$(remap "$p")"
  "${SSH[@]}" "$SERVER" "[ -e '$r' ]" || { warn "$r not on server — skipped"; continue; }
  say "sync $p…"
  if "${SSH[@]}" "$SERVER" "[ -d '$r' ]"; then mkdir -p "$DEST$p"; rsync -az "${EXCL[@]}" "$SERVER:$r/" "$DEST$p/"
  else mkdir -p "$(dirname "$DEST$p")"; rsync -az "$SERVER:$r" "$DEST$p"; fi
done

if [ "${BRINGHOME_SKIP_GUARDED:-0}" != 1 ]; then
  for f in "${GUARDED_FILES[@]}"; do say "guarded $f…"; guarded_pull "$(remap "$f")" "$DEST$f"; done
fi

REMOTE_PROJ="$REMOTE_HOME/.claude/projects/$(slug "$REMOTE_LAUNCH")"
LOCAL_PROJ="$DEST$HOME/.claude/projects/$(slug "$LAUNCH_DIR")"
PULLED_SESSION=""
if "${SSH[@]}" "$SERVER" "[ -d '$REMOTE_PROJ' ]"; then
  mkdir -p "$LOCAL_PROJ"
  if "${SSH[@]}" "$SERVER" "[ -d '$REMOTE_PROJ/memory' ]"; then say "Claude memory…"; rsync -az "$SERVER:$REMOTE_PROJ/memory" "$LOCAL_PROJ/"; fi
  newest="$("${SSH[@]}" "$SERVER" "ls -t '$REMOTE_PROJ'/*.jsonl 2>/dev/null | head -1" || true)"
  if [ -n "$newest" ]; then
    say "newest server transcript…"
    rsync -az "$SERVER:$newest" "$LOCAL_PROJ/"
    PULLED_SESSION="$(basename "$newest" .jsonl)"
  fi
fi

echo
printf '\033[1;32m✔ Work pulled back to this machine.\033[0m\n'
echo "  Continue here:"
if [ -n "$PULLED_SESSION" ]; then
  echo "      cd '$LAUNCH_DIR' && claude --resume $PULLED_SESSION"
  echo "  …or just 'claude' there for a fresh session (memory is synced)."
else
  echo "      cd '$LAUNCH_DIR' && claude"
fi
[ -n "$DEST" ] && echo "  (test mode: written under $DEST — not your real paths)"
exit 0
