---
name: bring-home-from-server
description: Pull work back from my home server to this machine and continue locally — the reverse of handover-to-server. Fetches the repo (with server-created branches), the project's configured extra paths and guarded files, Claude memory, and the newest server session transcript so I can resume the conversation here. Use for "bring it back from the server", "pull my server work down", "sync down from the server", "continue on my computer", "come back home from the server".
---

# bring-home-from-server

The return trip for [handover-to-server](../handover-to-server/SKILL.md). Pulls
the home server's work back (server → this machine): repo with any branches
made there, `HANDOVER_SYNC_PATHS`, `HANDOVER_GUARDED_FILES` (usually the reason
to come home — that is where the latest state lives), Claude memory, and the
newest server session transcript so you can resume the conversation locally.

Driver: `~/.claude/skills/bring-home-from-server/bring-home.sh`. Run it from
inside the project; do not re-derive it. Uses the same `server.env` +
`.handover.env` as the forward skill (exit 2/3 → run `/setup-server`).

## Run

```bash
~/.claude/skills/bring-home-from-server/bring-home.sh
```

Ends by printing how to continue here — the user's interactive step, hand it over:

```
cd '<launch dir>' && claude --resume <session-id>
```

## Test safely first

Pulls real server content but writes under a scratch prefix:

```bash
BRINGHOME_DEST_PREFIX=/tmp/bh-test ~/.claude/skills/bring-home-from-server/bring-home.sh
git -C /tmp/bh-test$HOME/repos/<proj> branch
rm -rf /tmp/bh-test
```

## Knobs

- `HANDOVER_FORCE=1` — overwrite guarded files even if the local copy is newer
- `BRINGHOME_SKIP_GUARDED=1` — leave guarded files alone
- `BRINGHOME_DEST_PREFIX=/dir` — scratch prefix (testing)
- `HANDOVER_PROJECT_CONFIG` — explicit `.handover.env` path

## Gotchas

- **Symmetric guard.** handover refuses to overwrite a newer *server* copy;
  bring-home refuses to overwrite a newer *local* copy (you worked here since
  the last sync). Local is always backed up (`*.bak-<timestamp>`) before an
  overwrite, and the result is sha256-verified.
- **Server is canonical on the pull.** Repo working tree + `.git` are overwritten
  from the server (rsync, no `--delete`). Commit or stash local work first,
  otherwise the server's refs win.
- **"Newest" transcript** = most recently modified `*.jsonl` in the server's
  project dir, copied into the local slug dir where `claude --resume` looks.
  Older server sessions stay on the server. No transcript yet (idle session
  never used) → it just prints plain `claude`.
- **Slugs differ per side** (`-home-me-repos-x` vs `-Users-me-repos-x`); the
  driver maps between them.
