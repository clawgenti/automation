#!/usr/bin/env bash
# Tests for scripts/repo-sync.sh.
#
# Isolation: repo-sync.sh runs as a SUBPROCESS (`bash "$SYNC"`), so we shadow
# `git` with a scripted stub at the front of PATH. The stub records each call
# and fakes clone/pull success or failure per GIT_STUB_* env this test sets.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$SCRIPT_DIR/../scripts/repo-sync.sh"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

STUB_DIR="$TEST_TMPDIR/bin"; mkdir -p "$STUB_DIR"
CALL_LOG="$TEST_TMPDIR/git_calls.log"

# git stub: supports `git clone <url> <dir>` and `git -C <dir> pull --ff-only`.
# Knobs (space-separated "owner/name" lists):
#   GIT_STUB_CLONE_FAIL_FOR : clone exits 1 (stderr) when <dir> ends with one of these
#   GIT_STUB_PULL_FAIL_FOR  : pull exits 1 (stderr) when -C <dir> ends with one of these
# A successful clone creates "<dir>/.git" so a later run sees the repo as present.
cat > "$STUB_DIR/git" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$CALL_LOG"
matches() { # $1 = dir, $2 = space list of owner/name suffixes
  local d="$1" list="$2" s
  for s in $list; do case "$d" in */"$s") return 0 ;; esac; done
  return 1
}
if [ "${1-}" = "clone" ]; then
  # git clone <url> <dir>
  url="$2"; dir="$3"
  if matches "$dir" "${GIT_STUB_CLONE_FAIL_FOR-}"; then
    # Real git writes a progress line FIRST, then the error last. The summary
    # must attach the error line, not the progress line (head -n1 would grab
    # the wrong one).
    printf "Cloning into '%s'...\n" "$dir" >&2
    printf 'fatal: repository not found: %s\n' "$url" >&2; exit 1
  fi
  mkdir -p "$dir/.git"; exit 0
elif [ "${1-}" = "-C" ]; then
  # git -C <dir> pull --ff-only
  dir="$2"
  if matches "$dir" "${GIT_STUB_PULL_FAIL_FOR-}"; then
    printf 'From https://github.com/%s\n' "$dir" >&2
    printf 'fatal: not a git repository: %s\n' "$dir" >&2; exit 1
  fi
  exit 0
fi
printf 'git stub: unhandled args: %s\n' "$*" >&2; exit 2
STUB
chmod +x "$STUB_DIR/git"
export CALL_LOG GIT_STUB_CLONE_FAIL_FOR GIT_STUB_PULL_FAIL_FOR

# fixtures: config.json + repos.json via the reader's env overrides
export REPOMAN_CONFIG_FILE="$TEST_TMPDIR/config.json"
export REPOMAN_REPOS_FILE="$TEST_TMPDIR/repos.json"
REPOS_ROOT="$TEST_TMPDIR/repos"
printf '{"repos_dir":"%s","fork_owner":"rubambiza"}\n' "$REPOS_ROOT" > "$REPOMAN_CONFIG_FILE"
printf '[{"owner":"alice","name":"tool"},{"owner":"bob","name":"lib"}]\n' > "$REPOMAN_REPOS_FILE"

run_sync() { PATH="$STUB_DIR:$PATH" bash "$SYNC" "$@"; }

