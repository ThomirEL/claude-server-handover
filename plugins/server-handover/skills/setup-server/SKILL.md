---
name: setup-server
description: One-time setup for the home-server handover skills. Configures which server to use (once per machine) and what a project should carry across (once per project). Use for "set up my server", "setup-server", "configure handover for this project", "add this project to the server handover", or whenever handover-to-server / bring-home-from-server say the server or project is not set up.
---

# setup-server

> **Where the scripts live.** `${SKILLS}` below means the `skills/` directory this SKILL.md sits in: `${CLAUDE_PLUGIN_ROOT}/skills` when installed as the `server-handover` plugin, or `~/.claude/skills` when installed with `install.sh`. Resolve it once, then run the scripts from there.

Two layers of config, one script: `${SKILLS}/setup-server/setup-server.sh`.

| Layer | File | Created by |
|---|---|---|
| Server (per machine) | `~/.claude/handover/server.env` | `setup-server.sh server --host user@host` |
| Project (per project) | `<launch dir>/.handover.env` | `setup-server.sh project --dir <launch dir> …` |

`handover.sh` / `bring-home.sh` exit **2** when the server layer is missing and
**3** when the project layer is missing. Run the matching step below, then re-run.

## Server (first time on this machine)

Ask the user for the ssh target (e.g. `you@100.x.y.z`, a Tailscale IP is
ideal). Optionally a remote `CLAUDE_CONFIG_DIR` if they use a separate Claude
profile on the server.

```bash
${SKILLS}/setup-server/setup-server.sh server --host user@host \
  [--no-remote-control] [--claude-args "--permission-mode acceptEdits"]
```

Remote Control is on by default: the remote session starts with
`--remote-control`, so questions and permission prompts reach the user's phone or
claude.ai/code instead of stalling in tmux. On Team/Enterprise an admin must have
enabled Remote Control; if the remote session fails to start, re-run with
`--no-remote-control` (or set `HANDOVER_REMOTE_CONTROL=0` in `server.env`).

It checks key-based ssh (no password prompts — `ssh-copy-id user@host` if it
fails) and that `tmux`, `rsync`, `python3`, `claude` exist on the server.

## Project (first time per project)

The **launch dir** is where Claude starts on the server and where `.handover.env`
lives. Usually the repo root; can be a parent folder holding repo + data.

Ask the user, then run (all flags optional except `--dir`):

```bash
${SKILLS}/setup-server/setup-server.sh project --dir ~/repos/myproj \
  --repo . \
  --sync "~/repos/myproj-data ~/some/other/dir" \
  --guarded "~/.myproj/state.db" \
  --session myproj \
  --remote-setup '[ -d .venv ] || python3 -m venv .venv; ./.venv/bin/pip install -q -e .' \
  --remote-env "MYPROJ_DB=~/.myproj/state.db" \
  --excludes "dist .cache"
```

Meaning of each field:

- `--repo` — git repo to mirror with its `.git` (branches travel). Relative to the launch dir, or absolute. Default `.`.
- `--sync` — extra files/dirs to mirror (Mac canonical on push, server canonical on pull). Must live under `$HOME`; the same relative path is used on the server.
- `--guarded` — irreplaceable files (SQLite DBs, decision logs). Always backed up before overwrite; **never overwrite a newer copy** in either direction unless `HANDOVER_FORCE=1`.
- `--session` — tmux name. Default: launch dir basename. Auto-suffixed `-2`, `-3` if taken.
- `--remote-setup` — shell run inside the remote repo before Claude starts (venv, npm ci…). Skip with `HANDOVER_SKIP_SETUP=1`.
- `--remote-env` — `KEY=value` pairs exported into the remote Claude session; `~` in values is remapped to the server's home.
- `--excludes` — extra rsync exclude patterns (defaults already skip `node_modules .venv __pycache__ .pytest_cache`).

Good defaults when the user is unsure: `--repo .` and nothing else. Only add
`--guarded` when there is a file that would be painful to lose.

`.handover.env` contains local paths; if it sits inside the repo, add it to
`.gitignore` (the script warns).

## Check what would be used

```bash
${SKILLS}/setup-server/setup-server.sh status --dir ~/repos/myproj
```

## Reconfigure

Re-run `project … --force` to overwrite. Or edit `.handover.env` by hand — it is
plain shell `KEY='value'` lines.
