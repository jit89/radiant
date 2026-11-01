# Setup — restore the house on a new laptop

For Claude Code. Grok is still required, but only as the plan attacker
(`scripts/grok-review.sh`) — it no longer drives the workflow. Run this
after the backup trees are on disk. Do not invent keys.
Do not skip `--check`. Done when the verify block at the bottom is all OK.

This repo (`~/claude-coding-workflow`) has **no git remote**. It must be copied
as a directory (include `.git` and `.env`). `.env` is gitignored.

The watch skill and rules may hold absolute home paths from the old machine
(e.g. `/Users/<old-user>/...`). If this machine's `$HOME` differs, rewrite
them in step 6.

## What you are installing

| Piece | Path on disk | Claude sees it as |
|-------|----------------|-----------------|
| House (crucible, to-goals, run-goal, run-goals) | `~/claude-coding-workflow/` | `~/.claude/skills/{crucible,to-goals,run-goal,run-goals}` → **symlinks** |
| Watch harness | `~/claude-video-opt/` | skill `watch-video` |
| Watch skill body | `~/.grok/skills/watch-video/SKILL.md` | `/watch-video` |
| Watch auto-trigger | `~/.grok/rules/video-urls.md` | paste a video URL |
| Borrowed skills | `~/mattpocock-skills/` (pinned clone) | `~/.claude/skills/{wayfinder,tdd,…}` → **symlinks** (`install.sh`) |

Bundled xAI skills (`~/.grok/bundled/`) come with the Grok CLI. Do not copy them.

## 0. Prerequisites (host, not this repo)

```bash
git --version     # 2.18+ (run-goal.sh's status reads); 2.38+ for --jobs (merge-tree --write-tree)
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
Missing Codex → optional now: only the legacy `IMPLEMENTER=codex` launcher needs Codex CLI ≥ 0.144.
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
`logs.sh: OK`, `run-goal wake: OK`, `implementer: OK`. `claude:` should not be
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

## 4. Borrowed skills (pinned `~/mattpocock-skills`)

Borrowed skills come from [mattpocock/skills](https://github.com/mattpocock/skills),
cloned once and pinned to the commit `scripts/install.sh` names
(`MATTPOCOCK_SKILLS_PIN`). Not the self-updating plugin: an upstream rename
(for example `CONTEXT.md` → `GLOSSARY.md`) would land silently.

```bash
git clone https://github.com/mattpocock/skills "$HOME/mattpocock-skills"
git -C "$HOME/mattpocock-skills" checkout "$(sed -n 's/^MATTPOCOCK_SKILLS_PIN=//p' "$HOME/claude-coding-workflow/scripts/install.sh")"
"$HOME/claude-coding-workflow/scripts/install.sh"
```

`install.sh` symlinks each borrowed skill from the clone into `~/.claude/skills`:

`wayfinder` `prototype` `research` `tdd` `handoff` `diagnosing-bugs`
`improve-codebase-architecture`, plus the skills those call:
`grilling` `domain-modeling` `codebase-design` `setup-matt-pocock-skills`

A real directory already at one of those names is left alone (with a warning).
Override the clone location with `MATTPOCOCK_SKILLS_DIR`.

Re-run:

```bash
"$HOME/claude-coding-workflow/scripts/install.sh" --check
```

Targets: `borrowed <name>: present` for every name and
`mattpocock-skills pin: OK`. A missing name is a warning; the house still
runs, but `/crucible` research/prototype/tdd/wayfinder will not. `DRIFT`
prints the `git checkout` that restores the pin.

## 5. Optional extras from the old `~/.grok/skills`

```bash
test -f "$HOME/.grok/skills/linkedin-post/SKILL.md" && echo linkedin-post:OK
```

Copy that folder if you use `/linkedin-post`. Not required for the house.

`~/.grok/config.toml` is optional (model / UI prefs). Do not copy
`~/.grok/auth.json` — run `grok login` on this machine.
Do not copy `~/.grok/bundled/` or `~/.grok/sessions/`.

## 6. Rewrite old-home absolute paths if this home is different

```bash
echo "HOME=$HOME"
grep -rln '/Users/' "$HOME/.grok/skills/watch-video/SKILL.md" "$HOME/.grok/rules/video-urls.md" "$HOME/.claude/CLAUDE.md" 2>/dev/null
```

Replace any old `/Users/<old-user>` prefix with this machine's `$HOME` in:

- `~/.grok/skills/watch-video/SKILL.md`
- `~/.grok/rules/video-urls.md`
- `~/.claude/CLAUDE.md` (only if you also use Claude Code; skip for Grok-only)

House scripts use `$HOME` / `Path.home()` and do not need this.

`~/.claude/CLAUDE.md` is a **duplicate** of the video-URL rule for Claude
compatibility. Grok-only: `~/.grok/rules/video-urls.md` is enough.

## 7. Auth (human)

Ask the user to:

1. `grok login`
2. `claude login` (Opus 5.5 goal reviewer)
3. Optional, legacy `IMPLEMENTER=codex` only: confirm Codex can run
4. Confirm `DEEPSEEK_API_KEY` is in the house `.env` (the house reads only that;
   the watch harness also reads `~/.config/watch/.env`)

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
| `borrowed <name>: MISSING` | Clone + pin `~/mattpocock-skills` (step 4), re-run `install.sh` |
| `mattpocock-skills pin: DRIFT` | Run the `git checkout` it prints |
| Watch skill present, harness 403 on YouTube | `download.py` already prefers android/ios player clients; not a setup miss |
| `DEEPSEEK_API_KEY: MISSING` in step 8 | Key not in watch `.env` or house `.env` |
| `/watch-video` does not fire on a pasted URL | Missing `~/.grok/rules/video-urls.md` |

## Done

Report to the user: house linked, `--check` result, watch key OK/MISSING,
borrowed skills present/missing. Stop.
