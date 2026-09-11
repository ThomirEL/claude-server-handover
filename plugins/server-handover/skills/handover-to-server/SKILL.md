---
name: handover-to-server
description: Hand off, sync, or deploy the current project to my home server over SSH and launch Claude Code there — optionally with a starting prompt so the remote session begins work immediately. Works per project via a .handover.env in the project root (set up once with setup-server). Use for "hand this off to my server", "sync to my home server", "continue this on my server", "ssh this over and start claude", "deploy to the home server and pick up there".
---

# handover-to-server

> **Where the scripts live.** `${SKILLS}` below means the `skills/` directory this SKILL.md sits in: `${CLAUDE_PLUGIN_ROOT}/skills` when installed as the `server-handover` plugin, or `~/.claude/skills` when installed with `install.sh`. Resolve it once, then run the scripts from there.

Pushes the current project to the home server and starts Claude Code there in a
detached tmux session, already working on a prompt if you give one. One script:
rsync (repo + configured extra paths + guarded files) → remote setup command →
pre-accept folder trust → tmux + `claude "<prompt>"`. It is a **push** (this
machine → server).

Driver: `${SKILLS}/handover-to-server/handover.sh`. Run it from inside
the project; do not re-derive it.

## Before you send: pre-screen the questions (do this every time there is a prompt)

The remote session is unattended. Anything it would stop to ask the user about
becomes hours of idle time. So screen for those questions **here, while the user
is present**, and answer them in the prompt.

1. **Mechanical checks** — run and read the warnings:
   ```bash
   ${SKILLS}/handover-to-server/handover.sh --preflight
   ```
   Missing tools on the server, no git identity, dirty tree, leftover
   `HANDOVER-QUESTIONS.md` from last run, missing `.env`, guard conflicts.
   Resolve what you can (commit, copy the .env, set the identity) or tell the user.

2. **Judgement pass** — read the user's prompt against the project (CLAUDE.md,
   README, recent git log, the files the task touches) and look for decisions a
   Claude working alone would plausibly stop to ask about. **Only ask if you
   find one.** Most prompts need zero questions; a clear prompt with a
   CLAUDE.md that settles conventions should go straight to the server. Never
   invent questions to look thorough, and never ask what you can look up or
   what the unattended preamble already covers ("assume, log blockers, commit").
   Things that do justify a question:
   - ambiguity in scope ("which of the three failing tests?", "also the frontend?")
   - a choice of approach with real trade-offs (library, schema change vs. migration)
   - anything destructive or hard to undo (force-push, dropping data, deleting files)
   - credentials, external services, deploy targets
   - style/convention questions not settled by CLAUDE.md
   - "done" criteria: tests must pass? open a PR? just commit?
   If there are any, ask them all in **one** `AskUserQuestion` batch, with the
   default you would pick marked as recommended. Rarely more than 3.

3. **Fold any answers into the prompt** as an explicit block (omit the block if
   there were no questions), then run:
   ```bash
   ${SKILLS}/handover-to-server/handover.sh "continue the UX work — run pytest first

   DECISIONS ALREADY MADE (do not re-ask):
   - Only fix the 3 failing tests in tests/ux/; do not touch the frontend.
   - Use the existing migration pattern in db/migrations; no schema rewrite.
   - Done = pytest green + one commit per logical change on branch ux-fixes. No PR.
   - If X turns out to be needed, prefer Y."
   ```
   The driver adds the unattended preamble (assume, log real blockers to
   `HANDOVER-QUESTIONS.md`, commit as you go) on top.

If the user says "just send it", skip the judgement pass but still run
`--preflight`. When the user gives **no prompt** (idle session), skip both.
Tell the user in one line what you checked and that nothing needed asking, when
that is the case.

## Run

```bash
${SKILLS}/handover-to-server/handover.sh "continue the UX work — run pytest first"
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

## If it still needs the user later

Pre-screening removes most stalls. What is left:

1. **Unattended preamble** (`HANDOVER_UNATTENDED_NOTE=1`): the remote Claude is
   told to assume, log real blockers to `HANDOVER-QUESTIONS.md`, and keep going
   with everything else. After bring-home, read that file to the user.
2. **`--status`** (below) tells whether it is working, idle, or waiting.
3. **Remote Control** (`HANDOVER_REMOTE_CONTROL=1`, default on): a
   `https://claude.ai/code/session_…` URL is printed; if the user does have the
   Claude app or a browser handy, prompts can be answered there. Optional, not
   required.
4. `HANDOVER_CLAUDE_ARGS='--permission-mode acceptEdits'` in `server.env` to
   auto-approve edits on the server.

## Check on a session (agent, headless)

```bash
${SKILLS}/handover-to-server/handover.sh --status            # session from .handover.env
${SKILLS}/handover-to-server/handover.sh --status <session>
```

Prints `▶ WORKING`, `✔ IDLE` (turn finished, prompt empty) or `⚠ WAITING FOR YOU`
(question / permission prompt) plus the last pane lines and how to answer. Use
this when the user asks "how is the server doing?" or "is it stuck?".

## Knobs

- `HANDOVER_FORCE=1` — push guarded files even if the server copy is newer
- `HANDOVER_SKIP_SETUP=1` — skip `HANDOVER_REMOTE_SETUP`
- `HANDOVER_ATTACH=1` — `ssh -t` attach at the end
- `HANDOVER_PROJECT_CONFIG` — explicit `.handover.env` path
- `HANDOVER_REMOTE_CONTROL=0` — launch without Remote Control (server.env)
- `HANDOVER_CLAUDE_ARGS` — extra flags for the remote `claude` (server.env)
- `HANDOVER_UNATTENDED_NOTE=0` — do not prepend the unattended preamble (server.env)

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
