#!/usr/bin/env bash
# Installs the three skills into ~/.claude/skills (symlinks, so `git pull` updates them).
# Usage: ./install.sh            (symlink)     ./install.sh --copy   (copy instead)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
mkdir -p "$DEST"
for s in setup-server handover-to-server bring-home-from-server; do
  if [ -e "$DEST/$s" ] && [ ! -L "$DEST/$s" ]; then
    echo "⚠ $DEST/$s exists and is not a symlink — moving it to $DEST/$s.bak"; mv "$DEST/$s" "$DEST/$s.bak"
  fi
  rm -f "$DEST/$s"
  if [ "${1:-}" = "--copy" ]; then cp -R "$HERE/skills/$s" "$DEST/$s"; else ln -s "$HERE/skills/$s" "$DEST/$s"; fi
  echo "✓ $s"
done
echo
echo "Next, in any Claude Code session:  /setup-server"
echo "or directly:  ~/.claude/skills/setup-server/setup-server.sh server --host you@your-server"
