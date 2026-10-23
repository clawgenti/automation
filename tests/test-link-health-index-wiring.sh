#!/usr/bin/env bash
# Verifies the _index.json wiring for link-health after the run-path change:
#
#   1. The scanner run DIRECTLY no longer self-registers (writes no _index.json).
#      Registration moved to the run-path orchestrator (the sole index writer).
#   2. `repoman run link-health` DOES register the program: the orchestrator
#      invokes the REAL repoman-index.sh and the entry has the right
#      display_name + report_path.
#
# Isolation: fixtures via REPOMAN_CONFIG_FILE / REPOMAN_REPOS_FILE. The enrolled
# repo has no clone on disk, so the scanner's scan loop is a no-op (--dry-run).
# For case 2 the capability gate and clone refresh are stubbed via REPOMAN_RUN_BIN
# so no gh/git/network is touched; the scanner is stubbed too so the test asserts
# ONLY the orchestrator's index write (the scanner's own exec is covered by its
# tests). repoman-index.sh is the REAL script.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$SCRIPT_DIR/../scripts/link-health-scanner.sh"
RUN="$SCRIPT_DIR/../scripts/repoman-run.sh"
REAL_SCRIPTS="$SCRIPT_DIR/../scripts"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

STUB_DIR="$TEST_TMPDIR/bin"; mkdir -p "$STUB_DIR"
# gh stub: no-op success (the direct-scan case may reach a gh call tail).
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_DIR/gh"

export REPOMAN_CONFIG_FILE="$TEST_TMPDIR/config.json"
export REPOMAN_REPOS_FILE="$TEST_TMPDIR/repos.json"
REPOS_ROOT="$TEST_TMPDIR/repos"
mkdir -p "$REPOS_ROOT"
printf '{"repos_dir":"%s","fork_owner":"tester"}\n' "$REPOS_ROOT" > "$REPOMAN_CONFIG_FILE"
printf '[{"owner":"alice","name":"tool"}]\n' > "$REPOMAN_REPOS_FILE"

REPORTS="$TEST_TMPDIR/reports/link-health"
export REPOMAN_INDEX_FILE="$TEST_TMPDIR/reports/_index.json"

# --- Case 1: direct scanner run does NOT write the index ---
rm -rf "$TEST_TMPDIR/reports"
out=$(REPORTS_DIR="$REPORTS" PATH="$STUB_DIR:$PATH" bash "$SCANNER" --dry-run 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c1: scanner exit $rc"; echo "$out"; fail=1; }
[ ! -f "$REPOMAN_INDEX_FILE" ] \
  || { echo "FAIL c1: scanner self-wrote the index ($REPOMAN_INDEX_FILE should not exist)"; fail=1; }

# --- Case 2: `repoman run link-health` writes the index via the real writer ---
# Stub capability gate, clone refresh, and the scanner itself; use the REAL
# repoman-index.sh so the orchestrator's write is exercised end to end.
RUNBIN="$TEST_TMPDIR/runbin"; mkdir -p "$RUNBIN"
for s in repoman-check.sh repo-sync.sh link-health-scanner.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$RUNBIN/$s"; chmod +x "$RUNBIN/$s"
done
ln -s "$REAL_SCRIPTS/repoman-index.sh" "$RUNBIN/repoman-index.sh"
PROGDIR="$TEST_TMPDIR/programs"; mkdir -p "$PROGDIR"
echo '{"enabled":true,"output_repo":{"mode":"same"}}' > "$PROGDIR/link-health.json"
rm -rf "$TEST_TMPDIR/reports"

out=$(REPOMAN_RUN_BIN="$RUNBIN" REPOMAN_PROGRAMS_DIR="$PROGDIR" \
      PATH="$STUB_DIR:$PATH" bash "$RUN" link-health 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c2: repoman run exit $rc"; echo "$out"; fail=1; }
[ -f "$REPOMAN_INDEX_FILE" ] || { echo "FAIL c2: orchestrator did not write index"; fail=1; }
[ "$(jq -r '.["link-health"].display_name' "$REPOMAN_INDEX_FILE" 2>/dev/null)" = "Link Health" ] \
  || { echo "FAIL c2: link-health entry missing/wrong display_name"; fail=1; }
got_rp=$(jq -r '.["link-health"].report_path' "$REPOMAN_INDEX_FILE" 2>/dev/null)
case "$got_rp" in
  */reports/link-health) ;;
  *) echo "FAIL c2: report_path wrong: [$got_rp]"; fail=1 ;;
esac

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
