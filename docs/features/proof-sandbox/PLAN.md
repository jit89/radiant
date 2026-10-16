# Plan: Sandbox the host proof (house item 12)
_Locked via crucible — by Claude + cobalt, 2026-10-16._

## Goal

The implementer (Haiku 5.5) runs inside Claude Code's sandbox. The code it
writes then runs on the host **unsandboxed**, as the user, through the goal's
proof: `scripts/lib/proof.sh` `proof_exec` runs `env -u <credential vars> bash
-c "$PROOF"`. The same function runs the walker's `worktree_setup` and its
merged proofs after an integration. Today that code can:
- read every file the user can, including other repos and secrets;
- write anywhere the user can, including the walker's run folders, the events
  index, the main checkout and shell start-up files;
- reach the network.

Step 3 (ADR 0002) feeds a red proof's output back to the implementer, so
anything a proof prints can reach a model provider. Its excerpt is redacted,
but redaction only catches known secret shapes.

A second gap: the implementer's Read, Edit and Write tools are confined to
`$RUN_DIR/implementer/`, but its shell can read all of `$RUN_DIR`, including
the raw, unredacted proof output that the redaction exists to protect, and
every other goal's run folder in a parallel walk.

This plan closes both: every `proof_exec` call runs under a macOS sandbox
profile the house generates, and the implementer's folder moves out of the run
folders so the run folders can be read-denied whole.

## Approach

### 0. Measure before building (evidence, no house code)

Write the step 0 profile by hand and run, under `sandbox-exec`, recorded in
`EVIDENCE.md`:
- **Legitimate proofs:** the rbtree C proofs (CMake, Homebrew gcc-16, ASan and
  UBSan), the uregex proofs, and the ts-tier-rules fixture's Vitest and
  node:test proofs. Each must pass under the profile exactly as it passes
  without it.
- **Legitimate setups** (`--setup`): a fresh-tree `npm ci` and a fresh-tree
  `uv sync --frozen`, with their caches pointed at `--tmp` (step 3).
