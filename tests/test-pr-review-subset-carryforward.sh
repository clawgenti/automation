#!/usr/bin/env bash
# Regression test for the subset-run carry-forward fix (PR #117, huang195
# must-fix) applied to pr-review: a named-subset run must NOT evict the
# reviewed/in_progress state entries of repos OUTSIDE the subset. pr-review's
# eviction pass drops entries not in the current open+labeled set, but on a
# subset run that set only covers scanned repos — so an out-of-subset entry
# must be carried forward, not evicted.
#
# Drives the REAL pr-review-scanner.sh with gh stubbed (no open PRs anywhere, so
# open_keys.txt is empty and the ONLY thing protecting bob/b's entries is the
# scanned-repo scoping). Entries are recent (not TTL/stale-expired).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$SCRIPT_DIR/../scripts/pr-review-scanner.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../scripts/pr-review-lib.sh"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

BIN="$TEST_TMPDIR/bin"; mkdir -p "$BIN"
# gh stub: no open PRs for any repo; everything else empty-success.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*) echo "[]"; exit 0 ;;
  *) echo "[]"; exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"

export REPOMAN_CONFIG_FILE="$TEST_TMPDIR/config.json"
export REPOMAN_REPOS_FILE="$TEST_TMPDIR/repos.json"
printf '{"repos_dir":"%s/repos","fork_owner":"tester"}\n' "$TEST_TMPDIR" > "$REPOMAN_CONFIG_FILE"
printf '[{"owner":"alice","name":"a"},{"owner":"bob","name":"b"}]\n' > "$REPOMAN_REPOS_FILE"

REPORTS="$TEST_TMPDIR/reports/pr-review"; mkdir -p "$REPORTS"
# Prior state: a recent in_progress + reviewed entry, both in bob/b (out of the
# alice/a subset). "recent" timestamps so TTL/stale checks do not evict them.
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$REPORTS/state.json" <<JSON
{"in_progress":[{"repo":"bob/b","number":7,"head_sha":"abc","started_at":"$NOW"}],
 "reviewed":[{"repo":"bob/b","number":9,"head_sha":"def","reviewed_at":"$NOW"}]}
JSON
# Prior latest.json eligible_prs (all in bob/b, out of the alice/a subset):
#  - #11: genuinely eligible, not in state -> MUST be carried forward (step 3).
#  - #9 @head_sha def: already in state.reviewed at the SAME head_sha -> MUST be
#    dropped (C1: carrying it would make the fixer re-review an unchanged PR).
cat > "$REPORTS/latest.json" <<JSON
{"scan_id":"prev-1","date":"2026-10-01T00:00:00Z","repos_scanned":2,
 "candidates_found":2,"eligible_prs":[{"repo":"bob/b","number":11,"head_sha":"zzz"},
   {"repo":"bob/b","number":9,"head_sha":"def"}]}
JSON
printf '[{"scan_id":"prev-1","eligible":1}]\n' > "$REPORTS/history.json"

# Subset run: scan ONLY alice/a.
SUBSET="$TEST_TMPDIR/subset.json"
printf '[{"owner":"alice","name":"a"}]\n' > "$SUBSET"
REPORTS_DIR="$REPORTS" PATH="$BIN:$PATH" \
  REPOMAN_REPOS_FILE="$SUBSET" REPOMAN_SUBSET_REPOS="alice/a" \
  bash "$SCANNER" >/dev/null 2>&1

# Load the written state back and assert bob/b's entries survived.
w=$(pr_review_state_load "$REPORTS/state.json")
ip=$(printf '%s' "$w" | jq -r '[.in_progress[] | select(.repo=="bob/b")] | length' 2>/dev/null)
rv=$(printf '%s' "$w" | jq -r '[.reviewed[] | select(.repo=="bob/b")] | length' 2>/dev/null)
if [ "$ip" = "1" ]; then
  echo "PASS: bob/b in_progress entry carried forward"
else
  echo "FAIL: bob/b in_progress entry evicted on subset run (count=$ip)"; fail=1
fi
if [ "$rv" = "1" ]; then
  echo "PASS: bob/b reviewed entry carried forward"
else
  echo "FAIL: bob/b reviewed entry evicted on subset run (count=$rv)"; fail=1
fi

# Step 3: the genuinely-eligible out-of-subset PR (#11) is carried forward.
has11=$(jq -r '[.eligible_prs[] | select(.repo=="bob/b" and .number==11)] | length' "$REPORTS/latest.json" 2>/dev/null)
if [ "$has11" = "1" ]; then
  echo "PASS: bob/b#11 (eligible, unhandled) carried forward"
else
  echo "FAIL: bob/b#11 not carried forward (count=$has11):"; jq -c '.eligible_prs' "$REPORTS/latest.json" 2>/dev/null; fail=1
fi

# C1: the already-reviewed PR (#9, in state.reviewed at same head_sha) is DROPPED
# from the carried set, so the fixer won't re-review an unchanged PR.
has9=$(jq -r '[.eligible_prs[] | select(.repo=="bob/b" and .number==9)] | length' "$REPORTS/latest.json" 2>/dev/null)
if [ "$has9" = "0" ]; then
  echo "PASS: bob/b#9 (already reviewed at same head_sha) dropped from carried set"
else
  echo "FAIL: bob/b#9 wrongly carried forward -> would cause a duplicate review"; jq -c '.eligible_prs' "$REPORTS/latest.json" 2>/dev/null; fail=1
fi

# Step 4: history.json not appended on a subset run (still 1 row).
hrows=$(jq 'length' "$REPORTS/history.json" 2>/dev/null)
if [ "$hrows" = "1" ]; then
  echo "PASS: history.json not appended on subset run (still $hrows row)"
else
  echo "FAIL: history.json grew to $hrows rows on a subset run (expected 1)"; fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
