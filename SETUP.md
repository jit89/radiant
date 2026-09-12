# Setup — restore the house on a new laptop

For Claude Code. Grok is still required, but only as the plan attacker
(`scripts/grok-review.sh`) — it no longer drives the workflow. Run this
after the backup trees are on disk. Do not invent keys.
Do not skip `--check`. Done when the verify block at the bottom is all OK.

This repo (`~/claude-coding-workflow`) has **no git remote**. It must be copied
as a directory (include `.git` and `.env`). `.env` is gitignored.

Hardcoded `/Users/jit/...` paths live in the watch skill and rules. Restore
under the same home if you can. If `$HOME` is not `/Users/jit`, rewrite those
paths in step 6.

## What you are installing

| Piece | Path on disk | Claude sees it as |
|-------|----------------|-----------------|
| House (crucible, to-goals, run-goal, run-goals) | `~/claude-coding-workflow/` | `~/.claude/skills/{crucible,to-goals,run-goal,run-goals}` → **symlinks** |
| Watch harness | `~/claude-video-opt/` | skill `watch-video` |
| Watch skill body | `~/.grok/skills/watch-video/SKILL.md` | `/watch-video` |
| Watch auto-trigger | `~/.grok/rules/video-urls.md` | paste a video URL |
| Borrowed skills | `~/.agents/skills/` (mostly links into `~/mattpocock-skills`) | wayfinder, tdd, … |

Bundled xAI skills (`~/.grok/bundled/`) come with the Grok CLI. Do not copy them.

## 0. Prerequisites (host, not this repo)

```bash
command -v claude && claude --version
command -v grok && grok --version
command -v brew
brew list ffmpeg yt-dlp >/dev/null
command -v ffmpeg && command -v yt-dlp
test -x "$HOME/.local/bin/claude" || command -v claude
command -v codex || ls -d "$HOME"/.nvm/versions/node/*/bin/codex
```

Missing Grok CLI → install Grok, then `grok login`.
Missing Claude → install Claude Code, then `claude login`.
Missing Codex → install Codex CLI ≥ 0.144.
Missing ffmpeg/yt-dlp → `brew install ffmpeg yt-dlp`.

## 1. Confirm the trees exist

Expected after restore (same layout as the old laptop):

```bash
test -d "$HOME/claude-coding-workflow/skills/crucible" && echo house:OK
test -x "$HOME/claude-coding-workflow/scripts/install.sh" && echo install:OK
test -f "$HOME/claude-coding-workflow/.env" && echo house.env:OK || echo house.env:MISSING
test -x "$HOME/claude-video-opt/scripts/watch-video.sh" && echo watch:OK
test -f "$HOME/.config/watch/.env" && echo watch.env:OK || echo watch.env:MISSING
test -f "$HOME/.grok/skills/watch-video/SKILL.md" && echo watch-skill:OK
test -f "$HOME/.grok/rules/video-urls.md" && echo rules:OK
```

If `house.env:MISSING`, copy `.env.example` to `.env` and set `DEEPSEEK_API_KEY`.
Never print the key. Never commit `.env`.

Watch key: `DEEPSEEK_API_KEY` in `~/.config/watch/.env` **or** the house `.env`
(harness reads both). Whisper (`GROQ_API_KEY` / `OPENAI_API_KEY`) is optional.

```bash
chmod 600 "$HOME/claude-coding-workflow/.env" "$HOME/.config/watch/.env" 2>/dev/null || true
```

## 2. Link house skills into Grok

```bash
"$HOME/claude-coding-workflow/scripts/install.sh"
"$HOME/claude-coding-workflow/scripts/install.sh" --check
```

`--check` must print `goals.py: OK`, `mock-walk: OK`, `events.py: OK`,
`logs.sh: OK`, `run-goal wake: OK`. `claude:` and `codex:` should not be
`MISSING`. Borrowed-skill warnings are step 4.

Expect four symlinks:

```bash
ls -l "$HOME/.claude/skills/crucible" "$HOME/.claude/skills/to-goals" \
      "$HOME/.claude/skills/run-goal" "$HOME/.claude/skills/run-goals"
```

Each must point at `$HOME/claude-coding-workflow/skills/<name>`.

## 3. Watch skill (already a real directory, not a symlink)

```bash
test -f "$HOME/.grok/skills/watch-video/SKILL.md"
test -x "$HOME/claude-video-opt/scripts/watch-video.sh"
command -v codex || ls -d "$HOME"/.nvm/versions/node/*/bin/codex
mkdir -p "$HOME/Downloads/Reports"
```

Optional: `python3 "$HOME/claude-video-opt/scripts/setup.py" --check`
(exit 0 silent = ffmpeg/yt-dlp + a Whisper key, or captions-only is fine).

