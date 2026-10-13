# RepoMan Entrypoint Skill — `/repoman`

**Date:** 2026-10-12
**Status:** Design (awaiting review)
**Implements:** [#107](https://github.com/rossoctl/automation/issues/107) (RepoMan epic [#72](https://github.com/rossoctl/automation/issues/72)); delivers the setup-conversation half of [#73](https://github.com/rossoctl/automation/issues/73)
**Parent spec:** `docs/specs/2026-08-27-repoman-architecture.md` (§Setup flow, §Program invocation flow)

> **Living document.** Kept in sync with the skill and helper as written and
> revised. Any question, reconciliation rule, or helper-signature change during
> implementation or review is reflected here in the same commit (or the
> immediately following one).

> **Pinned source references.** Every `file:line` this spec cites is a
> **permalink to commit `c2af03e`** (`main` HEAD when this design was written),
> not a bare `path:line`. The scripts and this spec both evolve; a pinned link
> records that the design decision was made against *that* state of the world. A
> reader following a link sees the exact code the decision rests on, even after
> the line has moved or the function has changed. When this spec is revised, new
> citations pin to the then-current commit.

## Summary

RepoMan's eight numbered phases built composable **primitives** — a setup
writer (`repoman-setup.sh`), a capability gate (`repoman-check.sh`), an
enrolled-set resolver (`org.sh`), a requirements parser
(`repoman-requirements.sh`), and per-program scanners — but nothing wires them
into the user-facing invocation flow the architecture spec describes. A user
cannot today say "set up RepoMan" or "run pr-review on these repos" and have the
primitives orchestrated for them.

This phase delivers the **entrypoint**: a single `/repoman` intent-dispatching
skill that infers from context and `~/.repoman/` state what the user wants. It
orients a new or returning user who has no concrete ask (what RepoMan does, which
programs ship, that it is open source), runs the five-question setup conversation
when there is no setup, and reconciles user-named repos (or an org) against the
enrolled set before a run. It reuses every existing primitive and adds exactly
one new executable (a bare-name → owner lookup helper). A hard invariant runs
through the whole design: **the skill driver never writes `~/.repoman/`
directly — every mutation goes through a `repoman-setup.sh` subcommand.** The
**run path** (actually exec'ing a scanner and writing reports) and the
**standing-orders migration** are named follow-ons, deliberately out of scope
(see Scope boundary).

## Scope boundary

**In this phase:**
- A `/repoman` skill (`SKILL.md` + bundled scripts) in agent-skills: an
  intent-dispatching entrypoint, not a user-selected mode.
- A **welcome orientation** for users with no concrete ask (new or returning):
  what RepoMan does, which programs ship/are enabled, what else can be
  activated, and the open-source invitation — new-user acquisition as a
  first-class flow.
- The **five-question setup conversation** (#73's unbuilt half), following the
  architecture spec's canonical Q1–Q5 (including Q2's individual-vs-org
  enrollment), driving the existing `repoman-setup.sh` subcommands.
- The **repo-selection reconciliation rule** at the skill layer: when a user
  names repos (or an org) for a run, reconcile those names against the enrolled
  set (enrolled / ambiguous-bare-name / not-enrolled / org-scoped) before
  handing off.
- Requirement wiring: call the existing `repoman_parse_requirements` on a
  program's `SKILL.md`, adapt its JSON arrays to the CSVs `set-requirements`
  expects, and call `set-requirements`. This is the documented-but-unimplemented
  contract at [`scripts/repoman-setup.sh:493`](https://github.com/rossoctl/automation/blob/c2af03e50949bdeb231c3581f07e4350ed65f8e0/scripts/repoman-setup.sh#L493),
  not a new parser.
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
  `config/core-repos.txt`
  ([`dep-bump.md:12`](https://github.com/rossoctl/automation/blob/c2af03e50949bdeb231c3581f07e4350ed65f8e0/standing-orders/dep-bump.md#L12),
  [`link-health.md:12`](https://github.com/rossoctl/automation/blob/c2af03e50949bdeb231c3581f07e4350ed65f8e0/standing-orders/link-health.md#L12),
  [`pr-review.md:12`](https://github.com/rossoctl/automation/blob/c2af03e50949bdeb231c3581f07e4350ed65f8e0/standing-orders/pr-review.md#L12))
  are "full of rossoctl-isms that would need to be rethought
  for a broader OpenClaw deployment" — the main deployment route for standing
  orders. Their reshape depends on that rethink and is a separate follow-on.
- **No new requirements parser.** `repoman_parse_requirements` already exists,
  is sourced via [`program-lib.sh:20`](https://github.com/rossoctl/automation/blob/c2af03e50949bdeb231c3581f07e4350ed65f8e0/scripts/program-lib.sh#L20),
  and is unit-tested (`tests/test-repoman-requirements.sh`). Adding another would
  duplicate it.

## Design principle: intent dispatch, not a mode menu

`/repoman` infers what the user wants from (a) their message and (b)
`~/.repoman/` state. It asks only on **genuine ambiguity**, and always with
**explicit enumerated options** (a mid/low-tier model must be able to answer
without free-form reasoning). The setup-vs-activate distinction is *inferred
from state*, never presented as a user-facing menu:

- **No `~/.repoman/config.json`** → no setup exists → first-time setup flow.
- **Setup exists** → activate a new program, reconfigure, or run one — inferred
  from the message.

## Invariant: the skill driver NEVER writes `~/.repoman/` directly

> **This is the single most important rule in this design.** The skill driver
> (the model executing `/repoman`) MUST NOT create, edit, append to, or delete
> any file under `~/.repoman/` with its own file tools — not `config.json`, not
> `repos.json`, not `programs/<name>.json`, not with Write, Edit, `echo >`,
> `jq > file`, `tee`, or any other direct means. **Every mutation of
> `~/.repoman/` goes through a `repoman-setup.sh` subcommand** (`init-config`,
> `add-repo`, `enable-program`, `set-requirements`, `set-output`), which is the
> sole writer and owns validation, schema shape, atomicity, and dedup.

Why this is non-negotiable:

- The setup writers enforce invariants the model would otherwise have to
  re-derive and would get subtly wrong — `validate_repos_dir` rejection,
  owner/name dedup, the known-program allowlist, CSV→array normalization,
  JSON-merge of surviving keys. A hand-written file bypasses all of it.
- A single source of truth for writes means the on-disk schema can evolve in one
  place. Direct writes scattered through a skill driver would pin the schema to
  whatever shape the model happened to emit.
- It keeps the skill auditable: every state change is a named subcommand
  invocation, not an opaque file edit.

The skill driver reads `~/.repoman/` freely (via `org.sh` helpers and plain
reads) to infer state; it writes it only by calling the setup writer.

## State-inference decision tree

The skill's first action is to read `~/.repoman/` state and classify. Let
`SETUP = config.json exists and parses`, and `INTENT = the message names a
program and/or a target to act on` — where a *target* is one or more
`owner/name` slugs, bare repo names, or an org. Distinguishing an org token from
a bare repo name is itself a reconciliation step (see "Org-vs-repo detection"),
not a free-form judgment the driver makes on its own.

```
read ~/.repoman/config.json
  |> SETUP?
      no  -> INTENT?
               no  -> show the WELCOME ORIENTATION (what RepoMan does, which
                      programs ship, that it is open source), THEN begin the
                      first-time setup conversation (five questions)
               yes -> AMBIGUOUS COLD START: ask the user (enumerated):
                        A. set up now, then run the named intent (one flow)
                        B. just set up now; re-invoke to run later
                      (never guess — see "Cold start with intent")
      yes -> INTENT present?
               no  -> no actionable intent: show the ORIENTATION tailored to an
                      existing user — summarize the current setup, list ENABLED
                      programs, list what else is AVAILABLE to activate, and the
                      open-source invitation (read-only; no writes)
               yes -> INTENT names a program not yet enabled?
                        yes -> activate: enable-program + requirement wiring,
                               then (if INTENT also names a run) reconcile + hand off
                        no  -> classify each named target (org-vs-repo detection),
                               reconcile targets vs enrolled set, hand off
```

The only question the tree forces on an unprompted basis is the **cold-start
conflict** (SETUP absent, INTENT present) — the one case where "absence of
setup" and "an explicit run request" genuinely contradict, so the user decides.
Everything else is inference over state. Both no-intent branches (new user and
returning user) lead with the **orientation** below, because the first thing a
user without a concrete ask needs is to understand what the system is and what
it can do for them.

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

## Welcome orientation (new-user acquisition)

Whenever the skill reaches a no-intent branch — a brand-new user with no setup,
or a returning user who invoked `/repoman` with no concrete ask — it leads with
a short, plain-language orientation *before* any question or summary. A user who
does not yet know what RepoMan is cannot sensibly answer "which programs do you
want to run?"; onboarding is a first-class flow, not a side effect of setup.

The orientation is a brief, enumerated briefing (not a wall of prose), inferred
from live state so it never lies about what is installed:

1. **What RepoMan does, in one or two sentences** — it runs automated
   maintenance *programs* (PR review, link-health, dependency bumps, weekly
   reports, …) across a set of GitHub repos you enroll once, handling the
   capability checks and output wiring for you.
2. **Which programs ship and are ready to deploy** — the authoritative program
   names are the `KNOWN_PROGRAMS` allowlist in `repoman-setup.sh`
   ([line 34 at `c2af03e`](https://github.com/rossoctl/automation/blob/c2af03e50949bdeb231c3581f07e4350ed65f8e0/scripts/repoman-setup.sh#L34):
   `link-health`, `dep-bump`, `pr-review`, `automation-health`, `repo-sync`),
   each shown with its one-line description read from the program's `SKILL.md`
   (the same source the gate uses). The skill maps between a program's canonical
   allowlist name and its agent-skills `SKILL.md` location. For a returning user,
   split this into **enabled** (already active in `~/.repoman/programs/`) vs
   **available to activate**.
3. **What else can be activated** — the available-but-not-enabled set, so the
   path to "turn on one more program" is visible without the user guessing a
   name.
4. **Open invitation** — RepoMan is open source and welcomes new programs;
   point to the repo and the program-authoring path (`docs/program-template.md`).

For a **new user**, the orientation flows directly into the five-question setup
(the user has now seen what they are enrolling into). For a **returning user**
with no intent, it ends read-only: a summary of their current setup plus the
enabled/available split, with no writes and no forced question — they can then
say what they want in a follow-up turn.

The orientation makes no `~/.repoman/` writes; it is pure presentation over
inferred state.

## Setup conversation (five questions)

Each question maps to one `repoman-setup.sh` subcommand. Questions are asked one
at a time; each offers a sensible default so a user can accept the whole flow
quickly. All writes go through the setup writer — the skill never writes
`~/.repoman/` files directly.

The questions follow the canonical five in the architecture spec (§Setup flow),
not an ad-hoc list. Each maps to one `repoman-setup.sh` subcommand (or, for Q2
Option B and Q4, to a step that resolves inputs *then* calls the writer).

| # | Question | Default | Subcommand / step |
|---|----------|---------|-------------------|
| Q1 | Where should repo clones live? Who is the fork owner? | `~/repoman/repos` (a subdir, so `validate_repos_dir` accepts it) + the user's gh login | `init-config --repos-dir <path> --fork-owner <owner>` |
| Q2 | Which repos to enroll? **Option A** — individual `owner/name` slugs or URLs (repeatable). **Option B** — enroll an entire org. | from the named intent if present, else prompt | A: `add-repo (--owner <o> --name <n>)...`. B: see "Org enrollment" below (resolve the org's repo list, then `add-repo`). |
| Q3 | Which program(s) to enable now? | from the named intent if present, else none | `enable-program --program <name>` (per program) + requirement wiring (below) |
| Q4 | Set up nightly repo sync? (keeps clones fresh for scanners) | yes | enable the `repo-sync` program via `enable-program --program repo-sync` (deferred: user can add later) |
| Q5 | *(not asked at setup)* Output destination is asked the first time each program is invoked, not here. | — | — |

**Output mode is NOT a setup question.** The architecture spec defers it to the
first invocation of each program (§Program invocation flow): "Same repo as the
finding" (default) vs "one central repo." That first-invocation prompt drives
`set-output --program <name> --mode same|central [--repo <owner/name>]`. It is
listed here only to make the five-question boundary explicit — the setup
conversation does not ask it, so a user is not forced to decide output routing
before they have ever run anything.

**Capability check** (`repoman-check.sh --program <name>
[--create-missing-labels]`) likewise runs at invocation time, not as a setup
question — every run does a fast capability check (§Program invocation flow). The
skill may offer to run it once at the end of setup as a convenience, but it is
not one of the five.

**Q1 path rejection.** `validate_repos_dir`
([`org.sh:36`](https://github.com/rossoctl/automation/blob/c2af03e50949bdeb231c3581f07e4350ed65f8e0/scripts/org.sh#L36))
rejects empty values,
dangerous system paths, `$HOME` itself, and non-existent dirs. The default
`~/repoman/repos` is a subdir and passes. If a user-offered path is rejected,
the skill re-prompts with the specific reason the validator gave — it does not
silently fall back to the default.

**Q3 requirement wiring (the documented contract at
[`repoman-setup.sh:493`](https://github.com/rossoctl/automation/blob/c2af03e50949bdeb231c3581f07e4350ed65f8e0/scripts/repoman-setup.sh#L493)).**
For each program the user enables, the skill:

1. locates that program's `SKILL.md` (e.g. `skills/github-pr-review/SKILL.md`);
2. calls `repoman_parse_requirements <skill-md>` →
   `{"pat_scopes":[...],"labels_required":[...],"labels_applied":[...],"programs":[...]}`;
3. joins each JSON array into a comma-separated string (empty array → empty CSV,
   which `set-requirements` normalizes back to `[]`);
4. calls `set-requirements --program <name> --pat-scopes <csv>
   --labels-required <csv> --labels-applied <csv>`.

The skill parses `SKILL.md` **only** through `repoman_parse_requirements`;
nothing else reads that block.

**Q2 Option B — org enrollment.** The architecture spec (§Setup flow, Q2) offers
"enroll an entire org" as an alternative to listing individual repos, and the
same capability applies when a user's *intent* names an org rather than a repo
(e.g. "set up RepoMan for the `rossoctl` org"). The skill first confirms the
token is an org via "Org-vs-repo detection" (below) — it does not assume a bare
token is an org. The current `add-repo` writer takes only explicit
`{owner, name}` pairs — it does **not** expand an org — so once detection
confirms an org, expansion is a step the skill performs *before* calling the
writer:

1. list the org's repos: `gh repo list <org> --json nameWithOwner,isArchived`;
2. filter out archived repos (and optionally forks/templates — ask or default to
   excluding archived only, matching the architecture spec);
3. present the resulting set for confirmation (count + the list, or a chance to
   deselect), since enrolling a large org is a big action;
4. enroll the confirmed set in one call by piping the JSON array of
   `{owner, name}` to `add-repo` on stdin (its documented array-on-stdin form),
   so the writer still owns dedup and validation.

The org-expansion `gh` call and filtering live in the skill layer (or a thin
bundled helper), never in `add-repo` — consistent with the invariant that the
writer stays a pure writer with no `gh`. Enrolling an org is still a set of
`add-repo` entries on disk; there is no separate "org" record, so later runs and
reconciliation treat org-enrolled repos exactly like individually-enrolled ones.

## Repo-selection reconciliation (activate / run)

The architecture spec's run path sketches scanners called with
`--repos owner/name`, but Phase 4+ scanners resolve the enrolled set
**internally** via `repoman_get_repos`
([`org.sh:133`](https://github.com/rossoctl/automation/blob/c2af03e50949bdeb231c3581f07e4350ed65f8e0/scripts/org.sh#L133)) — no `--repos` flag exists
anywhere, and link-health/dep-bump additionally drive from
`repoman_load_enrolled` + `enrolled_clone_dirs` while pr-review/weekly go
straight to GitHub. The reconciliation therefore lives at the **skill layer**;
scanners stay unchanged and keep resolving internally. The skill's job is to
*narrow* the set when the user names repos, and to catch names that cannot be
run yet.

### Org-vs-repo detection (the single org-detection rule)

A bare token like `rossoctl` is lexically indistinguishable from a bare repo
name and a GitHub org slug — and the driver is a mid/low-tier model that must
not guess. This is the one place the design defines how a target is classified
as an org; both setup Q2 Option B and reconciliation rule 6 route through it.

Given a bare token `T` (no `/`), the skill classifies it in order:

1. **Enrolled bare name?** If `repoman_match_name T` emits any `owner/name`, `T`
   is treated as a **repo name** (reconciliation rules 3–5 take over). An
   already-enrolled repo name wins — the user is almost certainly referring to a
   repo they enrolled, not an org of the same slug.
2. **Live org?** Otherwise probe once: `gh repo list T --limit 1`. Success (exit
   0, non-empty) means `T` is a reachable org/user with repos → **org candidate**.
3. **Ambiguous or neither?** If the probe is inconclusive (e.g. `T` is both a
   plausible repo name the user has *not* enrolled and a reachable org), the
   skill **asks** with enumerated options — "Did you mean the `T` org (enroll its
   repos), or a repo named `T` (which owner)?" — never guessing. If the probe
   fails outright (no such org, no enrolled match), fall through to rule 5
   (not-enrolled bare name).

Once `T` is confirmed an org (step 2, or the org branch of step 3), org
expansion is mechanical: `gh repo list T --json nameWithOwner,isArchived` →
filter archived → the `{owner, name}` pairs the primitives already consume.
Detection is the only hard part; after confirmation the existing `add-repo`
array-on-stdin path and `repoman_get_repos` reconciliation handle the rest.

When the user names repos for a run (setup already done), for each named token:

1. **`owner/name` given, enrolled** → use it.
2. **`owner/name` given, not enrolled** → offer to enroll it now (via
   `add-repo`) and then run; if declined, drop it from the run.
3. **Bare `name` given, exactly one enrolled owner** → resolve to that
   `owner/name` (via `repoman_match_name`, below).
4. **Bare `name` given, multiple enrolled owners** → ambiguous: surface the
   candidate `owner/name` list and ask which (enumerated options).
5. **Bare `name` given, no enrolled owner** → treat as not-enrolled: offer to
   enroll (ask for the owner), else drop.
6. **An org named (no repo), e.g. "run pr-review on the `rossoctl` org"** —
   classified as an org by "Org-vs-repo detection" above (not guessed) →
   resolve to the set of that org's enrolled repos. If *some* of the org's live
   repos are not yet enrolled, offer to enroll the missing ones first (the Q2
   Option B expansion flow), then run across the resolved org set. This mirrors
   setup's org enrollment at run time, so a user whose intent is org-scoped is
   not forced to name every repo.

When the user names **no** repos and **no** org → run across the whole enrolled
set (the current scanner default; the skill hands off without a repo filter).

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
resolution: `is_enrolled`
([`org.sh:165`](https://github.com/rossoctl/automation/blob/c2af03e50949bdeb231c3581f07e4350ed65f8e0/scripts/org.sh#L165))
needs a full `owner/name` and matches whole-line (`grep -Fx`), so it cannot
answer "which enrolled owners have a repo named `rossoctl`?" — the question
reconciliation rules 3–6 need.

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

## Issue housekeeping (at implementation time)

- **Close #73 when `/repoman` lands.** This phase delivers #73's
  setup-conversation half; #73 is **closed** (not re-pointed) once `/repoman`
  merges — its deliverable is subsumed here.
- **Resolved-issue sweep.** Before/at the start of implementation (after this
  spec is approved), audit the open issues on `rossoctl/automation` against where
  the code now stands — several phases have merged (#94, #95, #106, #108) and
  issues may already be satisfied. Close or re-point any that the current code
  resolves, so the backlog reflects reality before new work piles on. This is a
  one-time cleanup step tracked as part of this phase's implementation, not a
  standing process.
