#!/usr/bin/env bash
# Regression test for the subset-run carry-forward fix (PR #117, huang195
# must-fix) applied to dep-bump: a named-subset run must NOT close the issues of
# stale Dependabot PRs in repos OUTSIDE the subset, and must carry those prior
# stale PRs forward into latest.json.
#
# Drives the REAL dep-bump-scanner.sh with gh stubbed. Scenario: two enrolled
# repos alice/a and bob/b (clones on disk); a prior latest.json holds one stale
# PR in bob/b with an open issue (#42). Scan ONLY alice/a. gh pr list returns
# empty (alice/a has no stale PRs). Expect: bob/b #42 not closed, bob/b stale PR
# carried forward, history.json not appended.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$SCRIPT_DIR/../scripts/dep-bump-scanner.sh"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

BIN="$TEST_TMPDIR/bin"; mkdir -p "$BIN"
CLOSE_LOG="$TEST_TMPDIR/close_calls.txt"; : > "$CLOSE_LOG"
cat > "$BIN/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"issue close"*) echo "CLOSE \$*" >> "$CLOSE_LOG"; exit 0 ;;
  *"pr list"*)     echo "[]"; exit 0 ;;   # alice/a has no open Dependabot PRs
  *"issue list"*|*"search"*) echo "[]"; exit 0 ;;
  *"dependabot/alerts"*) echo "[]"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"

export REPOMAN_CONFIG_FILE="$TEST_TMPDIR/config.json"
export REPOMAN_REPOS_FILE="$TEST_TMPDIR/repos.json"
REPOS_ROOT="$TEST_TMPDIR/repos"
mkdir -p "$REPOS_ROOT/alice/a/.git" "$REPOS_ROOT/bob/b/.git"
printf '{"repos_dir":"%s","fork_owner":"tester"}\n' "$REPOS_ROOT" > "$REPOMAN_CONFIG_FILE"
printf '[{"owner":"alice","name":"a"},{"owner":"bob","name":"b"}]\n' > "$REPOMAN_REPOS_FILE"

REPORTS="$TEST_TMPDIR/reports/dep-bump"; mkdir -p "$REPORTS"
cat > "$REPORTS/latest.json" <<'JSON'
{
  "scan_id": "prev-1",
  "date": "2026-10-01T00:00:00Z",
  "repos_scanned": 2,
  "repos_with_dependabot": 1,
  "total_open_prs": 3,
  "stale_prs": [
    {"repo":"bob/b","pr_number":7,"title":"bump lodash","category":"security",
     "age_days":30,"issue_number":42}
  ],
  "coverage_gaps": [
    {"repo":"bob/b","reason":"no dependabot config"}
  ],
  "repo_pr_counts": [
    {"repo":"bob/b","open_prs":3}
  ],
  "delta": {"new":1,"fixed":0,"recurring":0}
}
JSON
printf '[{"scan_id":"prev-1","fixed":0}]\n' > "$REPORTS/history.json"

SUBSET="$TEST_TMPDIR/subset.json"
printf '[{"owner":"alice","name":"a"}]\n' > "$SUBSET"
REPORTS_DIR="$REPORTS" PATH="$BIN:$PATH" \
  REPOMAN_REPOS_FILE="$SUBSET" REPOMAN_SUBSET_REPOS="alice/a" \
  bash "$SCANNER" >/dev/null 2>&1

if grep -q "issue close" "$CLOSE_LOG" 2>/dev/null; then
  echo "FAIL: subset run closed an out-of-subset issue:"; cat "$CLOSE_LOG"; fail=1
else
  echo "PASS: no out-of-subset issue closed"
fi

carried=$(jq -r '[.stale_prs[] | select(.repo=="bob/b")] | length' "$REPORTS/latest.json" 2>/dev/null)
if [ "$carried" = "1" ]; then
  echo "PASS: bob/b stale PR carried forward into latest.json"
else
  echo "FAIL: bob/b stale PR not carried forward (count=$carried):"; jq -c '.stale_prs' "$REPORTS/latest.json" 2>/dev/null; fail=1
fi

# bob/b's coverage_gap must also be carried forward (not just stale_prs).
cov=$(jq -r '[.coverage_gaps[] | select(.repo=="bob/b")] | length' "$REPORTS/latest.json" 2>/dev/null)
if [ "$cov" = "1" ]; then
  echo "PASS: bob/b coverage_gap carried forward"
else
  echo "FAIL: bob/b coverage_gap not carried forward (count=$cov):"; jq -c '.coverage_gaps' "$REPORTS/latest.json" 2>/dev/null; fail=1
fi

hrows=$(jq 'length' "$REPORTS/history.json" 2>/dev/null)
if [ "$hrows" = "1" ]; then
  echo "PASS: history.json not appended on subset run (still $hrows row)"
else
  echo "FAIL: history.json grew to $hrows rows on a subset run (expected 1)"; fail=1
fi

# H1: scalar totals stay WHOLE-SET-consistent on a subset run (no negative SLA).
# alice/a (scanned) has 0 open PRs; bob/b (unscanned, carried) had 3. The written
# total_open_prs must be 3 (merged), NOT 0 (subset-only) -> so the dashboard's
# (total_open_prs - stale)/total_open_prs stays >= 0. stale_prs has 1 (bob/b).
top=$(jq -r '.total_open_prs' "$REPORTS/latest.json" 2>/dev/null)
rwd=$(jq -r '.repos_with_dependabot' "$REPORTS/latest.json" 2>/dev/null)
stale=$(jq -r '.stale_prs | length' "$REPORTS/latest.json" 2>/dev/null)
if [ "$top" = "3" ] && [ "$rwd" = "1" ]; then
  echo "PASS: subset totals merged whole-set (total_open_prs=$top, repos_with_dependabot=$rwd)"
else
  echo "FAIL: subset totals not merged (total_open_prs=$top want 3, repos_with_dependabot=$rwd want 1)"; fail=1
fi
# the pre-fix bug: stale(3 whole-set) > total_open_prs(subset 0) -> negative SLA.
if [ "$stale" -le "$top" ]; then
  echo "PASS: stale ($stale) <= total_open_prs ($top) -> SLA non-negative"
else
  echo "FAIL: stale ($stale) > total_open_prs ($top) -> dashboard SLA would go negative"; fail=1
fi

# H2: dep-bump dry-run writes NO baseline (the gate Hai flagged as untested).
rm -f "$REPORTS/latest.json" "$REPORTS/history.json"
printf '{"scan_id":"prev-1"}\n' > "$REPORTS/latest.json"   # a baseline to (not) overwrite
PRE=$(cat "$REPORTS/latest.json")
REPORTS_DIR="$REPORTS" PATH="$BIN:$PATH" \
  REPOMAN_REPOS_FILE="$SUBSET" REPOMAN_SUBSET_REPOS="alice/a" \
  bash "$SCANNER" --dry-run >/dev/null 2>&1
if [ "$(cat "$REPORTS/latest.json")" = "$PRE" ]; then
  echo "PASS: dep-bump --dry-run left latest.json untouched"
else
  echo "FAIL: dep-bump --dry-run overwrote latest.json"; fail=1
fi
[ ! -f "$REPORTS/history.json" ] && echo "PASS: dep-bump --dry-run wrote no history.json" \
  || { echo "FAIL: dep-bump --dry-run wrote history.json"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