# Case 1: both repos missing -> both cloned, exit 0
: > "$CALL_LOG"; rm -rf "$REPOS_ROOT"
out=$(run_sync 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c1: exit $rc"; fail=1; }
grep -q "clone .*/alice/tool" "$CALL_LOG" || { echo "FAIL c1: alice/tool not cloned"; fail=1; }
grep -q "clone .*/bob/lib"    "$CALL_LOG" || { echo "FAIL c1: bob/lib not cloned"; fail=1; }
# Pin the exact clone URL, not just the destination dir: a dir-only grep matches
# even if owner/name are swapped in the URL (github.com/$name/$owner.git).
grep -qF "clone https://github.com/alice/tool.git " "$CALL_LOG" || { echo "FAIL c1: alice/tool clone URL wrong"; fail=1; }
grep -qF "clone https://github.com/bob/lib.git " "$CALL_LOG" || { echo "FAIL c1: bob/lib clone URL wrong"; fail=1; }
printf '%s' "$out" | grep -q "cloned 2" || { echo "FAIL c1: summary not 'cloned 2'"; fail=1; }

# Case 2: both present -> both pulled, exit 0
: > "$CALL_LOG"; mkdir -p "$REPOS_ROOT/alice/tool/.git" "$REPOS_ROOT/bob/lib/.git"
out=$(run_sync 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c2: exit $rc"; fail=1; }
grep -q -- "-C .*/alice/tool pull" "$CALL_LOG" || { echo "FAIL c2: alice/tool not pulled"; fail=1; }
printf '%s' "$out" | grep -q "pulled 2" || { echo "FAIL c2: summary not 'pulled 2'"; fail=1; }

# Case 3: mixed present/absent -> correct split (alice present, bob absent)
: > "$CALL_LOG"; rm -rf "$REPOS_ROOT"; mkdir -p "$REPOS_ROOT/alice/tool/.git"
out=$(run_sync 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c3: exit $rc"; fail=1; }
printf '%s' "$out" | grep -q "pulled 1" || { echo "FAIL c3: not 'pulled 1'"; fail=1; }
printf '%s' "$out" | grep -q "cloned 1" || { echo "FAIL c3: not 'cloned 1'"; fail=1; }

# Case 4: one repo's clone fails -> counted failed, other still cloned, EXIT 0,
# and the failed repo is named (surface-every-failure, non-fatal swallow).
: > "$CALL_LOG"; rm -rf "$REPOS_ROOT"
out=$(GIT_STUB_CLONE_FAIL_FOR="tool" run_sync 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c4: exit should stay 0, got $rc"; fail=1; }
grep -q "clone .*/bob/lib" "$CALL_LOG" || { echo "FAIL c4: bob/lib not attempted after alice failed"; fail=1; }
printf '%s' "$out" | grep -q "failed 1" || { echo "FAIL c4: not 'failed 1'"; fail=1; }
printf '%s' "$out" | grep -q "alice/tool" || { echo "FAIL c4: failed repo not named"; fail=1; }

# Case 5: repos.json absent -> fail loud, exit non-zero, message names the file,
# and NO $ORG / 'gh repo list' fallback fired (assert the message, not just exit).
: > "$CALL_LOG"; rm -f "$REPOMAN_REPOS_FILE"
out=$(run_sync 2>&1); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL c5: absent repos.json should fail loud"; fail=1; }
printf '%s' "$out" | grep -qF "$REPOMAN_REPOS_FILE" || { echo "FAIL c5: message does not name the repos file"; fail=1; }
printf '%s' "$out" | grep -qi "gh repo list" && { echo "FAIL c5: a \$ORG fallback fired"; fail=1; }
# restore repos.json for any later cases
printf '[{"owner":"alice","name":"tool"},{"owner":"bob","name":"lib"}]\n' > "$REPOMAN_REPOS_FILE"

# Case 6: --refresh-skills FLAG alone (no REPOMAN_SKILLS_DIR) -> skills pull
# invoked once against the DEFAULT path ($HOME/agent-skills). Point HOME at a
# temp dir so the flag exercises the default-path branch, not the env override.
: > "$CALL_LOG"; rm -rf "$REPOS_ROOT"; mkdir -p "$REPOS_ROOT/alice/tool/.git" "$REPOS_ROOT/bob/lib/.git"
FAKE_HOME="$TEST_TMPDIR/home"; mkdir -p "$FAKE_HOME/agent-skills/.git"
out=$(HOME="$FAKE_HOME" run_sync --refresh-skills 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c6: exit $rc"; fail=1; }
grep -q -- "-C $FAKE_HOME/agent-skills pull" "$CALL_LOG" || { echo "FAIL c6: default-path skills clone not pulled"; fail=1; }

# Case 6b: skills dir PRESENT but the pull FAILS -> fatal (exit non-zero), the
# failure is surfaced (not swallowed), and the failing dir is named. A skills
# pull that fails silently would leave a stale skills clone masquerading as fresh.
: > "$CALL_LOG"; rm -rf "$REPOS_ROOT"; mkdir -p "$REPOS_ROOT/alice/tool/.git" "$REPOS_ROOT/bob/lib/.git"
SKILLS_DIR="$TEST_TMPDIR/agent-skills"; mkdir -p "$SKILLS_DIR/.git"
out=$(REPOMAN_SKILLS_DIR="$SKILLS_DIR" GIT_STUB_PULL_FAIL_FOR="agent-skills" run_sync --refresh-skills 2>&1); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL c6b: skills pull failure should be fatal, got exit $rc"; fail=1; }
printf '%s' "$out" | grep -qi "skills refresh failed" || { echo "FAIL c6b: skills pull failure not surfaced"; fail=1; }
printf '%s' "$out" | grep -qF "$SKILLS_DIR" || { echo "FAIL c6b: message does not name the failing skills dir"; fail=1; }

# Case 7: --refresh-skills with skills dir ABSENT -> FATAL, exit non-zero,
# message names the missing dir, and NO clone attempted for it.
: > "$CALL_LOG"; rm -rf "$REPOS_ROOT"; mkdir -p "$REPOS_ROOT/alice/tool/.git" "$REPOS_ROOT/bob/lib/.git"
MISSING_SKILLS="$TEST_TMPDIR/no-skills-here"; rm -rf "$MISSING_SKILLS"
out=$(REPOMAN_SKILLS_DIR="$MISSING_SKILLS" run_sync --refresh-skills 2>&1); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL c7: absent skills dir should be fatal"; fail=1; }
printf '%s' "$out" | grep -q "$MISSING_SKILLS" || { echo "FAIL c7: message does not name the missing skills dir"; fail=1; }
grep -q "clone .*no-skills-here" "$CALL_LOG" && { echo "FAIL c7: attempted to bootstrap-clone skills dir"; fail=1; }

# Case 8: --help -> usage, exit 0
out=$(run_sync --help 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c8: --help exit $rc"; fail=1; }
printf '%s' "$out" | grep -qi "usage" || { echo "FAIL c8: --help lacks usage"; fail=1; }

# Case 9: mkdir for the clone target fails (ENOTDIR) -> each such repo is counted
# failed with an accurate "mkdir failed" label and processing does not abort
# mid-loop (both repos are still attempted). Here the repos_dir sits under a
# regular file, so mkdir fails for BOTH repos -> this is an all-failed run, which
# the exit model treats as fatal (exit non-zero); partial mkdir failure staying
# non-fatal is covered by the partial-failure cases (4, 16). The label + count
# assertions confirm the loop kept going rather than aborting on the first mkdir.
: > "$CALL_LOG"
BLOCKER="$TEST_TMPDIR/blocker-file"; : > "$BLOCKER"   # a regular file
# point config's repos_dir at a path under that file so mkdir -p can't create it
printf '{"repos_dir":"%s/repos","fork_owner":"rubambiza"}\n' "$BLOCKER" > "$REPOMAN_CONFIG_FILE"
out=$(run_sync 2>&1); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL c9: all-repos mkdir failure should be fatal (all-failed), got exit $rc"; fail=1; }
printf '%s' "$out" | grep -q "failed 2" || { echo "FAIL c9: not 'failed 2' (both repos should fail mkdir -> loop did not abort early)"; fail=1; }
printf '%s' "$out" | grep -qi "mkdir" || { echo "FAIL c9: failure not labeled 'mkdir'"; fail=1; }
# restore the good config for any later cases / re-runs
printf '{"repos_dir":"%s","fork_owner":"rubambiza"}\n' "$REPOS_ROOT" > "$REPOMAN_CONFIG_FILE"

# Case 10: a PULL failure attaches git's one-line stderr to the repo's summary
# entry (same line as the repo name -- not merely present anywhere in output,
# since git's own uncaptured stderr would otherwise leak into 2>&1 and give a
# false pass).
: > "$CALL_LOG"; rm -rf "$REPOS_ROOT"
mkdir -p "$REPOS_ROOT/alice/tool/.git" "$REPOS_ROOT/bob/lib/.git"
out=$(GIT_STUB_PULL_FAIL_FOR="alice/tool" run_sync 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c10: per-repo pull failure must stay non-fatal, got exit $rc"; fail=1; }
entry=$(printf '%s' "$out" | grep "^  alice/tool")
[ -n "$entry" ] || { echo "FAIL c10: failed repo not named on its own summary entry line"; fail=1; }
printf '%s' "$entry" | grep -q "not a git repository" || { echo "FAIL c10: git stderr not attached to the repo's own summary line"; fail=1; }
# The attached line must be git's error, not its leading progress line. git
# emits progress ("From https://...") first and the fatal line last, so a
# head -n1 capture would wrongly grab the progress line.
printf '%s' "$entry" | grep -q "^  alice/tool (pull): From " && { echo "FAIL c10: progress line attached instead of the fatal error line"; fail=1; }

# Case 11: a CLONE failure attaches git's one-line stderr to the repo's summary
# entry (same line as the repo name; see case 10 for why whole-output grep is
# insufficient).
: > "$CALL_LOG"; rm -rf "$REPOS_ROOT"; mkdir -p "$REPOS_ROOT"
out=$(GIT_STUB_CLONE_FAIL_FOR="alice/tool" run_sync 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c11: per-repo clone failure must stay non-fatal, got exit $rc"; fail=1; }
entry=$(printf '%s' "$out" | grep "^  alice/tool")
[ -n "$entry" ] || { echo "FAIL c11: failed repo not named on its own summary entry line"; fail=1; }
printf '%s' "$entry" | grep -q "repository not found" || { echo "FAIL c11: git stderr not attached to the repo's own summary line"; fail=1; }
# Must be the fatal line, not the leading "Cloning into '...'" progress line.
printf '%s' "$entry" | grep -q "^  alice/tool (clone): Cloning into" && { echo "FAIL c11: progress line attached instead of the fatal error line"; fail=1; }

# Case 12: REPOMAN_SKILLS_DIR set WITHOUT --refresh-skills -> the env var alone
# triggers the refresh (spec 2026-09-28-repoman-phase4-repo-sync-design.md:112,
# standing-orders/repo-sync.md:29 both document the env var as an alternative
# trigger). Skills pull invoked once, exit 0.
: > "$CALL_LOG"; rm -rf "$REPOS_ROOT"; mkdir -p "$REPOS_ROOT/alice/tool/.git" "$REPOS_ROOT/bob/lib/.git"
SKILLS_DIR="$TEST_TMPDIR/agent-skills"; mkdir -p "$SKILLS_DIR/.git"
out=$(REPOMAN_SKILLS_DIR="$SKILLS_DIR" run_sync 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c12: exit $rc"; fail=1; }
grep -q -- "-C $SKILLS_DIR pull" "$CALL_LOG" || { echo "FAIL c12: env var alone did not trigger skills pull"; fail=1; }

# Case 13: REPOMAN_SKILLS_DIR set WITHOUT --refresh-skills but the dir is ABSENT
# -> still fatal (exit non-zero), message names the missing dir, no bootstrap
# clone. The error message must NOT claim '--refresh-skills' was passed, since
# the env var was the trigger here (trigger-neutral wording).
: > "$CALL_LOG"; rm -rf "$REPOS_ROOT"; mkdir -p "$REPOS_ROOT/alice/tool/.git" "$REPOS_ROOT/bob/lib/.git"
MISSING_SKILLS="$TEST_TMPDIR/no-skills-env"; rm -rf "$MISSING_SKILLS"
out=$(REPOMAN_SKILLS_DIR="$MISSING_SKILLS" run_sync 2>&1); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL c13: absent skills dir (env trigger) should be fatal"; fail=1; }
printf '%s' "$out" | grep -q "$MISSING_SKILLS" || { echo "FAIL c13: message does not name the missing skills dir"; fail=1; }
grep -q "clone .*no-skills-env" "$CALL_LOG" && { echo "FAIL c13: attempted to bootstrap-clone skills dir"; fail=1; }
printf '%s' "$out" | grep -q -- "--refresh-skills" && { echo "FAIL c13: error wrongly claims --refresh-skills when the env var triggered the refresh"; fail=1; }

# Case 14: an enrolled entry with a path-traversal / unsafe owner or name is
# REJECTED before any mkdir/clone -- it is counted failed and named, the run
# does NOT clone or pull it, and a well-formed sibling entry is still processed.
# Without this, "../../etc" or an absolute name would let repos.json write
# outside the repos_dir tree.
: > "$CALL_LOG"; rm -rf "$REPOS_ROOT"
printf '[{"owner":"..","name":"evil"},{"owner":"alice","name":"tool"}]\n' > "$REPOMAN_REPOS_FILE"
out=$(run_sync 2>&1); rc=$?
# the unsafe entry must never reach git
grep -q "clone" "$CALL_LOG" && grep -q "evil" "$CALL_LOG" && { echo "FAIL c14: unsafe entry reached git clone"; fail=1; }
printf '%s' "$out" | grep -qi "invalid" || { echo "FAIL c14: unsafe entry not flagged invalid"; fail=1; }
printf '%s' "$out" | grep -q "\.\./evil" || { echo "FAIL c14: unsafe entry not named"; fail=1; }
# the well-formed sibling is still cloned
grep -qF "clone https://github.com/alice/tool.git " "$CALL_LOG" || { echo "FAIL c14: safe sibling not cloned"; fail=1; }
# also reject a name containing a slash-dotdot even when owner is clean
: > "$CALL_LOG"; rm -rf "$REPOS_ROOT"
printf '[{"owner":"alice","name":"../../escape"}]\n' > "$REPOMAN_REPOS_FILE"
out=$(run_sync 2>&1); rc=$?
grep -q "clone" "$CALL_LOG" && { echo "FAIL c14: unsafe name reached git clone"; fail=1; }
printf '%s' "$out" | grep -qi "invalid" || { echo "FAIL c14: unsafe name not flagged invalid"; fail=1; }
# restore repos.json for later cases
printf '[{"owner":"alice","name":"tool"},{"owner":"bob","name":"lib"}]\n' > "$REPOMAN_REPOS_FILE"

# Case 15: when EVERY enrolled repo fails, the run exits NON-ZERO (a total
# failure must not report success). One or more successes keeps exit 0
# (covered by case 4); all-failed is the newly-fatal condition.
: > "$CALL_LOG"; rm -rf "$REPOS_ROOT"
out=$(GIT_STUB_CLONE_FAIL_FOR="tool lib" run_sync 2>&1); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL c15: all-repos-failed should exit non-zero, got $rc"; fail=1; }
printf '%s' "$out" | grep -q "failed 2" || { echo "FAIL c15: not 'failed 2'"; fail=1; }

# Case 16: a PARTIAL failure (some fail, some succeed) still exits 0 -- confirm
# case 15's fatal condition is specifically "all failed", not "any failed".
: > "$CALL_LOG"; rm -rf "$REPOS_ROOT"
out=$(GIT_STUB_CLONE_FAIL_FOR="tool" run_sync 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c16: partial failure must stay exit 0, got $rc"; fail=1; }
printf '%s' "$out" | grep -q "failed 1" || { echo "FAIL c16: not 'failed 1'"; fail=1; }
printf '%s' "$out" | grep -q "cloned 1" || { echo "FAIL c16: not 'cloned 1'"; fail=1; }

exit "$fail"
