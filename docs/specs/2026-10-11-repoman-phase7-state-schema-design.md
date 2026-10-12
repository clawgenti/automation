# RepoMan Phase 7 — Standard state.json Envelope

**Date:** 2026-10-11
**Status:** Design (awaiting review)
**Implements:** [#79](https://github.com/rossoctl/automation/issues/79) (Phase 7 of epic [#72](https://github.com/rossoctl/automation/issues/72))
**Parent spec:** `docs/specs/2026-08-27-repoman-architecture.md` (§State and persistence)

> **Living document.** Kept in sync with the code as written and revised. Any
> field, subcommand, or validation-rule change during implementation or review
> is reflected here in the same commit (or the immediately following one).

## Summary

Wrap every program's `state.json` in a common envelope so future cross-program
tooling (a unified eviction sweep — a garbage collector, "GC", over expired
dedup entries) can read any program's state without knowing its internals. Only
**pr-review** (scanner + fixer) writes a `state.json`
today, so this phase defines the envelope, migrates that one consumer, and
establishes the pattern for future writers. Backward-compatible: a legacy file
is migrated in memory on read and rewritten in the new shape on the next normal
write.

## Scope boundary

**In Phase 7:**
- The envelope schema (below) and a thin `scripts/pr-review-lib.sh` holding the
  load-and-migrate / build helpers, sourced by both pr-review scripts.
- Migrate `scripts/pr-review-scanner.sh` and `scripts/pr-review-fixer.sh` to
  read/write the envelope.
- A new offline bash unit test (`tests/test-pr-review-state.sh`) covering
  envelope round-trip and legacy migration, wired into CI.
- Updating `tests/test-pr-review-integration.sh` (already in CI) to assert the
  envelope shape instead of the legacy `{in_progress, reviewed}` shape, so it
  keeps passing.

**Not in Phase 7 (called out to prevent scope creep):**
- No state.json for link-health / dep-bump. Their dedup is GitHub-authoritative
  (issue search); the parent spec's state diagram shows state.json under them as
  the *planned* layout, not a current gap. They adopt the envelope only if/when
  they gain a local cache.
- No shared/vendored helper. The envelope logic is **automation-only** and lives
  in `pr-review-lib.sh`, not in the parity-vendored `core.sh` / `program-lib.sh`
  — no agent-skills skill writes state (`github-pr-review` is SKILL.md-only).
  A future unified sweep (#107 run path) may promote it to a shared lib then.
- The unified eviction sweep (garbage collector) itself (future; #79 only
  enables it).

## Envelope schema

```json
{
  "schema_version": 1,
  "program": "pr-review-scanner",
  "acted_on": {
    "rossoctl/x:123": { "at": "2026-10-01T12:00:00Z", "ttl_days": 30, "head_sha": "abc123" }
  },
  "program_data": {
    "in_progress": [
      { "repo": "rossoctl/x", "number": 123, "head_sha": "abc123", "started_at": "2026-10-01T12:00:00Z" }
    ]
  }
}
```

- **`schema_version`** (int) — envelope version. `1` for this phase. Its
  presence is also the migration trigger (see below).
- **`program`** (string) — the writing program's identifier (e.g.
  `pr-review-scanner`, `pr-review-fixer`).
- **`acted_on`** (object) — the standardized dedup cache: a map from a
  program-chosen dedup key to `{ at, ttl_days, ... }`. `at` is the ISO-8601
  action time; `ttl_days` drives envelope-level eviction. Extra per-entry fields
  (here `head_sha`) are allowed and ignored by the envelope. This is what a
  future garbage-collection sweep walks across programs.
- **`program_data`** (object) — program-specific, unvalidated at the envelope
  level.

### How pr-review maps onto the envelope

pr-review has two lists with two different eviction rules:

- **`reviewed[]`** is a dedup cache (TTL 30d). It maps to **`acted_on`**: key
  `"<repo>:<number>"`, `at` = `reviewed_at`, `ttl_days` = 30, plus `head_sha`.
  This is the dedup set the envelope exists to standardize.
- **`in_progress[]`** is a 30-minute coordination *lease*, not a dedup record,
  and is evicted by a stale-minutes rule, not a TTL. It stays in
  **`program_data.in_progress`** unchanged.

This split is the general rule for future programs: durable dedup → `acted_on`;
anything else (leases, counters, cursors) → `program_data`.

## Migration

Lazy, trigger = **absent `schema_version`**:

```
load state.json  (pr_review_state_load)
  |> .schema_version present?
       yes -> envelope v1: unwrap to the WORKING shape in memory
              (acted_on -> reviewed[], program_data.in_progress -> in_progress)
       no  -> legacy v0 { in_progress, reviewed } arrays: pass through as-is
              (already the working shape)
  ... normal scan/fix: the ~15 inline jq blocks operate on the WORKING shape ...
write state.json (pr_review_state_write)
  |> wrap WORKING shape back into envelope v1, atomic write
     # legacy shape never written again
```

The on-disk form is always envelope v1; the in-memory form the scanner/fixer jq
blocks manipulate is the **working shape** `{reviewed, in_progress}`. All
envelope knowledge lives at the two conversion boundaries (load/write) so the
inline jq blocks stay untouched. A missing file yields the empty working shape
in memory, which `pr_review_state_write` then persists as an empty envelope v1
on the first write. No explicit version-dispatch function yet — a single inline
`0 -> working` unwrap is enough; a `migrate(from_version)` dispatcher is
deferred to whenever a `schema_version: 2` first exists (YAGNI).

## Helpers (`scripts/pr-review-lib.sh`)

A new automation-only lib, sourced by both pr-review scripts after
`program-lib.sh` (so `jq` and `atomic_write_file` from `core.sh` are already
available). It is NOT vendored to agent-skills and NOT part of
`core.sh`/`program-lib.sh`. Two functions plus a working-shape default
constant (`PR_REVIEW_WORKING_DEFAULT='{"in_progress": [], "reviewed": []}'`):

- `pr_review_state_load <state_file>` — emits the WORKING shape
  `{reviewed, in_progress}` on stdout. Handles envelope v1 (unwraps
  `acted_on` → `reviewed[]` and `program_data.in_progress` → `in_progress`),
  legacy v0 arrays (passes through), a missing file (empty working shape), and
  invalid JSON (empty working shape, non-destructive — the bad file is logged to
  stderr but not rewritten, unlike `validate_json_schema` which resets on
  invalid). Replaces the inline `STATE_DEFAULT`/`validate_json_schema` block
  duplicated in both scripts.
- `pr_review_state_write <working_json_file> <dest_file> <program_id>` — wraps
  the working shape into envelope v1 (building `acted_on` from `reviewed[]` keyed
  `<repo>:<number>` with `at`/`ttl_days`/`head_sha`, and
  `program_data.in_progress` from `in_progress`), stamping the given
  `program_id`, then atomically writes via `atomic_write_file`.

No `acted_on` accessor helpers exist: the scanner's TTL/stale eviction and the
fixer's reviewed/in_progress transitions remain the existing inline jq blocks
operating on the working shape, so they were not rewritten. Envelope validation
is implicit in `pr_review_state_load`'s `jq` conversion (invalid or
unrecognized input falls through to the empty working shape); there is no
separate boolean validation expression.