- **Where denials land:** with `(debug deny)` the kernel logs each denied
  operation and path to the unified log, not to the process. Measure how to
  bring them into the proof's own output: a `log show --predicate
  'sender == "Sandbox"'` window filtered to the proof's process ids, or
  `log stream` around the run. Pick the one that reliably names the operation
  and path, and record its latency.
- **Escape probes,** each must be refused, run both with the stock binaries
  and with **copies of them placed in `--root`** (a path rule on
  `/usr/bin/open` does not cover a copy, so the mach lookups are what must
  hold):
  - writes to `$HOME`, `~/.zshrc`, `~/Library/LaunchAgents`, another repo, the
    run folder, the events index, the main checkout of a worktree goal, and
    `<root>/.git`;
  - reads and writes of every secret-list path, **including a listed secret
    planted inside `--root`** (a `.env` in the checkout);
  - a symlink in the checkout to a denied path, read and written through;
  - a hard link: creating one in the sandbox, in `--root` and in `--tmp`, to a
    file outside them; and reading and writing through a hard link left before
    the run in an ignored folder of the checkout and in `<root>/.git`;
  - Launch Services (`open`, `open -a Terminal`, a C program calling
    `LSOpenCFURLRef`), AppleEvents (`osascript`), launchd job submission
    (`launchctl submit`/`bootstrap`), all from copies in `--root`;
  - the keychain through `securityd`: `security find-generic-password`,
    `git credential fill` with the osxkeychain helper;
  - an ssh agent through `SSH_AUTH_SOCK`, and the Docker socket
    (`~/.docker/run/docker.sock`, `/var/run/docker.sock`);
  - a copy of `sandbox-exec` in `--root` running a nested `(allow default)`
    profile: it must still be unable to write outside `--root`, open Launch
    Services or reach `securityd`;
  - outbound TCP to a public address and a public DNS lookup: each must fail
    with `EPERM` from the sandbox (not `ECONNREFUSED`, which a closed port
    gives with no sandbox at all).
- **Localhost:** a server bound on `127.0.0.1` and on `::1` (Node listens on
  `::1` by default), each connected to, with the network otherwise denied; a
  bind to `0.0.0.0` refused; a connect to a TCP service already listening on
  the host's loopback (Docker's API on `127.0.0.1:2375`, a stand-in listener
  started outside the sandbox) refused.
- **The implementer's write set.** List every place Claude Code's sandbox lets
  the implementer write (the repo, its `$TMPDIR`, its handoff folder, the
  worktree's admin and common gitdirs, anything else measured). Each must be
  either unreadable to the proof or covered by the hard-link walk (step 3);
  record which. Plant a hard-linked secret in each from inside the implementer
  sandbox and check the proof cannot read it or `proof-hardlink` fires.
- **Trees after setup:** run the hard-link pre-check (step 3) on the trees the
  fresh-tree `npm ci` and `uv sync --frozen` left, and on a pnpm install: it
  must pass.
- **Rule order:** that a later `allow` for `--tmp` overrides an earlier `deny`
  of the folder that holds it, and that a later `deny` of a secret path
  overrides an earlier `allow` of `--root`.

If any legitimate proof or setup cannot pass without widening the profile
beyond this plan, or any probe escapes, stop and bring the evidence to the
user before step 1.

### 1. The profile generator: `scripts/lib/proof-sandbox.py`

`proof-sandbox.py --root DIR --tmp DIR [--network] [--setup]` prints a
Seatbelt profile (SBPL) to stdout.

**Paths.** `~` is expanded first. A path that exists is resolved with
`realpath` (`/var` → `/private/var`, symlinked homes); a path that does not
exist yet is denied as its literal expanded path, and also with its existing
parent resolved, so a file created later is still covered. Every path must
match `[A-Za-z0-9._/@+-]` only; anything else (a quote, a backslash, a space,
a control character, non-ASCII) makes the generator exit 2 with the offending
path, and `proof_exec` stops the goal (`proof-sandbox-path`). No path is ever
escaped by hand.

**The profile, in this order (SBPL: the last matching rule wins):**
1. `(version 1)`, `(deny default)`, `(debug deny)`.
2. The allows step 0 measured a proof needs: process fork and exec, signals
   within the sandbox, sysctl reads, the mach and IPC lookups the measured
   toolchains use (an explicit list, no wildcard), reads of the filesystem,
   and `/dev/null`, `/dev/zero`, `/dev/random`, `/dev/urandom` and `/dev/tty`.
3. Writes to `--root` and `--tmp` only.
4. Network: bind, inbound and outbound on `127.0.0.1` and `::1` only, and the
   unix-socket paths step 0 printed as needed (explicit paths, never an
   unscoped `(remote unix-socket)`). Outbound to a loopback port is allowed
   only to ports the sandboxed process itself bound (step 0 measures whether
   SBPL can express that; if it cannot, outbound loopback is limited to
   ports above 1023 and the host-loopback probe decides whether that is
   acceptable, brought to the user if not). `--network` or `--setup` allows
   outbound network.
5. **Denials that must win over the allows above,** emitted last:
   - reads and writes of every secret-list path (step 2), wherever it sits,
     including inside `--root`;
   - reads of the house's state: `~/.cache/claude-coding-workflow/runs`,
     `grok`, `logs`, `keys`, `handoffs`, and the `run-goal-*` folders;
   - reads of the shared temp areas, `/tmp`, `/private/tmp` and
     `/private/var/folders`, except the toolchain caches step 0 shows are
     needed (e.g. the per-user cache folder clang and `xcrun` use), each of
     which is then also covered by the hard-link walk;
   - writes to `<root>/.git` (a proof never needs to write git metadata; in
     worktree mode `.git` is a file and the common gitdir is outside `--root`);
   - `file-link*` everywhere (no hard link can be created in the sandbox);
   - the mach lookups that reach outside the sandbox: `securityd` and the
     keychain services, Launch Services, AppleEvents and launchd job
     submission, by the exact names step 0 recorded;
   - `process-exec` of `/usr/bin/open`, `/usr/bin/osascript`,
     `/bin/launchctl`, `/usr/bin/security` and `/usr/bin/sandbox-exec`
     (a second layer; the mach denials are what hold against copies).
6. A final allow of `file-read*` and `file-write*` (only those) of `--tmp`,
   for a `--tmp` that sits under a denied house folder (the walker's
   `$WAVE_DIR/tmp-*`, `run-goal.sh`'s `$RUN_DIR/tmp`). `--tmp` is created
   fresh per run and can hold no secret.
7. `file-link*` denied again, after that allow, so no rule can re-open it.

### 2. One secret list: `scripts/lib/secret-paths.txt`

One path per line, `#` comments. A line may start with `~/` (the user's home)
or `@HOUSE/` (the house checkout the reader runs from); the readers expand
both, and nothing is resolved against the target repo. The list:
- `@HOUSE/.env`, `~/.config/watch/.env`, `~/.cache/claude-coding-workflow/keys`;
- `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/.npmrc`, `~/.pypirc`,
  `~/.docker` (the whole folder: config and `run/docker.sock`), `~/.kube`,
  `~/.config/gh`;
