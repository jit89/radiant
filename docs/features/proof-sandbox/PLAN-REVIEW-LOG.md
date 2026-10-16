# Plan Review Log: Sandbox the host proof (house item 12)
Phases 0-1 (recon + interrogation) complete — plan locked with the user. MAX_ROUNDS=5.

## Round 1 — Grok

I'll read the plan and the domain docs around it, then check the repo assumptions it depends on.The plan cites specific scripts and decisions. I'll check those against the code and the domain docs.The plan does not confine a proof. Several of the escapes it depends on are unenforceable by the profile it specifies, and two of its mechanisms do not match how the scripts actually run.

1. **A path allow on `--root` does not stop a hard-link write.** Seatbelt checks the path you open, not the inode. The implementer can leave a gitignored hard link in the checkout (`build/` and similar are invisible to `git status` and to `tree_snapshot`), and the proof can write that name and unlink it. `~/.zshrc` changes and the tamper check stays green. A symlink probe does not catch this.
   Fix: deny `file-link`, and immediately before `sandbox-exec` refuse the tree if any file under `--root` has `nlink > 1`.

2. **The keychain and local-socket brokers stay reachable, including under `--setup` and `proof_network`.** Denying `~/Library/Keychains` and `~/.ssh` does not stop `security`, `git credential fill` via `git-credential-osxkeychain`, or `SSH_AUTH_SOCK`. With network, that is an outbound copy of the user's GitHub credentials, and redaction never sees it. `~/.docker/config.json` is on the list, but `~/.docker/run/docker.sock` is not. An unscoped `(remote unix-socket)` allow makes the Docker socket a full escape.
   Fix: deny the `securityd` mach lookup in every profile, unset `SSH_AUTH_SOCK`, force `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` to `/dev/null`, deny `~/.docker` as a directory, and allow unix sockets only as explicit paths printed by step 0.

3. **Listed secrets inside `--root` are re-opened.** The house `.env` sits in the checkout this repo proves. The plan allows writes and reads of `--root` and never says the secret denials come after that allow. Last-match then leaves `.env` readable and writable, and because it is gitignored `proof_moved` ignores it.
   Fix: emit secret read and write denials after the `--root` and `--tmp` allows, and make step 0 plant a listed secret inside the root.

