# Always-on: setting up the Mac

The always-on house walks signed `GOALS.md` DAGs unattended on this Mac
(`PLAN.md`). This page sets the Mac up once. Every step is yours; nothing here
runs by itself.

## 1. The Mac stays up

- **Power**: keep it on AC with the lid open (a closed lid sleeps a laptop
  whatever the settings say).
- **No sleep on AC**: `sudo pmset -c sleep 0`. Displays may still sleep:
  `sudo pmset -c displaysleep 10` is fine.
- **Back after a power cut**: `sudo pmset -a autorestart 1`.
- **Back after a restart**: System Settings → Users & Groups → *Automatically
  log in as* your user. The LaunchAgents run in your login session, so
  without automatic login nothing runs after a reboot until you log in.
  (FileVault blocks automatic login; then a reboot needs you at the Mac.)

The supervisor runs under `caffeinate -is`, which keeps the Mac awake while
it runs; the settings above are what bring it back.

## 2. Keys and the recipient

- **The API key** the loop's Claude calls bill (a key with a monthly cap set
  in the Console): `~/.config/cw-secrets/anthropic-decider.key`, one line,
  mode 0600. Write it from the clipboard, never by pasting into a chat:
  `mkdir -p ~/.config/cw-secrets && pbpaste > ~/.config/cw-secrets/anthropic-decider.key && chmod 600 ~/.config/cw-secrets/anthropic-decider.key`.
- **The DeepSeek key**, as for any walk: `DEEPSEEK_API_KEY` in the house's
  `.env`. The supervisor reads its balance before
  each walk and holds below $2.
- **The iMessage recipient**: `install.sh --always-on` writes
  `~/.config/cw-always-on/notify.conf`; set `recipient=` to your phone number
  in international form (`+44...`) or your Apple ID's email.

## 3. Install, check, start

```bash
~/claude-coding-workflow/scripts/install.sh --always-on   # plists + ~/.config/cw-always-on (nothing loaded)
~/claude-coding-workflow/scripts/cw-decide.sh start       # load both LaunchAgents
~/claude-coding-workflow/scripts/cw-decide.sh doctor      # every line OK, or fix it (and run doctor again)
```

`doctor` checks: both LaunchAgents loaded (so it runs after `start`), AC
power, automatic login, the key file (present, not empty, 0600), the DeepSeek
balance at least $2, a recipient, Messages with an iMessage account this user
may script, git commits needing no signing prompt, and `claude --version`.
With the queue empty, a loaded supervisor only idles.

**The first iMessage** from a LaunchAgent may ask for permission to control
Messages (System Settings → Privacy & Security → Automation). Fire the
heartbeat agent once at the Mac and allow it if asked:
`launchctl kickstart gui/$(id -u)/com.cw.always-on.heartbeat`.

**Reinstalling** (after a house update changes the plists): `launchctl bootout
gui/$(id -u)/com.cw.always-on` and the same for `com.cw.always-on.heartbeat`,
then `install.sh --always-on` and `cw-decide.sh start`; `start` does not
reload an agent that is already loaded.

**Commit signing**: the supervisor commits one journal line per decision with
no terminal. If your git config signs commits (`commit.gpgsign true`), set up a
signer that needs no prompt, or turn signing off for the target repos; a commit
that fails holds the entry.

**Claude Code updates**: the LaunchAgents set `DISABLE_UPDATES=1` and
`DISABLE_AUTOUPDATER=1`. Upgrade between walks (`brew upgrade`); an upgrade
under a running supervisor holds the next dispatch (`claude-version-changed`).
Restart the supervisor so it records the new version, then resume:
`launchctl kickstart -k gui/$(id -u)/com.cw.always-on`, then `cw-decide.sh
resume <entry>` (`stop` and `start` do not restart it: `stop` only writes the
kill file).

## 4. Signing a walk

After `/to-goals` has committed `GOALS.md` and its oracles (with the
`ARCHITECT decompose` record and an APPROVED oracle review, or your override):

```bash
~/claude-coding-workflow/scripts/cw-decide.sh sign ~/code/my-project jobs=2
```

The loop walks exactly that commit's contract: a later change to the plan, an
oracle, `tests/acceptance/` or `GOALS.md` beyond statuses holds the entry
(`contract-drift`) until you sign again.

## 5. Day to day

| You want to | Run |
|---|---|
| See the queue, holds and spend | `cw-decide.sh status` |
| Let a held entry go on (one rerun) | `cw-decide.sh resume <entry>` |
| Drop an entry | `cw-decide.sh skip <entry>` |
| Stop everything now | `cw-decide.sh stop` (the kill file; running walks are stopped, nothing starts) |
| Go again after stop | `cw-decide.sh start`, then `resume` each entry the stop held |

Messages come for every hold and every finished walk (the digest marks one
decision in five for a spot check: read it in
`~/.cache/claude-coding-workflow/always-on/decisions.jsonl`), and once a day at
09:00 (the heartbeat). **No heartbeat on a day means the Mac is off or asleep;**
a late one means it slept through 09:00 and sent it on waking.
With Remote Control connected and a Claude Code session open, a hold also
arrives as a push from the walk mod.

A hold's class says who it is for: **A** (security, integrity, contracts,
budget, the loop's own safety) and **B** (contract questions) are yours;
**needs-human** means the decider or a retry limit gave up. Fix what the hold
names, commit, and `resume` (or `sign` again if you changed the contract).

## 6. Ceilings

$10 in any 24 hours, $20 per entry, $50 in any 7 days (`always-on-spend.py`),
the Console's monthly cap on the key, and the DeepSeek prepaid balance. Over a
ceiling the walker stops and the entry holds `budget`.
