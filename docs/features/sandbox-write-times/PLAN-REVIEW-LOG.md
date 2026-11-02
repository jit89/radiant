# Plan Review Log: the proof sandbox allows setting file times (macOS 27)
Phases 0-1 (recon + interrogation) complete — plan locked with the user. MAX_ROUNDS=5.

## Round 1 — Grok

I'll review the sandbox write-times plan against the domain docs and the code it depends on, looking for concrete breaks rather than style nits.The profile change matches the measured precedence only when every write allow and every write deny carries both `file-write*` and the nine named operations, with the denials after the allows and the `--tmp` re-allow last. As written, the plan still ships a wider gate than that, and its tests do not pin the holes that widening creates.

1. `file-write*` allows operations the nine names leave out. The risk note says the wildcard covers flags, owner, and extended attributes. Those are already in `WRITE` (`proof-sandbox.py` lines 39–41): `file-write-flags`, `file-write-owner`, `file-write-xattr`. The names already probed and rejected for `touch` — `file-write-acl`, `file-write-finderinfo`, `file-write-mount` — are real operations the compiler accepts, and they are not in `WRITE`. A `file-write*` allow on `--root`, `--tmp`, `--deps`, and the pnpm lock folder turns them on. Assumption 3 says a named rule beats a wildcard whatever the order, so they can be closed without blocking the unnamed times operation. No test checks them.
   Fix: on those same trees, add a named deny for `file-write-acl`, `file-write-finderinfo`, and `file-write-mount`, and assert each still returns `EPERM` in the root.

2. The refused house-state and `run-goal-*` checks, and plant P2, sit outside every write allow. In `proof-sandbox-test.sh`, `ROOT` is `$TMP/root` and the cache is under `$TMP/home` (lines 9, 27–28). `$CW_CACHE/runs` and a cache `run-goal-*` folder are not under `--root` or `--tmp`, so `(deny default)` already refuses the unnamed operation there. P2 (wildcard only on the allows) stays green for those cases. Row A opens only where an ancestor allow matches. The file already builds that layout for reads (lines 88–111) and never writes house state or `run-goal-*` there.
   Fix: pre-create the secret, `runs/`, `logs/`, and `run-goal-*` files inside the root, attempt `os.utime` on each, and require `EPERM` with the mtime unchanged. That is the P2 red set.

3. Nothing plants row E. P2 keeps the nine names on the denies. P3, read the same way, keeps them on the allows. Dropping the nine names and leaving `(deny file-write* …)` makes a named allow on the parent beat that deny for create, write, and unlink no matter the order (row E and `EVIDENCE.md` lines 223–226). Times on `.git` stay refused, so a times-only check stays green while `.git` and an in-root secret become writable.
   Fix: add a plant whose denies are `file-write*` alone, and require the existing in-root write denials (`.git`, secret) to go red.

4. `plant-runs-on-copies` is not in the repo. `proof-sandbox-test.sh` sets `GEN` to `scripts/lib/proof-sandbox.py` (line 12) and sources `proof-sandbox.sh` from that same tree (line 233). A copy of `lib/` is what the two self-test copies already do, and the full file never reads it. Pointing a plant at the house tree either tests the unmutated generator or edits the live `lib/` while `run-all -j` is using it.
   Fix: copy `scripts/` to a temp tree, mutate the copy, point `GEN` and the sourced self-test at that copy, and run the copied test there.

5. The refused-case oracle treats the wrong failure as a times denial. `tar -x` of a new member in a denied tree fails on `file-write-create`, which is already named in the deny, so the archive member never exists and its mtime is not evidence about the unnamed operation. `touch -t` with the file's current stamp can succeed and still look unchanged. The suite section never requires `EPERM`. The self-test does, but `/usr/bin/touch` does not report it. A missing `.git` file also fails on `file-write-create`, so plant P2's self-test stays green.
   Fix: on a pre-created file, set a fixed old stamp, call `os.utime` to a different stamp through the existing `errno` helper, and accept a refusal only when the result is `EPERM` and both stamps are unchanged. Keep `tar -x` on the allow side.

VERDICT: REVISE