- `~/.claude`, `~/.grok`, `~/.codex`, `~/Library/Keychains`;
- `~/.config/cw-secrets` (Amendment 1 B: where a walked project's secrets
  live, outside its checkout).

`claude-implement.sh`'s `settings_json` reads the same file for its
`sandbox.filesystem.denyRead` and its `Read(...)` permission denials, in
place of its three hard-coded paths.

### 3. `proof_exec` runs under the profile

`proof_exec SECS OUT TMP CMD` keeps its signature. New:
- **The checkout.** The caller passes the directory the command runs in as
  `PROOF_ROOT` (`run-goal.sh`: the repo or the goal's worktree; the walker:
  the scratch integration tree or the goal's worktree); `proof_exec` refuses
  to run without it, and without a non-empty `TMP` (`run-goal.sh` in serial
  mode creates `$RUN_DIR/tmp`, as worktree mode already does).
- **Hard links.** Before the run, `proof_exec` walks `PROOF_ROOT` (including
  `.git`), `TMP`, and, for a worktree, its admin and common gitdirs (which sit
  outside the checkout and which the proof can read), plus any temp-area
  cache step 0 kept readable. It counts, for each regular file, the names it
  has in those trees. A file whose link count is greater than that count has a name
  outside them, and stops the goal (`proof-hardlink`, naming the files): a
  link left by the implementer could otherwise reach a file outside the
  checkout, since Seatbelt checks the path opened, not the file. Links wholly
  inside the trees (a package manager's own) are fine. Installs are told to
  copy rather than link out of their caches (`UV_LINK_MODE=copy`,
  `npm_config_package_import_method=copy` for pnpm).
- **The environment** (on top of today's credential stripping and
  `PYTHONDONTWRITEBYTECODE=1`): `SSH_AUTH_SOCK` unset; `GIT_CONFIG_GLOBAL`
  and `GIT_CONFIG_SYSTEM` set to `/dev/null` (no credential helper, no
  include); `npm_config_cache`, `UV_CACHE_DIR`, `PIP_CACHE_DIR` and
  `XDG_CACHE_HOME` pointed under `TMP`, so `worktree_setup` installs and
  proofs never write the user's shared caches.
- **The run.** The profile is generated into the caller's run folder
  (`$RUN_DIR/proof-sandbox.sb`, the walker's `$WAVE_DIR/...`), outside
  anything the proof can write, and the command runs as
  `sandbox-exec -f <profile> env ... bash -c "$CMD"`.
- **Denials in the output.** After the run, the step 0 method appends the
  sandbox's denials for that run (operation and path) to the proof's output
  file, under a `--- proof sandbox denials ---` line, so a fix round and the
  Architect can see them. This is for diagnosis only: it never decides red.
- **`proof_network`.** The GOALS.md preamble key is read once, from the main
  checkout, beside `worktree_setup` (`goals.py meta`). It is on only for the
  exact string `true`; `goals.py validate` refuses any other value (`false`
  is the default: leave the key out). When on, every proof of the walk gets
  `--network`. `worktree_setup` always gets `--setup`.

### 4. Fail closed (Q4)

- `scripts/lib/proof-sandbox.sh` `proof_sandbox_selftest` runs, before any
  implementer pass, in `run-goal.sh` (serial and `--worktree`) and once per
  walk in `run-goals.sh`. It generates a profile for a throwaway root and
  checks, each by its exact result:
  - `true` runs;
  - a write inside the root works and a write outside it fails with `EPERM`;
  - a read of a planted secret-list file fails with `EPERM`;
  - a read of a file planted under `/private/var/folders` (outside `--tmp`)
    fails with `EPERM`;
  - a connect to a public address fails with `EPERM`, and a public DNS lookup
    fails (no traffic leaves: the sandbox refuses before any packet);
  - inside the sandbox, a listener the test binds on `127.0.0.1` accepts the
    test's own connect, and a connect to a listener the harness started
    outside the sandbox, on another loopback port, fails with `EPERM`. (If
    step 0 found SBPL cannot express "own ports only" and the user accepted
    ports above 1023, the self-test checks that rule instead.)
- Any failure, `/usr/bin/sandbox-exec` missing, or a profile that does not
  load stops with `proof-sandbox-unavailable` and the self-test's output.
- `CW_PROOF_SANDBOX=off`, set by the user in the environment the walk is
  launched from, runs `proof_exec` unsandboxed as today. It is read only from
  the host's environment (the implementer cannot change that), journaled as
  `ORCHESTRATOR proof-sandbox off` once per run, and printed in the walk's
  header. No other value or variable disables it.

### 5. A sandbox denial is a red proof only if the proof says so

Red stays what it is today: a non-zero exit or `Ran 0 tests`. A denial the
proof does not handle makes it fail and so goes to a proof fix round; a proof
that catches `EPERM` and exits 0 is green, as any proof that passes is. The
denial listing (step 3) is diagnosis, never a red signal. The proof fix
handoff's "look for what differs on the host" line becomes: "environment
variables, `$TMPDIR`, network access, and the proof sandbox (no network but
localhost, writes only in the checkout and `$TMPDIR`, secret paths
unreadable); its denials, if any, are listed at the end of the output". The
tamper checks (`tree_snapshot`, `proof_moved`) stay as they are.

### 6. The implementer's folder leaves the run folder (Q5)

- The implementer folder (the handoffs, the return documents and the frozen
  plan copy) becomes `$CW_CACHE/handoffs/run-goal-<id>-XXXXXX/` (0700)
  instead of `$RUN_DIR/implementer/`. `cw_cache_init` creates `handoffs/`
  0700; `cw_prune` prunes it past `CW_PRUNE_DAYS` like `runs/`.
- **Who creates it.** In a walk, the walker creates every wave member's
  handoff folder before it spawns any member, and passes each its own path
  (`run-goal.sh --handoff-dir DIR`). In serial mode `run-goal.sh` creates it.
  A resume needs no pointer to an old one: it already rebuilds its handoffs
  from `ART_DIR` and `git show`, and writes them into the new folder.
- **The implementer's `$TMPDIR`.** `claude-implement.sh` sets the
  implementer's `TMPDIR` to `tmp/` inside its handoff folder (created 0700),
  instead of inheriting whatever the launching shell exported (which could be
  `~/tmp`, a folder the proof can read). The handoff folders are unreadable to
  every proof, so nothing the implementer plants in its scratch space reaches
  one. Step 0 checks the `$TMPDIR` the implementer's shell actually sees under
  Claude Code's sandbox; if Claude Code replaces it, that path must sit under a
  denied prefix, or the plan comes back to the user.
- **What the implementer may not read.** `claude-implement.sh` gains
  `--deny-read PATH` (repeatable, like `--deny-write`), added to
  `sandbox.filesystem.denyRead` and as `Read(...)` permission denials.
  `run-goal.sh` passes `$CW_CACHE/runs`, `$CW_CACHE/grok`, `$CW_CACHE/logs`
  and its `run-goal-*` artifact folder, and every folder under `handoffs/`
  other than its own that exists when it starts: earlier waves', earlier
  runs' not yet pruned, and, in a walk, every other member of the wave (the
  walker creates them all before it spawns any member, so they exist).
- **The reviewer keeps the frozen plan.** `claude-goal-review.sh` already
  takes `--add-dir`; `run-goal.sh` passes the handoff folder as a second
  `--add-dir` beside `$RUN_DIR`, so the brief's `PLAN:` path (the frozen
  copy) stays readable to Opus.
- Step 0 also measures this: from inside the implementer sandbox with these
  settings, `cat` of a file in its own `$RUN_DIR` and in another goal's run
  and handoff folders is refused, and its own handoff folder reads and
  writes.

### 7. Tests and evidence

- `scripts/tests/proof-sandbox-test.sh`: the generator (path refusals,
  missing paths, `@HOUSE`, rule order), each profile rule against a real
  `sandbox-exec` run (every step 0 probe that can run unattended, including
  the self-test's own-port and foreign-listener pair: writes,
  each secret path including one inside the root, `.git`, symlink, hard link
  creation, the hard-link pre-check, copies of `open`/`osascript`/
  `sandbox-exec` in the root, `securityd`, localhost on both addresses vs a
  public address with `EPERM`, `--network`, `--setup`), the self-test and
  `proof-sandbox-unavailable` (a fake `sandbox-exec` that fails, and one that
  runs the command unsandboxed: the self-test must catch it), the environment
  (`SSH_AUTH_SOCK`, `GIT_CONFIG_*`, caches), the denial listing, and
  `CW_PROOF_SANDBOX=off` (journaled, header).
- `goals-*` tests for `proof_network` (only `true` turns it on; `false`,
  `yes`, `True` are refused by `validate`).
- `proof-test.sh`, `proof-fix-test.sh`, `plan-freeze-test.sh`, the
  parallel-walk tests and `implement-test.sh` updated for `PROOF_ROOT`, the
  moved implementer folder, `--handoff-dir`, `--deny-read`, the reviewer's
  second `--add-dir`, and the shared secret list.
- **Tests whose attack the sandbox now blocks earlier get new oracles,** so
  they cannot stay green for the wrong reason. In
  `parallel-walk-trust-test.sh`, the `worktree_setup` that rewrites
  `commondir` outside the worktree now dies with `EPERM`: that case expects
  `worktree-setup-failed`. The gitfile pin keeps its own test, which plants
  the rewritten `commondir` from outside the sandbox (as an implementer
  could) and runs setup unsandboxed (`CW_PROOF_SANDBOX=off`), so the pin is
  still what stops it. Every existing test touched by this plan is read for
  the same failure before it is changed.
- Every new check is planted red, including multi-layer plants where two
  rules guard one path (the mach denial and the exec denial; the profile and
  the hard-link pre-check).
- The rbtree parallel re-run (the next walk) runs under the sandbox and is
  recorded in this feature's `EVIDENCE.md`.

## Key decisions & tradeoffs

- **Q1, mechanism: the house's own SBPL profile under `/usr/bin/sandbox-exec`.**
  No new dependency, one auditable file, every rule testable. Costs: Apple
  marks `sandbox-exec` deprecated (Claude Code's sandbox relies on the same
  mechanism), and the house owns the profile's correctness. Rejected:
  Anthropic's `sandbox-runtime` npm package (a Node dependency on every proof;
  `npx` is not on PATH here), and routing the proof through a sandboxed
  `claude -p` (a model session per proof).
