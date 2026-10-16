# Evidence: sandbox the host proof (house item 12)

## Step 0: measurements before any code (2026-10-16)

Setup: macOS 27.0.1 (26A434), Apple Silicon, `/usr/bin/sandbox-exec`,
Command Line Tools at `/Library/Developer/CommandLineTools`, Homebrew gcc 16.2.0,
CMake from Homebrew. The profile is a hand-built draft (`gen.py` in the job's
scratch folder), written to PLAN steps 1 and 3; checkouts are fresh
`git clone --no-hardlinks` copies under `~/dogfood/pss0/`, and each run's
`$TMPDIR` and output file sit under `~/.cache/claude-coding-workflow/runs/`,
where `run-goal.sh` will put them.

### How denials are seen

- `/usr/bin/log show --predicate 'sender == "Sandbox"'` lists each denial
  (process name, pid, operation, path) about 3 s after it happens. (`log`
  without its path is zsh's builtin, which prints "too many arguments".)
- The listing is system-wide: other daemons' denials (`mds`,
  `XprotectService`, `replayd`) appear in the same window.
- `(deny default (with message "<tag>"))` does **not** put the tag in the
  kernel's line. A run's own denials can be picked out by time window only,
  which is exact for one proof at a time and mixed when several run at once.
- `(trace "<file>")` writes nothing on this macOS.

### Profile fixes the measurement forced

1. **`file-link*` is not an operation name** (`unbound variable`); the
   operation is `file-link`, and `(deny file-link)` refuses `ln` (measured:
   `ln a b` → "Operation not permitted"; control without it succeeds).
2. **A checkout under a denied path cannot be proved.** A checkout inside
   `~/.claude/...` (on the secret list) was denied whole, as the secrets-last
   rule intends. The generator must refuse a `--root` under any denied path,
   not run a proof that cannot work.
3. **Parent metadata.** `cc1` resolves its `$TMPDIR` and is denied
   `file-read-metadata` on `~/.cache/claude-coding-workflow/runs` (a denied
   house folder). Allowing `file-read-metadata` (only) on the literal parent
   folders of `--root` and `--tmp` reveals only that they exist.
4. **The output file.** A proof whose stdout/stderr file sits in a denied
   folder fails its build (`make: *** [all] Error 2`, no compiler message)
   because a tool looks up its own output file's metadata; the same proof
   writing to an allowed folder passes. Writes through the open descriptor
   work. Fix: the generator takes the output file and allows
   `file-read-metadata` and `file-write-data` on that one literal path (the
   proof can already write it through its descriptor).

### C proofs (rbtree, uregex)

Every mach lookup denied (no mach allowance at all), network loopback only,
writes only to the checkout, `$TMPDIR` and the output file:

| Proof | Sandboxed | Unsandboxed |
|---|---|---|
| rbtree g1 (default + ASan/UBSan builds, 9 tests) | rc 0, 19 s | — |
| rbtree g7 | rc 0, 19 s | rc 0, 21 s |
| uregex g1 (13 tests) | rc 0, 21 s | — |
| uregex g7 | rc 0, 18 s | rc 0, 19 s |

Denied and harmless during these builds: `mach-lookup` of
`com.apple.bsd.dirhelper`, `opendirectoryd.membership`/`libinfo`,
`notification_center`, `logd`, `analyticsd`; `system-info vfs.disk-space`.

### TypeScript proofs (ts-tier-rules fixture, the `impl` variant)

- **Setup** (`--setup`, network on): `npm ci --no-audit --no-fund` with
  `npm_config_cache` and `XDG_CACHE_HOME` under the run's `$TMPDIR`: rc 0,
  2 s, both fixtures. (npm 11 printed that install scripts were not run, its
  own default.)
- **Proof** (default profile, loopback only): Vitest (`tsc --noEmit` then
  `vitest run`, 7 tests) rc 0; node:test (`tsc` then `node --test`) rc 0. Both
  also rc 0 unsandboxed; no time difference at this size. Denied and harmless:
  `mach-lookup` of `notification_center`, `logd`,
  `SystemConfiguration.DNSConfiguration`.