### Architect's response
All five points were taken.
1. Taken. A named deny of file-write-acl, file-write-finderinfo and file-write-mount goes on each allowed tree, after the allows. Measured on 27.0.1 under a file-write* allow: an ACL write succeeds without the deny and is refused with it, and touch still works. Writing FinderInfo through xattr -w is checked as file-write-xattr, which today's profile already allows, so it is no widening. The finderinfo and mount denies have no unprivileged probe and are recorded unproved. The risk note now states that an operation nobody has named would open on the allowed trees only. Plant P6 (the extra deny removed) turns the ACL case red.
2. Taken. The refused time cases run with HOME inside the root (the self-test's shape), so .git, the secret path, runs/, logs/ and run-goal-* are beneath the root's write allow, where row A's hole opens. The control case outside every tree is kept.
3. Taken. P5: denies carry file-write* alone. The existing in-root write denials must go red.
4. Taken. Plants copy scripts/ to a temporary tree and mutate the copy; the copy's test resolves GEN and the sourced self-test inside the copy, which the build checks first.
5. Taken. Each case uses a pre-created file with a fixed old stamp and Python os.utime to a new one, through the errno helper. Allowed means success and the stamp read back; refused means EPERM with both stamps unchanged. tar -x stays on the allow side only. The self-test's checks use the same shape.

## Round 2 — Grok

I'll re-read the revised plan and check each earlier finding against the current text and the code it cites.The earlier holes are written into the plan. I'll check the new deny placement and the plant harness against the generator and the test file.The five earlier findings are in the plan: the three-name deny, the in-root refusal set, plant P5, the `scripts/` copy, and the pre-created `os.utime`/`EPERM` oracle. Two of those repairs do not hold.

1. The acl/finderinfo/mount deny sits before the secret denials, and the `--tmp` re-allow stays last with `file-write*` inside `WRITE` (`proof-sandbox.py` line 200). For a file in `--tmp` the order is a named deny, then a later wildcard allow. Row A is the other way around (wildcard allow, then named deny). Row E and `EVIDENCE.md` lines 223–226 are a named allow beating a later wildcard deny. Neither row is this order. The ACL probe runs only in the root, where no later `file-write*` allow covers the file, so it stays green if the re-allow reopens `file-write-acl` on `--tmp`. The risk bullet also says all three operations are tested. Only the ACL write has a probe. FinderInfo via `xattr -w` is `file-write-xattr`, and mount is unproved.
   Fix: emit `(deny file-write-acl file-write-finderinfo file-write-mount …)` after the `--tmp` re-allow, and require the ACL write to return `EPERM` in the root and in `--tmp`.

2. A copy of `scripts/` cannot finish `proof-sandbox-test.sh`. The test reads `$HERE/../GOALS.example.md` (lines 272 and 277) under `set -e`, and the self-test starts at line 279. The parent of a copied `scripts/` has no `GOALS.example.md`, so `sed` aborts first. The clean copy exits non-zero, and P1 and P2 never reach the self-test checks the plan says must go red.
   Fix: stage `GOALS.example.md` next to the copied `scripts/` so the copied test runs through the self-test.

P4 still says the refused cases go red. The outside-tree control has no ancestor allow, so it stays refused. Only the in-root refusals go red.

VERDICT: REVISE

### Architect's response
All three were taken.
1. Taken. The acl/finderinfo/mount deny is emitted last among the write rules, after the --tmp re-allow (which carries file-write*), so no later wildcard allow reopens it. The ACL probe runs in the root and in --tmp. The risk bullet now says only the ACL deny has a probe.
2. Taken. GOALS.example.md is staged beside the copied scripts/. The clean copy must run green to the end before any plant counts.
3. Taken. P4: only the in-root refused cases go red; the outside control stays refused.

## Round 3 — Grok

I'll re-read the revised plan and check the last round's findings against the generator and the test file.The three round-2 findings are fixed in the plan. The acl/finderinfo/mount deny is emitted after the `--tmp` re-allow, the ACL probe requires `EPERM` in the root and in `--tmp`, and the risk note limits the probe to the ACL write. `GOALS.example.md` is staged beside the copied `scripts/`, and the clean copy must finish green before a plant counts. P4 now expects only the in-root refusals to go red.

The trailing deny is the measured order: a `file-write*` allow, then a named deny. On `--tmp` that is the re-allow at `proof-sandbox.py` line 200, then the new deny, so the re-allow cannot reopen `file-write-acl`. The root probe covers the early allow. FinderInfo and mount stay named denies with no unprivileged probe, which the plan records as unproved. The in-root time cases, P5, and the pre-created `os.utime`/`EPERM` oracle are unchanged and still match the generator.

VERDICT: APPROVED

### Architect's response
Converged: APPROVED in 3 rounds.