- **Q2, reads: deny known secret paths (b), not all of `$HOME` (a).** User's
  choice. Few false reds; a secret not on the list stays readable by a proof,
  and redaction is then the only guard between it and a model provider. The
  house's own state folders are added to the list because a proof can print
  them into a fix handoff.
- **Q3, network: localhost only for proofs; `proof_network: true` opts a walk
  in; `worktree_setup` keeps the network.** SBPL cannot allow by host name.
  Known limit: an install script run by `worktree_setup` (possibly a
  dependency the implementer added to a lockfile) has the network and, under
  (b), can read anything not on the secret list (see Risks).
- **Q4, fail closed.** A self-test before any implementer pass;
  `proof-sandbox-unavailable`; `CW_PROOF_SANDBOX=off` only from the host's
  environment, journaled.
- **Q5, move the implementer's folder out, deny whole folders.** A plain
  folder deny, no rule that excepts a subfolder (Claude Code's rule order is
  undocumented). The folder goes under `handoffs/`, not beside `$RUN_DIR`, so
  `runs/` can be denied whole and a parallel walk's other run folders are
  covered too.
- **The proof's own profile does use rule order:** secret and house-state
  denials come after the `--root` allow, and a final `--tmp` allow comes after
  the house-state denials. That is the house's own profile, measured in step 0
  and planted in tests, not Claude Code's.