### Python proof (a minimal pytest project, uv-managed CPython 3.14)

- **Setup:** `uv sync --frozen` with `UV_CACHE_DIR` under `$TMPDIR` and
  `UV_LINK_MODE=copy`: rc 0, 1 s. The managed interpreter's attempts to write
  `.pyc` files into `~/.local/share/uv/python/...` were denied, which is the
  intent (no setup writes into an interpreter every project shares); nothing
  broke.
- **Proof:** `.venv/bin/python -m pytest -q -p no:cacheprovider`: 2 passed,
  including a `tempfile` test (the private `$TMPDIR` works).

### pnpm (12.11.2, Rust)

pnpm is the package manager the plan names for hard links. Under the setup
profile it needs three things npm and uv do not:
1. **`mach-lookup com.apple.trustd.agent`**: it verifies TLS through the system
   trust service (Node carries its own CA bundle; uv its own roots).
2. **Its fixed lock folder** `/private/tmp/pnpm-store-operation-locks-<uid>`,
   inside the denied temp area (otherwise "File exists (os error 17)").
3. **Hard-link probes inside the checkout** (`_tmp_<pid>_*` files linked to
   test whether the store can hard-link).

With those (setup only) and `npm_config_store_dir` under `$TMPDIR`,
`npm_config_package_import_method=copy`: rc 0, 3.2 s.

### Hard links: `file-link` checks both ends

`(deny file-link) (allow file-link (subpath ROOT))`, measured with `ln`:

| Link | Result |
|---|---|
| inside ROOT → inside ROOT | allowed |
| outside → inside ROOT | refused |
| inside ROOT → outside | refused |

So the profile can allow links whose source and destination are both inside
`--root` or `--tmp` (what package managers need) without letting a proof pull
an outside file in. This is narrower than PLAN step 1's blanket
`(deny file-link)` and keeps its purpose; the pre-run walk is still needed
for links the implementer left before the run (it runs outside this profile).

### The hard-link pre-check on real trees

Counting, per regular file, the names it has inside the walked trees against
its link count:

| Tree | Files | Names outside |
|---|---|---|
| ts-vitest after `npm ci` | 1157 | 0 |
| ts-node-test after `npm ci` | 685 | 0 |
| py-pytest after `uv sync` | 536 | 0 |
| rbtree after both builds | 577 | 0 |
| uregex after both builds | 710 | 0 |
| ts-pnpm after `pnpm install` (copy mode, store in `$TMPDIR`) | 1171 | 0 |

No false alarms. A pnpm store inside the checkout also gives 0, but it is
untracked and not ignored, so the tamper check would stop it; the store
belongs under `$TMPDIR` with copy mode.

### Escape probes (draft profile, checkout `~/dogfood/pss0/probe`)

Contents of secret files were never printed: each probe records only whether
the open succeeded.

| Probe | Result |
|---|---|
| write `~`, append `~/.zshrc`, create a LaunchAgent, write another repo | refused |
| write the run folder, `logs/`, the checkout's `.git/hooks` and `.git/` | refused |
| read `~/.claude/settings.json`, the house `.env`, `~/Library/Keychains`, `runs/` | refused (all exist) |
| read `~/.ssh/known_hosts` | refused (file absent here; `ls ~/.ssh` refused) |
| read `/private/var/folders` | refused (`getconf DARWIN_USER_TEMP_DIR` returns `$TMPDIR` inside the sandbox; the first "escape" was that artefact) |
| a symlink in the checkout to `~/.ssh/known_hosts` | refused (Seatbelt checks the resolved path) |
| `ln` of an outside file into the checkout or into `$TMPDIR` | refused |
| `curl https://example.com`, `getaddrinfo`, TCP to 1.1.1.1:443 | refused; the connect fails with **`EPERM`** |
| `open -a Calculator`; a compiled program calling `LSOpenCFURLRef` | refused (`LSOpen status=-10661`; `coreservicesd`, `lsd.modifydb` lookups denied) |
| `osascript` sending a real AppleEvent (`get name of startup disk`) | refused (`launchservicesd` denied; `return 1` sends no event, the first "escape" was that artefact) |
| `launchctl submit` | refused |
| `security list-keychains` | refused (works outside the sandbox) |
| `git credential-osxkeychain get` | 0 bytes returned |
| connect to the ssh agent socket (`SSH_AUTH_SOCK`) | refused |
| a nested `sandbox-exec -p '(allow default)'` writing `~` | refused (nested profiles cannot widen) |
| copies of `open`, `osascript`, `launchctl`, `security`, `sandbox-exec` in the checkout | killed by the system (`Killed: 9`, code signing) before running |

