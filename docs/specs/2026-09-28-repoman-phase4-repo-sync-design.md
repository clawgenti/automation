# RepoMan Phase 4 — repo-sync program design

**Date:** 2026-09-28
**Status:** Approved (2026-09-28)
**Epic:** [#72](https://github.com/rossoctl/automation/issues/72) (Phase 4 = [#75](https://github.com/rossoctl/automation/issues/75))
**Companion:** [rossoctl/agent-skills#38](https://github.com/rossoctl/agent-skills/issues/38) (`skills/repo-sync/`)
**Parent spec:** `docs/specs/2026-08-27-repoman-architecture.md` (§Repo sync program, §Deployment)

## Summary

Promote repo-sync from a standing order (`standing-orders/repo-sync.md`) to a
first-class program with a real script, `scripts/repo-sync.sh`, driven by the
Phase 1 enrolled-repo model. It keeps the local clone cache current so the
scanner and fixer programs operate on up-to-date working copies: clone any
enrolled repo that is missing, `git pull` any that is present, owner-namespaced
under `<repos_dir>/<owner>/<name>/`. It is read-only toward GitHub. A per-repo
failure is logged and does not abort the run. An optional `--refresh-skills`
mode pulls a local agent-skills clone so a deployment's skill files stay
current.

## Scope and non-scope

**In scope:**
- `scripts/repo-sync.sh` — the program.
- Rewrite `standing-orders/repo-sync.md` to the enrolled-repo model.
- `tests/test-repo-sync.sh` — hermetic tests (no network; git and gh stubbed).
- The companion skill `skills/repo-sync/` lands in agent-skills (#38), tracked
  there; this spec covers the automation-repo half and defines the interface
  the skill wraps.

**Explicitly NOT in scope (owned elsewhere, do not implement here):**
- **No `$ORG` / `gh repo list <org>` fallback.** #75's backward-compat clause
  ("fall back to `gh repo list $ORG` if `repos.json` is absent") predates
  Phase 1, which retired `$ORG` and `load_org_profile` entirely. An absent
  `repos.json` fails loud (see Error model). The stale clause is flagged on
  #75 rather than implemented.
- **No `_meta.json` write.** The parent architecture spec (§Deployment, "`_meta.json`
  written by repo-sync on pull") is superseded by Phase 6 ([#77](https://github.com/rossoctl/automation/issues/77)),
  which chose Option 2: each skill's entry point writes `_meta.json` at startup.
  repo-sync only keeps the skill *clone* current; it never writes provenance.
- **No branch-safety hardening.** Restoring a clone to its main branch before a
  pull when the tree is clean is [#80](https://github.com/rossoctl/automation/issues/80)
  (v0.1.1). Phase 4 pulls the current branch as-is and logs a pull that fails
  because of local state.
- **No scheduling.** Cron/schedule registration is the setup flow's job, not
  the program's.

## Global constraints

- `bash` 3.2 compatible (macOS default): no `mapfile`, no associative arrays
  unless guarded. Follow the `while IFS= read -r` idiom the parent spec uses
  for `repoman_get_repos`.
- Source `scripts/program-lib.sh`, which transitively provides `core.sh`,
  `github-api.sh`, `fork.sh`, `org.sh` — so `repoman_config`,
  `repoman_get_repos`, and `gh_with_backoff` are all available. Do not
  re-source `org.sh` directly.
- `set -uo pipefail`, **not** `-e`: the per-repo loop must survive a single
  repo's clone/pull failure and continue. Match `repoman-check.sh`.
- **Surface every failure to the caller.** Every command's return code and
  every command-substitution output matters, unless a swallow is explicitly
  stated. Under `set -uo pipefail` an unguarded `$(cmd)` captures empty on
  failure and the caller proceeds as if it got a valid answer — the exact
  silent-failure class flagged in the Phase 3 review. So: check each git and
  `gh` invocation's exit code directly (`if ! git ...; then ...; fi`); never
  capture a fallible call's output in a way that discards its rc; never let a
  pipeline hide a meaningful earlier-stage failure. The ONLY sanctioned swallow
  is the per-repo clone/pull failure below — and even that is not silent: it is
  detected (rc checked) and surfaced (logged + tallied). No other failure is
  swallowed.
- Read-only toward GitHub: `git clone` / `git pull` only. Never push, open a
  PR, create an issue, or write a label.
- DCO `-s` sign-off; `Assisted-By`, never `Co-Authored-By`; PR title starts
  with a capitalized prefix.

## Inputs

| Source | Provides | Failure |
|---|---|---|
| `repoman_config` (from `config.json`) | `REPOS_DIR`, `FORK_OWNER` | fail loud if `config.json` missing or a required key empty (inherited) |
| `repoman_get_repos` (from `repos.json`) | enrolled set, one `owner/name` per line, file order | fail loud if `repos.json` missing, empty, or has a malformed entry (inherited) |
| `--refresh-skills` flag OR `REPOMAN_SKILLS_DIR` env | opt-in agent-skills clone refresh + its path | see Skills refresh |

The clone loop drives from the **full enrolled set** (`repoman_get_repos`), not
`enrolled_clone_dirs` — the latter emits only already-cloned repos, and
repo-sync's entire purpose is cloning the ones that are missing.

## Behavior

### Enrolled-repo sync loop

For each `owner/name` from `repoman_get_repos`, with target
`dir="$REPOS_DIR/$owner/$name"`:

- If `"$dir/.git"` exists → run `git -C "$dir" pull --ff-only` and inspect its
  exit code directly (`if ! git -C "$dir" pull --ff-only 2>err; then ...`). On
  non-zero: capture git's stderr, log the repo with that error, count `failed`,
  continue. `--ff-only` keeps the read-only, no-merge-commit contract;
  reconciling non-fast-forward state is #80.
- Else → run `git clone "https://github.com/$owner/$name.git" "$dir"` (parent
  dirs created first) and inspect its exit code directly. On non-zero (missing
  repo, no access, network): capture stderr, log the repo with that error,
  count `failed`, continue.

Every repo ends in exactly one of three tallies: `pulled`, `cloned`, `failed`.
The clone/pull rc is never captured into a variable that drops it, and never
buried in a pipeline — it is the loop's branch condition. This per-repo
`failed` path is the one explicitly-sanctioned non-fatal outcome (see Global
constraints); it is detected and surfaced, not silent.

### Skills refresh (opt-in)

Runs only when `--refresh-skills` is passed or `REPOMAN_SKILLS_DIR` is set
(flag wins if both). Let `skills_dir` be `REPOMAN_SKILLS_DIR` or its documented
default (`~/agent-skills`). The refresh keeps a deployment's skill clone current
so pinned-SHA attribution (Phase 6) resolves against fresh skill files; it is
opt-in because the primary platforms (DAM install, local Claude Code) manage
skills their own way, and only some deployments (OpenClaw) want the syncer to
own it.

- If `"$skills_dir/.git"` exists → `git -C "$skills_dir" pull --ff-only`, exit
  code inspected directly. Unlike the per-repo loop, a skills-refresh failure
  is **fatal** (non-zero exit): the caller explicitly asked for it, so a
  swallowed failure here would silently skip the refresh the user requested.
- Else → **error, do not bootstrap-clone.** The refresh assumes the clone
  exists (the parent spec treats `~/agent-skills/` as already-present on
  OpenClaw). A missing skills dir when the mode was explicitly requested is a
  loud failure, not a silent clone, so a mistyped path is caught.

Not part of the per-repo tally; reported on its own line.

### Output

A human-readable summary to stdout: counts of pulled / cloned / failed, each
failed repo named with its one-line git error, and the skills-refresh outcome
if that mode ran. Nothing is written to GitHub and nothing is posted. Exit
status: non-zero iff the config/enrollment reads failed (fail-loud inputs) OR
the skills refresh was requested and failed. **Per-repo clone/pull failures do
NOT change exit status** — a partial sync is the expected degraded mode (the
standing order's "logged, not fatal" contract), and a non-zero exit there would
break the nightly cron on one unreachable repo.

## Error model

| Condition | Behavior |
|---|---|
| `config.json` missing / key empty | fail loud, exit non-zero (via `repoman_config`) |
| `repos.json` missing / empty / malformed | fail loud, exit non-zero (via `repoman_get_repos`). **This is the "absent repos.json" case — no `$ORG` fallback.** |
| one repo clone/pull fails | log with git's error, continue, count as `failed`, exit stays 0 |
| `--refresh-skills` but skills dir absent | fail loud on that step, exit non-zero |
| `--help` | usage to stdout, exit 0 |

## Standing order rewrite

`standing-orders/repo-sync.md` currently describes the `$ORG` +
`gh repo list <org>` + `REMAP` / `canonical_repo_for_dir` model. Rewrite it to:
enrolled set from `repos.json`, owner-namespaced clone target, read-only,
per-repo non-fatal, optional skills refresh. Remove the `REMAP` / rename
paragraph (owner-namespacing removed that class of drift per Phase 1).

## Testing

Hermetic `tests/test-repo-sync.sh`, following the repo's stub pattern
(`test-repoman-check.sh` style). No network. `git` and any `gh` call are
stubbed on `PATH`; `REPOMAN_CONFIG_FILE` / `REPOMAN_REPOS_FILE` /
`REPOMAN_PROGRAMS_DIR` point at fixtures; `REPOS_DIR` and the skills dir point
at temp dirs.

Cases:
1. All enrolled repos missing → each is cloned; tally = cloned N, exit 0.
2. All present → each is pulled; tally = pulled N, exit 0.
3. Mixed present/absent → correct split.
4. One repo's clone fails (stub returns non-zero for it) → that repo counted
   `failed`, others still processed, **exit still 0**, error text names the repo.
5. `repos.json` absent → fail loud, exit non-zero, message names the file
   (asserts NO `$ORG` / `gh repo list` fallback fired).
6. `--refresh-skills` with skills dir present → skills pull invoked once.
7. `--refresh-skills` with skills dir absent → fail loud on that step, exit
   non-zero, message names the missing dir.
8. `--help` → usage, exit 0.

Each negative test captures and greps stderr (assert the message, not just a
non-zero exit) so "fails cleanly" cannot mean "fails silently".

## Dog-fooding

`tools/repoman-dogfood.sh` extends naturally: after `add-repo` enrolls a stub,
a `repo-sync --help` step and (against a scratch `REPOS_DIR`) a real
clone-a-tiny-public-repo step exercise the loop end-to-end without touching any
core repo. Optional; the hermetic tests are the gate.

## Commit shape

Small commits, TDD order: (1) failing test for the enrolled sync loop; (2)
minimal loop; (3) failing test for skills refresh; (4) skills refresh; (5)
standing-order rewrite; (6) dog-food harness extension (optional). Landed on
`feat/repoman-phase4-repo-sync` in this worktree; the companion skill (#38) is
its own agent-skills PR.