- **Shared caches are not shared with proofs.** npm, uv and pip caches point
  into the run's `$TMPDIR`: slower installs, but no install script run by a
  proof or `worktree_setup` can poison a cache other repos use.

## Assumptions

1. Every proof, `worktree_setup` and merged proof runs through `proof_exec`
   (`run-goal.sh:1015`, `wave-walk.sh:466` in `run_setup`, used for both the
   goal's worktree and the scratch tree, and `wave-walk.sh:663`). Source: grep.
2. The house targets macOS only. Source: README, SETUP.
3. `/usr/bin/sandbox-exec` works on Darwin 27. Measured:
   `sandbox-exec -p '(version 1)(allow default)' /bin/echo` ran.
4. SBPL filters network by address and port, not host name. Source: SBPL;
   step 0 confirms localhost-only.
5. The implementer's current read denials are three paths
   (`claude-implement.sh` `settings_json`); its Read, Edit and Write tools
   reach the repo and the handoff folder (`--add-dir`).
6. The launcher strips credential-named variables and three `CW_*` settings
   from the implementer's environment (`env_unsets`), not every `CW_*`.
7. Out of scope: the legacy `IMPLEMENTER=codex` launcher, Linux, and the Opus
   reviewer (read-only, no shell).

## Risks / open questions

- A toolchain may need a mach service or a path step 0 did not exercise
  (a later language, a new Xcode). It shows as a red proof naming "Operation
  not permitted"; the fix is a measured profile change, not a per-goal key.
- `sandbox-exec` could be removed in a future macOS. The self-test then stops
  every walk with `proof-sandbox-unavailable`, and `CW_PROOF_SANDBOX=off` is
  the user's deliberate fallback.
- A proof inherits the user's environment minus credential-named variables;
  a secret in a variable with another name stays visible to it, as today.
- The walker's state is protected from the proof by the profile, but not from
  `worktree_setup`'s network (it can upload what it can read).
- Surfacing denials depends on the unified log; if step 0 finds no reliable
  per-run method, the listing is dropped and denials are diagnosed by hand
  (`log show`), which the plan would then say.

## Out of scope

- Linux (bubblewrap) support.
- The legacy `IMPLEMENTER=codex` launcher.
- Sandboxing the Opus reviewer.
- Host-name network allowlists (needs a proxy).
- Denying all of `$HOME` (Q2 option (a)).

## Amendment 1 — step 0's findings (user-approved, 2026-10-16)

The evidence is `EVIDENCE.md`, "Step 0". Where this amendment and the steps
above disagree, this amendment wins.

### A. Network: none by default (changes Q3)

SBPL cannot express "only ports the proof itself bound" or a port range, a
loopback-only bind rule still allows a bind to `0.0.0.0` (a sandboxed server
bound there accepted a connection from the machine's LAN address), and an
outbound loopback rule reaches every host loopback service. No measured
proof needs loopback. So:
- **Default:** no `network-bind`, `network-inbound` or `network-outbound`
  allowance at all; any socket operation fails with `EPERM`.
- `proof_network: loopback` (GOALS.md preamble) allows loopback bind, inbound
  and outbound, accepting the two exposures above; `proof_network: true`
  allows the full network. `goals.py validate` accepts exactly `loopback` and
  `true`; the key absent means none.
- `worktree_setup` keeps the full network (`--setup`), as before.
- The self-test (step 4) checks that a TCP connect to a public address and a
  connect to a listener the harness started on `127.0.0.1` both fail with
  `EPERM`, and a public DNS lookup fails. The own-port listener check is
  dropped. Under `proof_network: loopback` the walk's header names the two
  measured exposures (any loopback service on the host is reachable; a server
  bound to all interfaces is reachable from the LAN), and so does the key's
  note in `skills/to-goals/GOAL-FORMAT.md`.
- **Tests (replaces the loopback items of step 7):** `proof-sandbox-test.sh`
  asserts the amended self-test pair (public address and host listener both
  `EPERM`) under the default profile; under `--network loopback` that a
  public address is still `EPERM` and a host loopback listener is reachable;
  under `--network true` that a public connect is attempted (no `EPERM`).

### B. No live `.env` in a walked checkout (extends Q2; user, 2026-10-16)

Step 0 found that a target repo's own `.env` (gitignored, unseen by the tamper
check) was readable to a proof. Denying it by pattern inside a checkout the
implementer can write turned into a run of patches, each answered by the next
trick (a hard link, a copy, a rename, a case variant). The user chose to close
the class instead:
- **The gate.** Before the first `proof_exec` of any run (so before every
  `worktree_setup`, which has the network) and before any implementer pass:
  once at the start of a walk in `run-goals.sh`, before it cuts or sets up any
  worktree, and in `run-goal.sh` at its start, fresh and resume. The host scans
  every checkout of the repo (`--root`, the main checkout, every worktree) for
  any directory entry (a file, a symlink whatever it points to, or a folder)
  whose name is `.env` or starts with `.env.`, case-insensitively, at any depth, except
  `.env.example`, `.env.sample` and `.env.template`, and except under `.git`
  and dependency folders (`node_modules`, `.venv`, `venv`, `site-packages`,
  `target`, `vendor`), which ship their own. Any hit stops with
  `secrets-in-checkout`, naming the entries and the fix: move the secrets out
  of the repo into `~/.config/cw-secrets/<project>/`, a folder added to the
  secret list (step 2) for this purpose, so proofs and the implementer cannot
  read it; leave no symlink behind.
- **Opt-out.** `CW_ALLOW_DOTENV=1`, set by the user in the launching
  environment, skips the gate; it is journaled (`ORCHESTRATOR dotenv allowed`)
  and printed in the walk's header, like `CW_PROOF_SANDBOX=off`. With it, the
  files stay readable to proofs and the implementer, knowingly.
- **What this removes:** no `.env` pattern in the profile, no per-file
  `--deny-read` for the implementer, no `.env` rule in the hard-link pre-check.
  A `.env.test` a goal itself creates is ordinary test data.
- **Tests:** the gate stops on `.env`, `sub/.ENV.local`, a nested
  `.env.prod`, and a `.env` symlink to a file outside the repo; it runs before
  the walk's first `worktree_setup` (a setup that would read the file never
  starts); passes on `.env.example` and on a `.env` under `node_modules`;
  the opt-out is journaled; the walker scans the main checkout and every
  worktree.

