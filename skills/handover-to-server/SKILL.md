---
name: handover-to-server
description: Hand off, sync, or deploy the current project to my home server over SSH and launch Claude Code there — optionally with a starting prompt so the remote session begins work immediately. Works per project via a .handover.env in the project root (set up once with setup-server). Use for "hand this off to my server", "sync to my home server", "continue this on my server", "ssh this over and start claude", "deploy to the home server and pick up there".
---

# handover-to-server

Pushes the current project to the home server and starts Claude Code there in a
detached tmux session, already working on a prompt if you give one. One script:
rsync (repo + configured extra paths + guarded files) → remote setup command →
pre-accept folder trust → tmux + `claude "<prompt>"`. It is a **push** (this
machine → server).

Driver: `~/.claude/skills/handover-to-server/handover.sh`. Run it from inside
the project; do not re-derive it.

## Run

```bash
~/.claude/skills/handover-to-server/handover.sh "continue the UX work — run pytest first"
```

No argument = sync and launch an idle session. It prints the attach command for
the **user** to run in their own terminal (interactive TTY — hand it over, do
not run it from the agent):

```
ssh -t user@host 'tmux attach -t <session>'
```

`HANDOVER_ATTACH=1` attaches at the end (only when a human runs it directly).

## First-time setup (the script tells you)

- exit code **2** → server not configured. Run `/setup-server` (server step).
- exit code **3** → no `.handover.env` found from the current dir upward. Run
  `/setup-server` (project step). Ask the user what belongs to the project: the
  repo, any data dirs, any irreplaceable DB, a setup command. Then re-run.

Config discovery: walks up from `$PWD` to the first `.handover.env`; that dir
is the launch dir. Override with `HANDOVER_PROJECT_CONFIG=/path/.handover.env`.

## What it syncs (and where)

Local `$HOME`-rooted paths mirror onto the server's `$HOME`
(`/Users/me/repos/x` → `/home/me/repos/x`):

- the repo with its full `.git` (local-only branches/tags travel)
- `HANDOVER_SYNC_PATHS` — extra dirs/files, this machine canonical
- `HANDOVER_GUARDED_FILES` — backed up on the server first; **skipped with a
  warning if the server copy is newer** (`HANDOVER_FORCE=1` to override)
- global `~/.claude/CLAUDE.md` (opt-out `HANDOVER_SYNC_GLOBAL_CLAUDE_MD=0`) and
  this project's Claude memory dir

## Verify a launched session (agent, headless)

```bash
ssh -o BatchMode=yes user@host 'tmux capture-pane -t <session> -p | tail -15'
```

## Knobs

- `HANDOVER_FORCE=1` — push guarded files even if the server copy is newer
- `HANDOVER_SKIP_SETUP=1` — skip `HANDOVER_REMOTE_SETUP`
- `HANDOVER_ATTACH=1` — `ssh -t` attach at the end
- `HANDOVER_PROJECT_CONFIG` — explicit `.handover.env` path

## Gotchas (all hit and handled)

- **Guarded files are irreplaceable and the server is also worked on.** Naive
  push would overwrite server-side work; hence the newer-wins guard + backup +
  sha256 verify.
- **Trust dialog.** A profile that has never seen the launch folder stalls on
  "Is this a project you trust?" and never runs the prompt. The driver sets
  `hasTrustDialogAccepted` for the launch dir in the remote `.claude.json`
  (`HANDOVER_CLAUDE_CONFIG_DIR` picks the profile).
- **Prompt injection through ssh→tmux→shell.** Quoting is a minefield, so the
  prompt is written to `~/.handover/<session>.prompt` on the server and the
  launcher reads it with `claude "$(cat …)"`. Empty file → plain `claude`.
- **tmux name collisions.** Auto-increments (`x` → `x-2`) instead of clobbering
  and prints the name actually used.
- **Non-interactive rc.** Ubuntu's `.bashrc` early-returns for non-interactive
  shells, so nothing is sourced; the launcher exports what it needs itself and
  the remote setup runs under `bash -lc`.
- **Non-ASCII paths** (`ø` etc.) are preserved; the Claude project slug is
  `re.sub(r'[^a-zA-Z0-9]','-', path)`, computed per side.

## Troubleshooting

- `✗ cannot reach <server> over key-based SSH` — `BatchMode=yes`, no password
  prompts. `ssh-copy-id user@host` first.
- Remote Claude sits at a trust prompt anyway — the remote profile's config dir
  differs; set `HANDOVER_CLAUDE_CONFIG_DIR` in `~/.claude/handover/server.env`.
- Remote setup failed — open the session and finish it by hand; the driver only
  warns.
