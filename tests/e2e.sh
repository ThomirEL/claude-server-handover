#!/bin/bash
# End-to-end test against a REAL server: setup → handover (with a prompt Claude
# executes remotely) → bring home. Needs server.env configured already.
#
#   tests/e2e.sh                 # uses the skills under ./plugins/server-handover/skills
#   SKILLS=~/.claude/plugins/cache/claude-server-handover/server-handover/1.0.0/skills tests/e2e.sh
#
# Creates ~/repos/handover-demo (tiny markdown project), pushes it, asks the
# remote Claude to edit + commit, waits, pulls back, asserts. Cleans up the
# server side and the tmux session; leaves the local demo dir for inspection
# unless KEEP=0.
set -euo pipefail
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"   # macOS bash 3.2 + UTF-8 is the hostile case; test it on purpose
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SKILLS="${SKILLS:-$HERE/plugins/server-handover/skills}"
DEMO="$HOME/repos/handover-demo"
WAIT="${WAIT:-90}"
pass(){ printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
fail(){ printf '\033[1;31mFAIL\033[0m %s\n' "$*"; exit 1; }

. "$HOME/.claude/handover/server.env"; SERVER="$HANDOVER_SERVER"
ssh_(){ ssh -o BatchMode=yes "$SERVER" "$@"; }

echo "── 0. fresh demo project"
rm -rf "$DEMO" "$HOME/.handover-demo"; mkdir -p "$DEMO" "$HOME/.handover-demo"
cd "$DEMO" && git init -q
printf '# Handover demo\n\nTiny project to prove the round trip.\n' > README.md
printf '# Notes\n\n- written on the Mac\n' > notes.md
git add . && git commit -qm "init" && git checkout -qb mac-branch
echo "decisions v1" > "$HOME/.handover-demo/decisions.db"

echo "── 1. setup project"
"$SKILLS/setup-server/setup-server.sh" project --dir "$DEMO" --guarded "~/.handover-demo/decisions.db" --session handover-demo --force
[ -f "$DEMO/.handover.env" ] && pass ".handover.env written" || fail "no .handover.env"

echo "── 2. exit codes without config"
tmpd=$(mktemp -d); (cd "$tmpd" && "$SKILLS/handover-to-server/handover.sh" >/dev/null 2>&1) && fail "should exit 3" || { [ $? -eq 3 ] && pass "exit 3 when no project config"; }

echo "── 3. handover with a prompt"
cd "$DEMO"
"$SKILLS/handover-to-server/handover.sh" 'Append the line "- edited on the server" to notes.md, then run: git add -A && git commit -m "server edit". Do nothing else, then stop.' | tee /tmp/handover-demo.log
SESS=$(grep -o "tmux session '[^']*'" /tmp/handover-demo.log | sed "s/tmux session '//;s/'//")
[ -n "$SESS" ] && pass "session $SESS launched" || fail "no session name"
ssh_ "cd ~/repos/handover-demo && git branch --show-current" | grep -q mac-branch && pass "local-only branch travelled" || fail "branch missing on server"
ssh_ "cat ~/.handover-demo/decisions.db" | grep -q "decisions v1" && pass "guarded file pushed" || fail "guarded file missing"

echo "── 4. wait up to ${WAIT}s for remote Claude to commit"
for i in $(seq 1 "$WAIT"); do
  if ssh_ "cd ~/repos/handover-demo && git log --oneline -1" | grep -q "server edit"; then pass "remote Claude committed after ~${i}s"; break; fi
  [ "$i" -eq "$WAIT" ] && { ssh_ "tmux capture-pane -t $SESS -p | tail -20"; fail "remote Claude did not commit in ${WAIT}s"; }
  sleep 1
done
ssh_ "sleep 2; echo 'decisions v2 (server)' > ~/.handover-demo/decisions.db"

echo "── 5. bring home"
"$SKILLS/bring-home-from-server/bring-home.sh" | tee /tmp/bringhome-demo.log
grep -q "edited on the server" "$DEMO/notes.md" && pass "server edit is in local notes.md" || fail "local notes.md lacks server edit"
git -C "$DEMO" log --oneline -1 | grep -q "server edit" && pass "server commit is in local git" || fail "server commit missing locally"
grep -q "v2 (server)" "$HOME/.handover-demo/decisions.db" && pass "newer guarded file pulled" || fail "guarded file not updated"
ls "$HOME/.handover-demo/"*.bak-* >/dev/null 2>&1 && pass "local backup made before overwrite" || fail "no backup"
grep -q "claude --resume" /tmp/bringhome-demo.log && pass "transcript pulled, resume command printed" || fail "no transcript / resume"

echo "── 6. guard: local newer must not be overwritten"
sleep 1; echo "local v3" > "$HOME/.handover-demo/decisions.db"
"$SKILLS/bring-home-from-server/bring-home.sh" > /tmp/bringhome-guard.log 2>&1 || true
grep -q "is NEWER" /tmp/bringhome-guard.log && pass "pull refused to clobber newer local" || { cat /tmp/bringhome-guard.log; fail "guard failed on pull"; }
grep -q "local v3" "$HOME/.handover-demo/decisions.db" || fail "local file was clobbered"

echo "── 7. cleanup server"
ssh_ "tmux kill-session -t '$SESS' 2>/dev/null || true; rm -rf ~/repos/handover-demo ~/.handover-demo ~/.handover/handover-demo.* ~/.claude/projects/-home-*-repos-handover-demo"
pass "server cleaned"
if [ "${KEEP:-1}" = 0 ]; then rm -rf "$DEMO" "$HOME/.handover-demo" "$HOME/.claude/projects/$(python3 -c "import re;print(re.sub(r'[^a-zA-Z0-9]','-','$DEMO'))")"; fi
echo; printf '\033[1;32mALL PASSED\033[0m  (demo left at %s — run: cd %s && %s)\n' "$DEMO" "$DEMO" "$(grep -o 'claude --resume [a-f0-9-]*' /tmp/bringhome-demo.log || echo claude)"