### C. Profile fixes within the plan's intent

1. The hard-link operation is `file-link`. A link is allowed only when both
   ends are inside the same tree: one `(allow file-link (subpath …))` rule for
   `--root` and one for `--tmp` (and, under `--setup` only, one for the
   dependency folder (D), which proofs may only read). Measured: inside→inside
   allowed; outside→inside, inside→outside and `--root`→`--tmp` refused; and a
   link to a read-denied file inside the root refused, because the link's
   source must itself be accessible. As a second layer, `file-link` is denied
   explicitly on every secret-list path, after the link allows. Every other `file-link` is denied,
   again after the final `--tmp` allow. The pre-run walk (step 3) stays.
2. `file-read-metadata` on the literal parent folders of `--root`, `--tmp` and
   the dependency folder (compilers resolve their `$TMPDIR`; this reveals only
   that those folders exist).
3. The output file: `proof-sandbox.py --out FILE` allows
   `file-read-metadata` and `file-write-data` on that one literal path (a tool
   looks up its own output file; the proof can already write it through its
   descriptor).
4. The generator refuses (exit 2, `proof-sandbox-path`) a `--root` that sits
   under any denied path: such a checkout can never be proved.
5. Under `--setup` only: `mach-lookup com.apple.trustd.agent` (pnpm verifies
   TLS through the system) and reads and writes of
   `/private/tmp/pnpm-store-operation-locks-<uid>` (pnpm's fixed lock folder,
   also walked by the hard-link pre-check of later proofs).