## Testing

Two test files are in play; both run in CI today (the run list in
`.github/workflows/tests.yml` is explicit, not globbed).

**New: `tests/test-pr-review-state.sh`** — offline, no `gh`, added to both the
`Run test suite` loop and the `shellcheck (repoman tests)` group. This is Phase
7's coverage of record. Cases:

1. Missing file → `pr_review_state_load` yields the empty working shape
   (empty `reviewed`, empty `in_progress`). The envelope only materializes on
   write.
2. Legacy `{in_progress,reviewed}` file → `pr_review_state_load` passes the two
   arrays through unchanged (they are already the working shape).
3. `pr_review_state_write` on a working shape → produces envelope v1:
   `schema_version==1`, the `program_id` recorded, each `reviewed` entry keyed
   `<repo>:<number>` under `acted_on` carrying `at`/`ttl_days`/`head_sha`, and
   `in_progress` under `program_data.in_progress`.
4. Round-trip (`write` then `load`) → `reviewed`/`in_progress` fields survive;
   `reviewed_at` is reconstructed from the envelope's `at`.
5. Corrupt/invalid JSON → `pr_review_state_load` falls back to the empty working
   shape without rewriting the bad file (non-destructive, unlike
   `validate_json_schema`'s reset-on-invalid).

**Required update: `tests/test-pr-review-integration.sh`** — this test *is*
wired into CI (re-included hermetically via a `REPOMAN_REPOS_FILE` stub; the
gh-dependent fixer phases take the no-PR SKIP path, but the scanner's full
state-write path runs). It currently asserts the legacy shape — `state.json has
in_progress array` and `state.json has reviewed array` (and reads top-level
`.in_progress | length` for the dry-run/live checks). After Phase 7 the on-disk
`state.json` is the envelope, so these assertions **must** be updated to the new
shape (`.program_data.in_progress` for the lease array; `.acted_on` for the
dedup map; `.schema_version == 1`) or CI breaks. This is a hard requirement, not
an optional refresh.

## Backward/forward compatibility

- A deployed pr-review with an on-disk legacy `state.json` migrates silently on
  its next run; no operator action.
- A reader that predates the envelope would break on the new shape, but the only
  readers are the two pr-review scripts, migrated together.
- `schema_version` lets a future `2` add fields without breaking v1 readers that
  check `>= 1`.