**Real gaps the probes found:**
1. **The checkout's own `.env`.** The secret list names absolute paths, so a
   target repo's `.env` (gitignored, never seen by the tamper check) was
   readable and writable. A regex rule closes it: `.env` and `.env.*`
   anywhere under `--root` refused, `.env.example|sample|template` readable;
   measured refused also through `..` and through a symlink.
2. **Binding to `0.0.0.0`.** `(local ip "localhost:*")` does not stop a bind to
   all interfaces, and a sandboxed server bound there **accepted a connection
   from the machine's LAN address** (192.168.0.4). `"127.0.0.1:*"` is not
   valid SBPL.
3. **A loopback listener outside the sandbox.** `(remote ip "localhost:*")`
   reaches any host loopback service (a stand-in on 127.0.0.1:2375 accepted).
   SBPL takes one port per rule (`localhost:5000` refuses 2375) and no ranges
   (`localhost:1024-65535` does not load), so "only ports the proof bound" and
   "ports above 1023" cannot be written.

### Proofs with no network at all

With every `network-bind`, `network-inbound` and `network-outbound` allowance
removed: Vitest rc 0, node:test rc 0, pytest rc 0, rbtree g1 (both builds) rc
0. None of the measured proofs needs loopback.

### Changes to the plan this evidence asks for

Within the plan's intent (no new decision):
- `file-link` is the operation (not `file-link*`); links are allowed only when
  both ends are inside `--root` or `--tmp`, the pre-run walk stays.
- `file-read-metadata` on the literal parent folders of `--root` and `--tmp`.
- The output file: `file-read-metadata` and `file-write-data` on its literal
  path (`--out`).
- The generator refuses a `--root` under any denied path.
- Under `--setup` only: `mach-lookup com.apple.trustd.agent` and pnpm's lock
  folder `/private/tmp/pnpm-store-operation-locks-<uid>` (walked by the
  hard-link pre-check); pnpm's store under `$TMPDIR` with copy mode.
- Denials cannot be told apart per run (`with message` is not logged): the
  listing appended to a proof's output is the time window's denials, labelled
  as possibly including other proofs running at the same time.

For the user (they change a locked decision):
- **Q3, network:** no network at all by default (not even loopback), with
  `proof_network: loopback` and `proof_network: true` as opt-ins, instead of
  loopback by default.
- **Q2, reads:** add `.env` and `.env.*` inside the checkout to the denials
  (the examples stay readable).

### Amendment 1 review: links and case (measured)

With `(deny file-link) (allow file-link (subpath ROOT)) (allow file-link
(subpath TMP))` and the `.env` regex read/write denial:
- `ln normal.txt nl` inside the root: allowed (control);
- `ln .env leaked` inside the root: **refused** (a link's source must be
  accessible to the process);
- `ln .env $TMP/leaked` (root → tmp): refused (each allow is one tree);
- the lower-case `.env` regex refuses `.ENV.probe` too (Seatbelt matched it
  case-insensitively on this APFS volume) while `normal.txt` stays readable;
- an inline `(?i)` flag is not valid SBPL regex ("unexpected ^ operator").