## 4. Borrowed skills (`~/.agents/skills`)

House `install.sh --check` wants these names present:

`wayfinder` `prototype` `research` `caveman` `tdd` `handoff`
`diagnosing-bugs` `improve-codebase-architecture`

Most are symlinks into `~/mattpocock-skills`. Restore that repo (or
`git clone https://github.com/mattpocock/skills "$HOME/mattpocock-skills"`)
then recreate the links the old machine had, **or** run that repo’s own
installer if you use it.

Local (non-link) dirs that lived under `~/.agents/skills` on the old
machine: `caveman`, `find-skills`, `llm-council`. Copy those directories
if they were in the backup.

Re-run:

```bash
"$HOME/claude-coding-workflow/scripts/install.sh" --check
```

`borrowed skills: present` is the target. Missing names are a warning; the
house still runs, but `/crucible` research/prototype/tdd/wayfinder will not.

## 5. Optional extras from the old `~/.grok/skills`

```bash
test -f "$HOME/.grok/skills/linkedin-post/SKILL.md" && echo linkedin-post:OK
```

Copy that folder if you use `/linkedin-post`. Not required for the house.

`~/.grok/config.toml` is optional (model / UI prefs). Do not copy
`~/.grok/auth.json` — run `grok login` on this machine.
Do not copy `~/.grok/bundled/` or `~/.grok/sessions/`.

## 6. Rewrite hardcoded `/Users/jit` if this home is different

```bash
echo "HOME=$HOME"
```

If that is not `/Users/jit`, replace `/Users/jit` with `$HOME` in:

- `~/.grok/skills/watch-video/SKILL.md`
- `~/.grok/rules/video-urls.md`
- `~/.claude/CLAUDE.md` (only if you also use Claude Code; skip for Grok-only)

House scripts use `$HOME` / `Path.home()` and do not need this.

`~/.claude/CLAUDE.md` is a **duplicate** of the video-URL rule for Claude
compatibility. Grok-only: `~/.grok/rules/video-urls.md` is enough.

## 7. Auth (human)

Ask the user to:

1. `grok login`
2. `claude login` (Opus 5 attacker + goal reviewer)
3. Confirm Codex can run (ChatGPT login if that CLI requires it)
4. Confirm `DEEPSEEK_API_KEY` is in house `.env` and/or `~/.config/watch/.env`

Do not ask them to paste a key into chat.

## 8. Verify (must all print OK)

```bash
# House
"$HOME/claude-coding-workflow/scripts/install.sh" --check

# Skills Claude will actually list
ls -1 "$HOME/.claude/skills"

# Grok is the attacker; it must be signed in
command -v grok >/dev/null && grok --version || echo 'grok: MISSING'

# Watch key visible to the harness (no value printed)
python3 -c "
import os
from pathlib import Path

def load(name):
    if os.environ.get(name, '').strip():
        return True
    for p in (Path.home()/'.config/watch/.env', Path.home()/'claude-coding-workflow/.env'):
        if not p.is_file():
            continue
        for line in p.read_text().splitlines():
            if line.startswith(name + '=') and line.split('=',1)[1].strip():
                return True
    return False
print('DEEPSEEK_API_KEY:', 'OK' if load('DEEPSEEK_API_KEY') else 'MISSING')
"

command -v codex >/dev/null && echo 'codex: OK' || echo 'codex: MISSING'

# Optional: grok inspect (if the binary supports it)
command -v grok >/dev/null && grok inspect 2>/dev/null | head -80 || true
```

`ls` of `~/.claude/skills` must include `crucible`, `to-goals`, `run-goal`,
`run-goals`. The Grok skill dir keeps `watch-video`.

Smoke the watch launcher help only (no network):

```bash
"$HOME/claude-video-opt/scripts/watch-video.sh" -h
```

Do **not** run a live `/run-goals` or a live watch as part of setup unless
the user asks.

## Failure table

| Symptom | Fix |
|---------|-----|
| `house.env:MISSING` | Copy `.env`; set `DEEPSEEK_API_KEY` |
| `claude: MISSING` / `codex: MISSING` | Install + login; re-run `--check` |
| Skills listed but `crucible` is a dangling symlink | House path wrong; `install.sh` again from the real repo |
| `borrowed skills missing` | Restore `~/mattpocock-skills` + `~/.agents/skills` |
| Watch skill present, harness 403 on YouTube | `download.py` already prefers android/ios player clients; not a setup miss |
| `DEEPSEEK_API_KEY: MISSING` in step 8 | Key not in watch `.env` or house `.env` |
| `/watch-video` does not fire on a pasted URL | Missing `~/.grok/rules/video-urls.md` |

## Done

Report to the user: house linked, `--check` result, watch key OK/MISSING,
borrowed skills present/missing. Stop.