4. **`realpath` and "deny paths that do not exist yet" contradict each other.** `realpath` fails on a missing `~/.kube` or `~/.aws`. The generator will either abort on a normal machine or skip the path, so a file created later is not covered. A backslash is legal in a path and is not refused, and SBPL string literals treat `\` as an escape, so a checkout path can break out of the quoted literal.
   Fix: expand `~`, deny the literal path when `realpath` fails, and refuse any path outside `[A-Za-z0-9._/-]`.

5. **The escape list is bypassed by copying the binary.** `(deny process-exec (literal "/usr/bin/open"))` does not apply to a copy in `--root`. Step 0 runs the stock paths, so the probe goes red on the path rule and never records the mach services a copy, or a C program calling Launch Services, actually uses. The same copy of `/usr/bin/sandbox-exec` is the nested-profile probe that matters.
   Fix: step 0 must exec copies from `--root`, and the pass condition is that the copy still cannot open Launch Services, talk to `securityd`, or write outside `--root` under a nested `(allow default)`.

6. **The network self-test passes when the sandbox is not applied.** A connect to a closed public port returns `ECONNREFUSED` with no sandbox at all. The plan treats any failure as "denied before any packet."
   Fix: require errno `EPERM`, and also refuse `getaddrinfo` of a public name and a connect to `::1` only when the profile allows it. Allow both `127.0.0.1` and `::1`. Node listens on `::1`.

7. **`--setup` cannot run the setup commands the house already documents.** `npm ci` and `uv sync` write `~/.npm` and `~/.cache/uv`. `--setup` adds network and no write paths, and step 0 never runs those commands. The rbtree proofs can pass while the first TypeScript or Python walk is red.
   Fix: point those caches at `--tmp` from `proof_exec`, and add a fresh-tree `npm ci` and `uv sync --frozen` to the step 0 pass list.

8. **Sibling handoff denial cannot be built the way the plan says.** `deny_list` runs before `run-goal.sh` is spawned (`wave-walk.sh` around line 916), and the handoff directory is an unpredictable `mktemp` created inside `run-goal.sh`. Each wave member's deny list therefore misses the others' directories, including ones created a moment later. Q5 forbids excepting a child under `handoffs/`, so denying the parent is not available. The resume pointer is also wrong: resume already rebuilds handoffs from `ART_DIR` and `git show`, and the new `$RUN_DIR` does not know the previous one.
   Fix: the walker creates each handoff directory before spawn, passes that path in, and writes every sibling into the deny file. Drop the `implementer-dir` pointer.

9. **Moving the frozen plan out of `$RUN_DIR` blinds the goal reviewer.** `claude-goal-review.sh` only receives `--add-dir` of the run directory, and the brief's plan path is that directory's `implementer/plan-at-base-*.md` (`plan-freeze-test.sh` line 75). The reviewer has no shell and no other grant.
   Fix: leave the frozen plan in `$RUN_DIR`, or pass the handoff directory as a second `--add-dir`.

10. **`proof_network` is a string in this YAML subset, and the shared secret file cannot name the house `.env`.** `parse_yaml_subset` stores `true` and `false` as strings, so a truthiness check treats `false` as on. A relative house `.env` line resolves against the target repo, not the house checkout.
    Fix: enable the flag only for the exact string `true`, reject every other value in `validate`, read it once from the main checkout beside `WORKTREE_SETUP`, and store `$HOUSE/.env` as a token the readers expand to the house path.

11. **A red proof is not what section 5 says it is.** `run-goal.sh` marks a proof red only on a non-zero exit or `Ran 0 tests`. It does not look for `Operation not permitted`. A proof that catches `EPERM` and exits 0 stays green. Denials also never name the path, because the profile has no `(debug deny)`, so step 0 and later toolchain reds are not diagnosable.
    Fix: add `(debug deny)` so the operation and path land in the proof log, and do not grep that string to decide red.

VERDICT: REVISE

### Architect's response

All eleven taken; three facts checked in the code first (9: the reviewer has only --add-dir "$RUN_DIR" and the frozen plan is under implementer/; 8: the walker builds deny lists before spawning members; 10: goals.py parses its YAML subset into strings).

1. Hard links: file-link* denied in the profile, plus a pre-run refusal (proof-hardlink) of any file outside .git with a link count above 1; writes to <root>/.git denied.
2. Brokers: securityd/keychain, Launch Services, AppleEvents and launchd lookups denied last; SSH_AUTH_SOCK unset; GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM set to /dev/null; ~/.docker denied whole; unix sockets only as explicit measured paths.
3. Secret denials (and house-state denials) are emitted after the --root allow; step 0 plants a listed secret inside the root.
4. Paths: ~ expanded, realpath only when the path exists, else the literal path plus its resolved parent; anything outside [A-Za-z0-9._/@+-] refused (proof-sandbox-path).
5. Escape probes run from copies placed in --root; the mach denials are the layer that must hold, the exec denials a second layer; a nested (allow default) from a copied sandbox-exec is a pass criterion.
6. Self-test requires EPERM (not ECONNREFUSED), a public DNS lookup refused, and localhost on 127.0.0.1 and ::1.
7. npm, uv, pip and XDG caches point into the run TMPDIR; step 0 runs fresh-tree npm ci and uv sync --frozen.
8. The walker creates every member's handoff folder before spawning and writes the others into each deny file (--handoff-dir); the implementer-dir pointer is dropped (resume rebuilds from ART_DIR and git show).
9. run-goal.sh passes the handoff folder as a second --add-dir to the reviewer.
10. proof_network on only for the exact string true, validate refuses any other value, read once from the main checkout; @HOUSE/ prefix in the secret list.
11. Taken with a change: red stays exit or Ran 0 tests (no string grep). (debug deny) logs to the unified log, not the process, so step 0 measures how to append each run's denials to the proof output for diagnosis; if no reliable method exists, the plan drops the listing and says so.

## Round 2 — Grok

I'll re-read the revised plan and check each previous finding against the code it depends on.The earlier holes in rule order, quoting, `EPERM`, caches, co-wave handoff creation, the reviewer path, and `proof_network` are fixed. The hard-link control and the network allow are not.

1. **The hard-link pre-check misses the plant and rejects ordinary trees.** It ignores `.git` and treats every other regular file with `nlink > 1` as fatal. `git-meta.py` only fingerprints `config`, `hooks`, and `info`, and `git status` never sees `.git`, so a link the implementer leaves at `.git/secret-link` (the sandbox blocks writes to `.git/hooks` and `.git/config`, not a new file beside the objects) is invisible. `link()` is not a read, so the implementer's new `denyRead` of `~/.ssh` does not have to stop it. The proof then reads that path. Seatbelt checks the path, and `<root>/.git/...` is still readable. The same check stops a real tree: pnpm, and npm or uv when they hardlink out of the cache on the same volume as `--tmp`, leave `nlink > 1` inside the checkout. Step 0 runs `npm ci` and `uv sync` and never runs this check afterward.
   Fix: walk `--root` (including `.git`) and `--tmp`, and fail only when `nlink` is greater than the number of names found there; add that tree to the step 0 pass list.

2. **The last SBPL rule can undo the hard-link denial.** The profile says the last match wins, denies `file-link*` in step 5, then ends with an allow of `--tmp`. A `file*` allow there re-opens `link()` inside `--tmp`, which the pre-check never scans because it is empty until the proof runs. The step 0 hard-link probe does not say the new link is created in `--tmp`.
   Fix: keep the tmp allow to `file-read*` and `file-write*`, repeat the `file-link*` denial after it, and probe `ln` of an outside file into `--tmp`.

3. **Loopback is specified only for outbound connects.** A server on `127.0.0.1` and `::1` also needs bind and inbound. Nothing refuses a bind to `0.0.0.0`, and nothing covers a Docker API already listening on `127.0.0.1` (the socket denies do not apply to that TCP port).
   Fix: allow bind and inbound only on `127.0.0.1` and `::1`, and add a step 0 probe that a bind to `0.0.0.0` and a connect to `127.0.0.1:2375` are refused.

4. **Handoff denial still stops at the current wave.** Folders from earlier waves and from the last 14 days stay in `handoffs/` and hold the other goals' frozen plans, return documents, and proof-fix excerpts. Raw logs in `runs/` are covered. These are not. Q5 already rules out denying the parent and excepting one child.
   Fix: at spawn, put every existing sibling under `handoffs/` on that member's `--deny-read` list, not only the other members of this wave.

5. **The trust tests will go green without proving the pin.** `parallel-walk-trust-test.sh` has `worktree_setup` write `commondir` outside the worktree. Under this profile that write dies with `EPERM`, setup fails, and the current assertions (filter never ran, g1 stopped, g2 integrated) still pass. The plan says to update the parallel-walk tests and does not say their oracles change.
   Fix: expect `worktree-setup-failed` for that attack, and keep a separate test of the pin that does not depend on setup writing outside `--root`.

Assumption 1 still cites `wave-walk.sh:643`. That line is a comment. The `proof_exec` calls are at 466 and 663.

VERDICT: REVISE

### Architect's response

All five taken, and the citation fixed.

1. The pre-check walks --root including .git, and --tmp, and fails only when a file's link count exceeds its names in those trees; installs copy out of caches (UV_LINK_MODE=copy, pnpm import method copy); step 0 runs the pre-check on npm ci, uv sync and pnpm trees.
2. The final --tmp allow is file-read* and file-write* only, and file-link* is denied again after it; step 0 probes ln into --tmp.
3. Bind, inbound and outbound on 127.0.0.1 and ::1 only; outbound loopback only to the sandbox's own ports if SBPL can express it, else ports above 1023 with the host-loopback probe deciding (brought to the user if not acceptable); probes for a 0.0.0.0 bind and a host loopback service (Docker 2375 stand-in).
4. Each member is denied every existing folder under handoffs/ but its own, not only this wave's.
5. Tests whose attack the sandbox blocks earlier get new oracles: the commondir-rewriting setup expects worktree-setup-failed; the gitfile pin keeps a test that plants from outside and runs setup with CW_PROOF_SANDBOX=off. Every touched test is read for the same failure.
Citation: wave-walk.sh:466 (run_setup, both trees) and :663.

## Round 3 — Grok

I'll re-read the revised plan and check the last round's findings against the code they rely on.The last round's five findings are fixed: the link-count check includes `.git`, the `file-link*` denial is repeated after the `--tmp` allow, loopback bind and a foreign listener are specified, handoff denial covers existing siblings, and the `commondir` test gets a new oracle. Two holes are left.

1. **The hard-link walk still misses the directory a worktree proof can read.** In a parallel goal the checkout's `.git` is only a gitfile. The admin and common gitdirs (`wave-walk.sh` writes `rev-parse --absolute-git-dir` to `$WAVE_DIR/$g.admin`) sit outside `PROOF_ROOT`, and the proof is allowed to read them. `git-meta.py` fingerprints only `config`, `hooks`, and `info`, so a new file there is invisible. The implementer can `link()` a secret into that directory (`link()` is not a read, so `denyRead` of `~/.ssh` does not have to stop it). The same plant works in the user temp dir under `/private/var/folders`, which the proof can search. Neither place is in the walk, so `nlink` inside the checkout stays 1 and `proof-hardlink` does not fire.
   Fix: walk the admin and common gitdirs too, deny proof reads of `/tmp` and `/private/var/folders` except `--tmp`, and point the step 0 plant probes at those directories.

2. **The self-test requires the loopback behavior step 0 forbids.** The profile allows outbound loopback only to a port the sandboxed process itself bound, and a connect to a listener started outside must be refused. Section 4 still says a connect to "a listener on `127.0.0.1`" works, which is how the old all-loopback rule was tested. A profile that satisfies that self-test accepts `127.0.0.1:2375`, and a profile that follows step 0 fails the self-test on every run.
   Fix: the self-test binds its own port inside the sandbox and connects to that, and a harness listener on another loopback port must fail with `EPERM`. Put that same pair in `proof-sandbox-test.sh`.

VERDICT: REVISE

### Architect's response

Both taken.

1. Fixed by the general rule, not only the two places named: every place the implementer's sandbox can write is either unreadable to the proof or covered by the hard-link walk. Step 0 lists that write set and plants a hard-linked secret in each. The walk now includes a worktree's admin and common gitdirs; the proof is denied reads of /tmp, /private/tmp and /private/var/folders except measured toolchain caches, which the walk then covers.
2. The self-test binds its own loopback port and connects to it, and a harness listener outside the sandbox must fail with EPERM; the same pair is in proof-sandbox-test.sh. If step 0 finds own-ports-only cannot be expressed and the user accepts ports above 1023, the self-test checks that instead.

## Round 4 — Grok

I'll re-read the revised plan and check the two open findings against the scripts they depend on.The last review stopped before the verdict. I'll re-read the revised plan and check the prior findings against the code.The two earlier holes are closed. The hard-link walk now covers `PROOF_ROOT` (including `.git`), `TMP`, a worktree's admin and common gitdirs, and any temp-area cache left readable, and the profile read-denies `/tmp`, `/private/tmp`, and `/private/var/folders`. The self-test now requires the sandboxed process's own `127.0.0.1` listener to accept a connect, and a connect to a harness listener on another loopback port to fail with `EPERM`.

The shared-temp deny is still three fixed prefixes, and `proof-sandbox.py` takes only `--root`, `--tmp`, `--network`, and `--setup`. The implementer is told to put scratch under `$TMPDIR` (`claude-implement.sh` lines 518–519), and `run-goal.sh` launches it with `env CW_OUT_DIR=...` without setting `TMPDIR`, so the directory is whatever the launching shell exported. When that path sits outside `/tmp` and `/private/var/folders` — `$HOME/tmp` is the usual case — the proof can open it. `link()` needs no read permission, so the implementer's denyRead of `~/.ssh` does not stop a hard link planted there; the walk never visits that directory, and `proof-hardlink` does not fire. Step 0 records one machine's `$TMPDIR`. A default `/var/folders/...` result adds no per-run input. The self-test also never reads a file under `/private/var/folders`, so dropping that deny leaves the every-walk gate green.

Fix: on every run, point the implementer's `TMPDIR` at a directory the proof already cannot read (inside its own handoff folder), or resolve the `TMPDIR` it actually inherited, pass that path into the generator, and read-deny it. Require `EPERM` in the self-test for a read under `/private/var/folders` and under that runtime temp when it is a different path.

Q3 still says the review sees the lockfile diff. Delete that sentence. The residual is already in Risks: `worktree_setup` can upload anything it can read.

VERDICT: REVISE

### Architect's response

Both taken. The launcher sets the implementer's TMPDIR to tmp/ inside its handoff folder (unreadable to every proof); step 0 checks the TMPDIR the implementer's shell actually sees under Claude Code's sandbox, and if Claude Code replaces it, that path must be under a denied prefix or the plan returns to the user. The self-test also requires EPERM for a read planted under /private/var/folders. The lockfile-diff sentence is deleted; the residual stays in Risks.

## Round 5 — Grok

The last review left one open hole: the implementer's `$TMPDIR` is not covered by the fixed temp denials. I'll read the revised plan and check that against the code.The earlier hole is closed. `claude-implement.sh` now sets the implementer's `TMPDIR` to `tmp/` inside its own handoff folder, which sits under `handoffs/` and is read-denied to every proof, so a hard link planted in the inherited shell temp (such as `~/tmp`) is no longer how a secret reaches the proof. Step 0 checks the `TMPDIR` the sandboxed shell actually sees, and if Claude Code replaces it the replacement has to sit under a denied prefix or the plan comes back to the user. The self-test now requires `EPERM` on a read of a file planted under `/private/var/folders` outside `--tmp`. The Q3 lockfile sentence is gone; the residual upload by `worktree_setup` is the Risks line.

The write-set measurement is still in step 0: every place the implementer sandbox can write is either unreadable to the proof or inside the hard-link walk. The repo and the worktree admin and common gitdirs stay on the walk; the handoff scratch does not, because the proof cannot open it. No new material hole.

VERDICT: APPROVED

## Resolution

APPROVED in round 5 of 5 (session 2099711b-dab9-41c2-966c-0faa2cbdc389). Findings per round: 11, 5, 2, 1, 0; all taken (round 1 finding 11 with a change). Awaiting user sign-off.
