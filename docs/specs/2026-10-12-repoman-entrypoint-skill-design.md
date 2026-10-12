# RepoMan Entrypoint Skill — `/repoman`

**Date:** 2026-10-12
**Status:** Design (awaiting review)
**Implements:** [#107](https://github.com/rossoctl/automation/issues/107) (RepoMan epic [#72](https://github.com/rossoctl/automation/issues/72)); delivers the setup-conversation half of [#73](https://github.com/rossoctl/automation/issues/73)
**Parent spec:** `docs/specs/2026-08-27-repoman-architecture.md` (§Setup flow, §Program invocation flow)

> **Living document.** Kept in sync with the skill and helper as written and
> revised. Any question, reconciliation rule, or helper-signature change during
> implementation or review is reflected here in the same commit (or the
> immediately following one).

## Summary

RepoMan's eight numbered phases built composable **primitives** — a setup
writer (`repoman-setup.sh`), a capability gate (`repoman-check.sh`), an
enrolled-set resolver (`org.sh`), a requirements parser
(`repoman-requirements.sh`), and per-program scanners — but nothing wires them
into the user-facing invocation flow the architecture spec describes. A user
cannot today say "set up RepoMan" or "run pr-review on these repos" and have the
primitives orchestrated for them.

This phase delivers the **entrypoint**: a single `/repoman` intent-dispatching
skill that infers from context and `~/.repoman/` state what the user wants, runs
the five-question setup conversation when there is no setup, and reconciles
user-named repos against the enrolled set before a run. It reuses every existing
primitive and adds exactly one new executable (a bare-name → owner lookup
helper). The **run path** (actually exec'ing a scanner and writing reports) and
the **standing-orders migration** are named follow-ons, deliberately out of
scope (see Scope boundary).

## Scope boundary

**In this phase:**
- A `/repoman` skill (`SKILL.md` + bundled scripts) in agent-skills: an
  intent-dispatching entrypoint, not a user-selected mode.
- The **five-question setup conversation** (#73's unbuilt half), driving the
  existing `repoman-setup.sh` subcommands.
- The **repo-selection reconciliation rule** at the skill layer: when a user
  names repos for a run, reconcile those names against the enrolled set
  (enrolled / ambiguous-bare-name / not-enrolled) before handing off.
- Requirement wiring: call the existing `repoman_parse_requirements` on a
  program's `SKILL.md`, adapt its JSON arrays to the CSVs `set-requirements`
  expects, and call `set-requirements`. This is the documented-but-unimplemented
  contract at `scripts/repoman-setup.sh:493`, not a new parser.
- One new executable: `repoman_match_name` — bare-name → enrolled-owner(s)
  lookup — authored in automation `scripts/` (source of truth, CI-tested) and
  bundled into the skill (Phase 6 primitive-in-automation / skill-in-agent-skills
  precedent).

**Not in this phase (called out to prevent scope creep):**
- **The run path.** `repoman run <program>` (capability-check → refresh clones →
  exec scanner → write reports + `_index.json`) is a named follow-on. The skill
  reconciles and *hands off* to it; this phase defines the handoff boundary but
  does not implement the exec. Rationale: it unlocks dogfooding `/repoman`'s
  setup/activate flows inside a Claude Code session first.
- **Standing-orders migration.** The three standing orders that still cite
  `config/core-repos.txt` (`dep-bump.md:12`, `link-health.md:12`,
  `pr-review.md:12`) are "full of rossoctl-isms that would need to be rethought
  for a broader OpenClaw deployment" — the main deployment route for standing
  orders. Their reshape depends on that rethink and is a separate follow-on.
- **No new requirements parser.** `repoman_parse_requirements` already exists,
  is sourced via `program-lib.sh:20`, and is unit-tested
  (`tests/test-repoman-requirements.sh`). Adding another would duplicate it.

## Design principle: intent dispatch, not a mode menu

`/repoman` infers what the user wants from (a) their message and (b)
`~/.repoman/` state. It asks only on **genuine ambiguity**, and always with
**explicit enumerated options** (a mid/low-tier model must be able to answer
without free-form reasoning). The setup-vs-activate distinction is *inferred
from state*, never presented as a user-facing menu:

- **No `~/.repoman/config.json`** → no setup exists → first-time setup flow.
- **Setup exists** → activate a new program, reconfigure, or run one — inferred
  from the message.

## State-inference decision tree

The skill's first action is to read `~/.repoman/` state and classify. Let
`SETUP = config.json exists and parses`, and `INTENT = the message names a
program and/or repos to act on`.

```
read ~/.repoman/config.json
  |> SETUP?
      no  -> INTENT?
               no  -> first-time setup conversation (five questions)
               yes -> AMBIGUOUS COLD START: ask the user (enumerated):
                        A. set up now, then run the named intent (one flow)
                        B. just set up now; re-invoke to run later
                      (never guess — see "Cold start with intent")
      yes -> INTENT names a program not yet enabled?
               yes -> activate: enable-program + requirement wiring, then
                      (if INTENT also names a run) reconcile + hand off
               no  -> INTENT names repos to run?
                        yes -> reconcile named repos vs enrolled set, hand off
                        no  -> no actionable intent: summarize current setup
                               and list enabled programs (read-only)
```

The only question the tree forces on an unprompted basis is the **cold-start
conflict** (SETUP absent, INTENT present) — the one case where "absence of
setup" and "an explicit run request" genuinely contradict, so the user decides.
Everything else is inference over state.

### Cold start with intent (the one forced question)

When the user invokes `/repoman` with an intent but no setup, the two signals
conflict: the request says "run," the state says "nothing is configured." The
skill surfaces this with two enumerated options:

- **A — Fold the run into setup:** run the five-question conversation using the
  named repos/program as the defaults for Q2 (repos) and Q3 (program), then
  proceed to reconcile + hand off the requested run. One continuous
  conversation.
- **B — Setup only:** complete and confirm setup, then stop. The user
  re-invokes `/repoman` to run.

The skill does not pick for the user. (Decision recorded this session.)

## Setup conversation (five questions)

Each question maps to one `repoman-setup.sh` subcommand. Questions are asked one
at a time; each offers a sensible default so a user can accept the whole flow
quickly. All writes go through the setup writer — the skill never writes
`~/.repoman/` files directly.

| # | Question | Default | Subcommand |
|---|----------|---------|------------|
| Q1 | Where should repo clones live? Who is the fork owner? | `~/repoman/repos` (a subdir, so `validate_repos_dir` accepts it) + the user's gh login | `init-config --repos-dir <path> --fork-owner <owner>` |
| Q2 | Which repos to enroll? (`owner/name`, repeatable) | from the named intent if present, else prompt | `add-repo (--owner <o> --name <n>)...` |
| Q3 | Which program(s) to enable now? | from the named intent if present, else none | `enable-program --program <name>` (per program) + requirement wiring (below) |
| Q4 | Output mode for each enabled program: write back to the same repo, or to a central repo? | `same` | `set-output --program <name> --mode same\|central [--repo <owner/name>]` |
| Q5 | Run the capability check now? (fix PAT scopes / create missing labels) | yes | `repoman-check.sh --program <name> [--create-missing-labels]` |

**Q1 path rejection.** `validate_repos_dir` (`org.sh:36`) rejects empty values,
dangerous system paths, `$HOME` itself, and non-existent dirs. The default
`~/repoman/repos` is a subdir and passes. If a user-offered path is rejected,
the skill re-prompts with the specific reason the validator gave — it does not
silently fall back to the default.

**Q3 requirement wiring (the documented contract at
`repoman-setup.sh:493`).** For each program the user enables, the skill:

1. locates that program's `SKILL.md` (e.g. `skills/github-pr-review/SKILL.md`);
2. calls `repoman_parse_requirements <skill-md>` →
   `{"pat_scopes":[...],"labels_required":[...],"labels_applied":[...],"programs":[...]}`;
3. joins each JSON array into a comma-separated string (empty array → empty CSV,
   which `set-requirements` normalizes back to `[]`);
4. calls `set-requirements --program <name> --pat-scopes <csv>
   --labels-required <csv> --labels-applied <csv>`.

The skill parses `SKILL.md` **only** through `repoman_parse_requirements`;
nothing else reads that block.

## Repo-selection reconciliation (activate / run)

The architecture spec's run path sketches scanners called with
`--repos owner/name`, but Phase 4+ scanners resolve the enrolled set
**internally** via `repoman_get_repos` (`org.sh:133`) — no `--repos` flag exists
anywhere, and link-health/dep-bump additionally drive from
`repoman_load_enrolled` + `enrolled_clone_dirs` while pr-review/weekly go
straight to GitHub. The reconciliation therefore lives at the **skill layer**;
scanners stay unchanged and keep resolving internally. The skill's job is to
*narrow* the set when the user names repos, and to catch names that cannot be
run yet.

When the user names repos for a run (setup already done), for each named token:

1. **`owner/name` given, enrolled** → use it.
2. **`owner/name` given, not enrolled** → offer to enroll it now (via
   `add-repo`) and then run; if declined, drop it from the run.
3. **Bare `name` given, exactly one enrolled owner** → resolve to that
   `owner/name`.
4. **Bare `name` given, multiple enrolled owners** → ambiguous: surface the
   candidate `owner/name` list and ask which (enumerated options).
5. **Bare `name` given, no enrolled owner** → treat as not-enrolled: offer to
   enroll (ask for the owner), else drop.

When the user names **no** repos → run across the whole enrolled set (the
current scanner default; the skill hands off without a repo filter).

Net: scanners keep resolving internally; the skill adds a name → enrolled-set
selection layer *before* handoff that narrows the set when repos are named and
resolves bare names, asking only on genuine ambiguity.

### Handoff to the run path (boundary only)

After reconciliation the skill has a concrete, enrolled, unambiguous repo set
(or the whole set). The **run path** (out of scope here) consumes that set:
capability-check → refresh clones → exec scanner → write reports + `_index.json`.
This phase defines the handoff shape — a resolved `owner/name` list the run path
accepts — but does not implement the exec. Until the run path lands, `/repoman`
completes reconciliation and reports the resolved set it *would* run, so the
setup/activate/reconcile flows are fully dogfoodable on their own.

## The one new executable: `repoman_match_name`

Every other primitive already exists. The single genuine gap is bare-name
resolution: `is_enrolled` (`org.sh:165`) needs a full `owner/name` and matches
whole-line (`grep -Fx`), so it cannot answer "which enrolled owners have a repo
named `rossoctl`?" — the question reconciliation rules 3–5 need.

**Home:** authored in automation `scripts/` (next to `org.sh`, source of truth,
CI-tested there), then **bundled** into the `/repoman` skill — the Phase 6
primitive-in-automation / skill-in-agent-skills split.

**Contract:**

```
# repoman_match_name <bare-name>
# Emits every enrolled "owner/name" whose name == <bare-name>, one per line.
# Zero matches  -> no output, return 0 (caller distinguishes via empty output).
# Reads the enrolled set via repoman_get_repos (honoring REPOMAN_REPOS_FILE).
# bash 3.2-safe: no mapfile, no associative arrays.
repoman_match_name() {
  local want="$1" line
  repoman_get_repos | while IFS= read -r line; do
    [ "${line##*/}" = "$want" ] && printf '%s\n' "$line"
  done
}
```

The caller maps the output count onto the reconciliation rule: 0 → rule 5, 1 →
rule 3, ≥2 → rule 4. Resolution happens at the skill layer; the helper only
answers the lookup.

## Testing

- **New unit test `tests/test-repoman-match-name.sh`** (offline, no `gh`), wired
  into the CI run list and the appropriate shellcheck group (the list in
  `.github/workflows/tests.yml` is explicit, not globbed). Cases, each with a
  `REPOMAN_REPOS_FILE` stub:
  1. Bare name with exactly one enrolled owner → emits that one `owner/name`.
  2. Bare name with two enrolled owners (same name, different owners) → emits
     both, one per line.
  3. Bare name with no enrolled owner → no output, return 0.
  4. Name that is a substring of an enrolled name but not equal (e.g. `ross`
     vs enrolled `rossoctl`) → no output (whole-name match, no false positive).
  5. Empty / malformed `repos.json` → `repoman_get_repos` fails loud; the helper
     surfaces that failure rather than emitting a bogus match.
- **Reuse, don't duplicate:** `repoman_parse_requirements`,
  `repoman-setup.sh` subcommands, and `repoman-check.sh` keep their existing
  tests. This phase adds coverage only for the one new helper.
- **Dogfood:** the RepoMan dog-food harness gains an entrypoint section
  exercising the state-inference branches (no-setup, setup+activate,
  setup+run-reconcile) against a stubbed `~/.repoman/`, consistent with the
  dog-food-covers-all-phases invariant.

## Follow-ons (named, out of scope)

- **Run path** — `repoman run <program>`: capability-check → refresh clones →
  exec scanner → write reports + `_index.json`. Consumes this phase's resolved
  repo set.
- **Standing-orders migration** — reshape the three `core-repos.txt`-citing
  standing orders for a broader OpenClaw deployment; depends on the OpenClaw
  rethink.
- **#73 disposition** — this phase delivers #73's setup-conversation half;
  recommend closing or re-pointing #73 when `/repoman` lands.
