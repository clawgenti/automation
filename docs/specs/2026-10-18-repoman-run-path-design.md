# RepoMan run path — design (`repoman run <program>`)

**Status:** approved for planning (2026-10-18)
**Epic:** [#72](https://github.com/rossoctl/automation/issues/72) — RepoMan multi-owner automation interface
**Issue:** [#107](https://github.com/rossoctl/automation/issues/107) — entrypoint skill + program invocation wiring (v0.1.0 completion). The setup/reconcile half of #107 shipped (automation #110, agent-skills #49); **this spec is the remaining "program invocation wiring" half.**
**Builds on:** architecture spec `docs/specs/2026-08-27-repoman-architecture.md` (§Program invocation flow, §Deployment), entrypoint-skill spec `docs/specs/2026-10-12-repoman-entrypoint-skill-design.md` (§Handoff to the run path).

## Summary

A single new orchestrator, `scripts/repoman-run.sh`, invoked as
`repoman run <program> [target...]`. It is **pure glue** over existing,
unchanged components: it turns a resolved program plus an (optional) enrolled
repo subset into an actual execution — capability check, clone refresh, scanner
exec, and `_index.json` registration — running only the steps each program needs.

No orchestrator exists today; every program is invoked standalone. This spec
defines the orchestrator, its per-program step table, and the contracts it
exposes to its callers (the `/repoman` skill, OpenClaw standing orders, DAM
schedules).

## Scope

**In scope (v0.1.0):** orchestrate the **5 non-fixer programs** —
`link-health` (scanner), `dep-bump` (scanner), `pr-review` (scanner),
`weekly-report` (scanner/wrapper), `automation-health` (index-consumer) — each
with per-program steps.

**Out of scope (deferred, tracked):**
- **Fixers** (`link-health-fixer`, `dep-bump-fixer`, `pr-review-fixer`) — they
  commit/push and hit the hardcoded commit identity (see §Commit & sign-off
  identity); deferred until the identity model settles ([#82](https://github.com/rossoctl/automation/issues/82)).
- **De-rossoctl-ing** the program scripts (hardcoded `REPORT_TARGET_REPO`,
  `SOURCE_REPO`, committer identity, personal `REPORT_PY` default) — its own
  tracked issue (see §Deferred work).
- **#99** (decouple scanners/fixers/dashboard from `repoman_config` — make them
  fully param-driven). The run path is built *param-first* so #99 later becomes
  a clean swap, but the refactor itself is v0.1.1.
- **#98** (`repoman_config` all-or-nothing key validation), **#115**
  (sourced-lib load-guard hygiene) — v0.1.1 / optional riders.
- **#76** (unify the program registry) — noted, not done here.

## The deployment contract (why non-interactivity is a hard requirement)

The architecture spec (§Deployment) states the program is invoked with an
**"identical invocation everywhere"** — both DAM pods and OpenClaw VMs run it on
a schedule as `task="repoman run ..."`. Therefore:

- **`repoman run` is the stable public contract.** Its CLI surface is what
  OpenClaw/DAM bind to. Internal mechanism choices (below) sit *below* this line
  and are swappable without a redeploy.
- **`repoman run` is fully non-interactive.** A scheduled invocation cannot
  prompt. All interactive setup (notably the first-invocation output-routing
  question) happens on the **skill/setup side** and is persisted to
  `~/.repoman/programs/<name>.json` *before* `repoman run` is ever scheduled.
- **State root is `$HOME`** on both targets (persistent volume / VM disk), with
  owner-namespaced clones under `repos_dir`. The orchestrator assumes nothing
  beyond a normal Unix `$HOME`.

## Architecture

```
repoman run <program> [target...]
  │
  ├─ 1. resolve program -> table row            (fail loud if not in table)
  ├─ 2. targets given? -> project subset:
  │        the /repoman skill has ALREADY reconciled targets to a concrete
  │        owner/name list (org-vs-repo detection, bare-name resolution, >=2-owner
  │        ambiguity) via repoman_match_name. The run path TRUSTS that list and
  │        does not re-interpret it; it only validates each is enrolled.
  │        write a throwaway repos.json to $TMPDIR; REPOMAN_REPOS_FILE points at it
  │        [skipped entirely for the index-consumer profile]
  ├─ 3. require output_repo set                  [only rows with posts_output=yes]
  ├─ 4. capability check: repoman-check.sh --program <p>   [skip for index-consumer]
  ├─ 5. clone refresh: repo-sync.sh              [only rows with needs_clone_refresh=yes]
  ├─ 6. exec the program                         (REPOMAN_REPOS_FILE=<temp> when subset)
  └─ 7. write _index.json entry                  [only rows with writes_index=yes; sole writer]
```

### Components

**New:** `scripts/repoman-run.sh` — the orchestrator; owns the program table and
the pipeline. bash 3.2-safe, `set -uo pipefail` (aggregate-then-decide, matching
`repoman-check.sh`), sources `program-lib.sh`.

**Reused, unchanged:**
- `scripts/repoman-check.sh` — capability gate (scope hard-gate, label warn).
- `scripts/repo-sync.sh` — owner-namespaced clone refresh.
- `scripts/repoman-index.sh` — `_index.json` writer
  (`--program --display-name --report-path`).
- `scripts/org.sh` — `repoman_get_repos`, `repoman_match_name`, `is_enrolled`,
  `repoman_config`, `enrolled_clone_dirs`.
- `scripts/repoman-setup.sh` — `set-output` (invoked on the **skill** side, not
  by `repoman run`).

**Changed:**
- `scripts/link-health-scanner.sh`, `scripts/dep-bump-scanner.sh` — **remove
  their self-registration into `_index.json`**; the orchestrator becomes the
  sole index writer (see §Index-write contract).
- `tools/repoman-dogfood.sh` — drive its Phase-5 assertions **through
  `repoman run`** instead of invoking scanners directly (local-only harness;
  never committed).

## The program table (sole encoder of per-program behavior)

A declarative table at the top of `repoman-run.sh`. bash 3.2 has no associative
arrays (codebase portability constraint), so it is encoded as a line-based table
parsed per program (or an equivalent lookup function). One row per program:

| program | profile | needs_clone_refresh | posts_output | writes_index | scanner_script |
|---|---|---|---|---|---|
| `link-health` | scanner | yes | yes | yes | `link-health-scanner.sh` |
| `dep-bump` | scanner | yes | yes | yes | `dep-bump-scanner.sh` |
| `pr-review` | scanner | no | no | no | `pr-review-scanner.sh` |
| `weekly-report` | scanner | no | no | no | `weekly-report.sh` |
| `automation-health` | index-consumer | no | no | no | `automation-health-dashboard.sh` |

Index rows additionally carry `index_display_name` (e.g. `Link Health`) and
`report_path` (e.g. `~/reports/link-health`) — the fields `repoman-index.sh`
requires.

**Rationale per non-obvious row:**
- `pr-review` posts a GitHub *review* in place, not issues to a report repo, so
  `posts_output=no` (no `output_repo` gate) and it has no report-dir/index shape
  (`writes_index=no`).
- `weekly-report` is a thin wrapper around a Python generator; it writes no
  `latest.json`/`_index.json` today, so `writes_index=no`. Giving it an index
  entry is follow-up work, not v0.1.0.
- `automation-health` *consumes* `_index.json` (it is the dashboard); the
  `index-consumer` profile skips clone-refresh, subset projection, and the
  scope gate, and simply execs the dashboard script.

**Adding a new program = adding one row.** The orchestrator reads the row's
fields to decide steps and to write the index entry; a program never
self-registers. This table is the natural future home for the unified program
registry (#76); for now it must stay consistent with the `KNOWN_PROGRAMS`
allowlist in `repoman-setup.sh:34`. Unifying the two lists is #76's job, not
this spec's — we deliberately avoid entrenching a conflicting third registry.

## Data flow

### Subset selection (env-scoped temp repos file)

Scanners resolve the enrolled set internally via `repoman_get_repos` and take
**no `--repos` flag** (the architecture spec's `--repos` sketch was never
implemented; link-health/dep-bump drive from `repoman_load_enrolled` +
`enrolled_clone_dirs`, pr-review/weekly go straight to GitHub). To restrict a
run to a named subset without touching any scanner:

```
~/.repoman/repos.json          (authoritative; written only at setup/enroll time
   [eventing-lab, context-service]  via repoman-setup.sh, never during a run)
        │  run path reads the skill-reconciled target list
        ▼
   project to subset  ->  "$(mktemp -d)/repos.json"   [in $TMPDIR, NOT under ~/.repoman/]
        │                   written directly as a throwaway {owner,name} array
        ▼                   (NOT via repoman-setup.sh; allowed because it is
   REPOMAN_REPOS_FILE="$tmp" bash <scanner>.sh         outside the ~/.repoman/ guard)
        │                   scanner's own repoman_get_repos reads the override
        ▼
   trap 'rm -rf "$tmpdir"' EXIT    (fires on success/error/signal; only kill -9 leaks,
                                     and $TMPDIR is OS-reclaimed)
```

- **No targets** → no temp file; scanner reads the real `repos.json` (whole
  enrolled set). Common scheduled case.
- **Targets** → the list is already reconciled by the skill. The run path
  validates each is enrolled (`is_enrolled`, defensive) and fails loud naming
  any that is not; it does not re-run org/ambiguity resolution.

**Writer invariant:** the temp file is a throwaway projection in `$TMPDIR`, so
writing it directly does **not** violate the HARD INVARIANT (which guards only
`~/.repoman/` state). The run path never writes under `~/.repoman/`.

**Race note (non-issue):** `repos.json` is written only at setup/enroll time,
never during a run, so there is no concurrent-writer race between the read and
the projection in the normal flow. (Two simultaneous sessions — one running, one
enrolling — are out of scope for v0.1.0; the read is a single atomic `jq` over a
file the setup writer writes atomically.)

### Output routing

`repoman run` reads `programs/<name>.json.output_repo` (shape
`{mode: "same"|"central", repo?: "owner/name"}`, written earlier by the skill
via `set-output`). For `posts_output=yes` programs, if `output_repo` is unset →
**fail loud**: "output destination not set; run `/repoman` (or
`repoman-setup.sh set-output …`)". It never prompts.

**Validate-vs-consume gap (honest, implementation-contingent).** In v0.1.0 the
scanner's report target is still the hardcoded `REPORT_TARGET_REPO`
(removal deferred to the de-rossoctl-ing issue). So the run path *validates and
requires* `output_repo` (contract-complete for callers now), while the scanner
actually *honoring* it lands with that later issue — a scanner-internal swap,
not a `repoman run` contract change. **If implementation shows this gap can
close cleanly within this work (or must change shape), update this section to
match reality rather than let the spec drift.**

## Index-write contract

**One writer: the orchestrator.** After a `writes_index=yes` program runs, the
run path writes its `_index.json` entry via `repoman-index.sh` using the row's
`index_display_name` + `report_path`. Programs never self-register.

Two accepted consequences (documented, not silent):
1. **Registry relationship (#76).** The orchestrator table is a per-program list
   alongside `KNOWN_PROGRAMS`; it must stay consistent with it. Unifying them is
   #76. We note the table as the future registry home to avoid entrenching a
   third conflicting list.
2. **Direct invocation no longer self-indexes.** Running
   `link-health-scanner.sh` directly (outside `repoman run`) will no longer
   update `_index.json`. The **blessed path for an indexed run is
   `repoman run`.** The dogfood harness (which invokes scanners directly and
   asserts index wiring) is updated to drive through the run path.

## Dry-run passthrough (added during implementation, 2026-10-18)

**Why this was added (deviation from the original spec):** the real scanners
perform **post-report push steps** — e.g. `link-health-scanner.sh` updates
`docs/*.md` and opens PRs against a report repo *after* writing `latest.json`.
Running them for real against a fresh or no-clone environment fails at that push
step, which means (a) there is no safe way to preview "what would
`repoman run <program>` do", and (b) the dogfood harness (which the spec requires
us to extend and run before the PR) cannot drive the real scanner→index chain.
The original spec was silent on dry-run; implementation showed a run
orchestrator without one is incomplete.

**Contract:** `repoman run <program> --dry-run` forwards `--dry-run` to the
program when the program's table row declares it supports it
(`supports_dry_run=yes`). The orchestrator still runs its own steps
(resolution, output gate, capability check, clone refresh, exec, index write);
`--dry-run` changes only what it hands the *program*, so the program itself
suppresses its mutating tail (issue/PR creation, docs push). Programs that do
not accept `--dry-run` (`weekly-report`) ignore the passthrough — the flag is
simply not forwarded to them, and the run proceeds normally. The program table
gains a `supports_dry_run` column for this.

This supersedes the earlier implementation-internal reading of `--dry-run` as
"preview resolution only, skip execution": the flag now means "a real run with
the program's own dry-run engaged", which is the useful preview and what the
dogfood exercises.

## Error handling & exit contract

Non-interactive, fail-loud, legible to cron/standing-order wrappers.

- **Unknown program** (not in table) → non-zero; stderr lists known programs.
- **Target not enrolled** (defensive) → fail loud, name the offending
  `owner/name`.
- **`output_repo` unset** for a `posts_output` program → fail loud (above);
  never prompts.
- **Capability gate** (`repoman-check.sh`): adopt its existing contract
  unchanged — **scope gap = hard fail (abort, non-zero)**; **label gap =
  warning, continue**. The run path surfaces its stderr and propagates its code.
- **Clone refresh** (`repo-sync.sh`): existing semantics — per-repo failures
  counted/logged. **Total sync failure (all enrolled fail) = fatal** (cannot
  scan uncloned repos); **partial = logged warning, continue.**
- **Scanner exec failure** → non-zero, reason on stderr.
- **Temp dir** → `trap 'rm -rf "$tmpdir"' EXIT` fires on success/error/signal.
- **Exit codes:** `0` = program ran and succeeded; **non-zero** = gate failed OR
  exec failed OR a fatal precondition (unknown program, unset output, total sync
  failure). Partial per-repo issues follow the program's own semantics.

## Commit & sign-off identity (considered extensively; deferred)

Captured because it shapes future RepoMan work and is why fixers are out of
scope.

- **Current mechanism:** `link-health-fixer.sh:25-29` hardcodes one identity
  (`Gloire Rubambiza <gloire@ibm.com>`) and sets author = committer; line 500
  commits with `git commit -s`, so the DCO `Signed-off-by` trailer is derived
  from that committer identity. **Author = committer = DCO signer, all one
  hardcoded identity. No split exists today.** The same shape produces the
  dashboard's auto-PRs (e.g. [#111](https://github.com/rossoctl/automation/pull/111)).
- **The real question (surfaced during run-path design):** when automation
  commits/opens PRs, three roles can diverge — **author** (who wrote the
  change), **committer** (what ran it; could be a bot/GitHub App), and **DCO
  signer** (a real person certifying under the DCO). DCO requires a real
  identity; a bot/App identity may not satisfy it. The hardcode is a stopgap
  that attributes automated work to a human so DCO passes.
- **Proposed future capability (NOT v0.1.0):** a setup-time question for
  commit-bearing programs — "use your detected login identity for both committer
  and sign-off, or split them (bot/App committer + human DCO signer)?" —
  persisted to `programs/<name>.json`, consumed by the fixers instead of the
  hardcode.
- **Dependency:** [#82](https://github.com/rossoctl/automation/issues/82)
  (GitHub App auth vs. clawgenti bot user) is the upstream decision this rests
  on. The identity model should be settled with #82 **before** the fixers'
  identity is parameterized. Hence v0.1.0 run path **does not touch identity**:
  scanners are read-only toward commits (they open issues via the PAT; the
  committer-identity hardcode only bites the fixers, which are out of scope),
  so there is a clean deferral boundary.

## Testing & CI

**New: `tests/test-repoman-run.sh`** — hermetic (overrides
`REPOMAN_CONFIG_FILE`/`REPOMAN_REPOS_FILE`/`REPOMAN_PROGRAMS_DIR`, stubs
`gh`/scanners/`repoman-check.sh`). Cases:
- unknown program → non-zero + known-programs list;
- no targets → scanner runs against full enrolled set, **no temp file created**;
- named subset → temp `repos.json` in `$TMPDIR` holds exactly the subset,
  scanner invoked with `REPOMAN_REPOS_FILE` pointing at it, temp dir **gone after
  exit**;
- target not enrolled → fail loud naming it;
- `output_repo` unset for a `posts_output` program → fail loud, no prompt;
- `writes_index=yes` → exactly one `_index.json` entry written **by the
  orchestrator**; `writes_index=no` → no entry;
- `index-consumer` (automation-health) → no clone-refresh, no scope gate, no
  subset projection; dashboard exec'd;
- scope-gate hard-fail (stub `repoman-check.sh` non-zero) → run aborts non-zero;
- total clone-sync failure → fatal; partial → warning + continue;
- exit codes asserted for clean / gate-fail / exec-fail.

**Modified tests:** `tests/test-link-health-index-wiring.sh` +
`tests/test-dep-bump-index-wiring.sh` — scanners no longer self-register, so
these retarget to assert the **orchestrator** writes the entry.

**CI (explicit lists, not globs — a new file silently never runs otherwise):**
add `tests/test-repoman-run.sh` to **both** the `Run test suite` loop **and** a
shellcheck group in `.github/workflows/tests.yml`. While editing that list, also
add the two currently shellcheck-only / un-run tests the run path depends on —
`tests/test-repoman-check.sh` and `tests/test-repoman-requirements.sh` — to the
run-suite loop (small adjacent hardening, directly relevant since the run path
leans on the capability gate).

## Deferred work (filed/to-file, referenced here for a clean boundary)

- **De-rossoctl-ing issue (to file):** remove the hardcoded org/person defaults
  — `REPORT_TARGET_REPO` (`link-health-scanner.sh:45`,
  `automation-health-dashboard.sh:82`), `SOURCE_REPO`
  (`automation-health-dashboard.sh:83`), committer identity
  (`link-health-fixer.sh:25-26`), and the personal `REPORT_PY` default
  (`weekly-report.sh:79`, already env-overridable). 4 behavioral constants
  across 3 files. Distinct from #99 (that is config *plumbing*; this is embedded
  org/person *defaults*).
- **#99** — scanner/fixer/dashboard param-driven decoupling (v0.1.1).
- **#82** — automation commit/sign-off identity (gates fixer orchestration).
- **#76** — unify program registry.
- **#98**, **#115** — v0.1.1 / optional riders.