6. The denial listing (step 3) is the denials logged during the run's time
   window. It cannot be per-run (`(with message …)` does not reach the kernel
   log), so it is headed "denials logged during this proof (may include other
   proofs running at the same time)". It stays diagnosis only.

### D. One dependency folder per walk

Rust and Go keep downloaded dependencies and build caches outside the repo
(`~/.cargo/registry`, `~/go/pkg/mod`, `~/Library/Caches/go-build`), which the
profile does not let a setup write, and a per-run `$TMPDIR` is gone before the
proof runs. So:
- Each walk (and a serial `run-goal.sh`) has one dependency folder,
  `$CW_CACHE/deps/<repo_id>-<walk id or run id>/` (0700), made by the host
  before the first `worktree_setup`.
- `worktree_setup` (`--setup`) may write it; proofs and merged proofs may only
  read it (`--deps DIR` in the generator: read for proofs, read and write for
  setup).
- Links inside it are allowed only under `--setup` (C.1).
- `proof_exec` points the language caches into it: `CARGO_HOME`,
  `GOMODCACHE`, `npm_config_cache`, `UV_CACHE_DIR`, `PIP_CACHE_DIR`, and pnpm's
  `npm_config_store_dir`. A proof's own build caches (`GOCACHE`,
  `XDG_CACHE_HOME`) go to its private `$TMPDIR`.
- It is not under a denied house folder, it is walked by the hard-link
  pre-check, and it is removed when the walk ends (and pruned past
  `CW_PRUNE_DAYS` if a walk dies).
- Known limit: within one walk, one goal's `worktree_setup` can write
  something into the folder that another goal's proof then reads or runs. Each
  of those proofs already runs implementer code, so it adds no kind of access
  a proof lacks; it is stated, not closed.

### E. A first-use smoke test for each new language

`skills/to-goals/SKILL.md` gains a check: before the first goal in a language
the house has not yet proved under the sandbox (today: C with CMake,
TypeScript with Vitest or node:test, Python with pytest and uv), run one
`worktree_setup` and one proof of a small project of that language under the
profile, and record in the feature's evidence that both pass and nothing new
is denied. A failure there is a profile change, made and reviewed before the
walk, not a red proof mid-walk.
