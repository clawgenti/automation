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
    printf 'fatal: could not clone %s\n' "$url" >&2; exit 1
  fi
  mkdir -p "$dir/.git"; exit 0
elif [ "${1-}" = "-C" ]; then
  # git -C <dir> pull --ff-only
  dir="$2"
  if matches "$dir" "${GIT_STUB_PULL_FAIL_FOR-}"; then
    printf 'fatal: not possible to fast-forward in %s\n' "$dir" >&2; exit 1
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
printf '%s' "$out" | grep -q "repos" || { echo "FAIL c5: message does not name the repos file"; fail=1; }
printf '%s' "$out" | grep -qi "gh repo list" && { echo "FAIL c5: a \$ORG fallback fired"; fail=1; }
# restore repos.json for any later cases
printf '[{"owner":"alice","name":"tool"},{"owner":"bob","name":"lib"}]\n' > "$REPOMAN_REPOS_FILE"

exit "$fail"
