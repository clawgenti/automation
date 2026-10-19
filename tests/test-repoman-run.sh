#!/usr/bin/env bash
# Tests for scripts/repoman-run.sh (the run-path orchestrator).
#
# Isolation: repoman-run.sh is invoked as a SUBPROCESS (`bash "$RUN"`), not
# sourced. Stubs for gh, repoman-check.sh, repo-sync.sh, repoman-index.sh and
# the scanner scripts are placed in a stub dir resolved via REPOMAN_RUN_BIN
# (the orchestrator's bin seam). Behavior is driven by RUN_STUB_* env vars per
# case. State comes from REPOMAN_CONFIG_FILE/REPOMAN_REPOS_FILE/
# REPOMAN_PROGRAMS_DIR overrides.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$SCRIPT_DIR/../scripts/repoman-run.sh"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

# ---------------------------------------------------------------------------
# Task 1: skeleton — unknown program, --help
# ---------------------------------------------------------------------------

# unknown program -> non-zero + known-programs list on stderr
err=$(bash "$RUN" likn-health 2>&1 >/dev/null); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL unknown-prog: expected non-zero"; fail=1; }
case "$err" in
  *"link-health"*) ;;
  *) echo "FAIL unknown-prog: stderr should list known programs, got [$err]"; fail=1 ;;
esac

# --help -> exit 0, prints usage
out=$(bash "$RUN" --help 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL --help rc=$rc"; fail=1; }
case "$out" in *"Usage:"*) ;; *) echo "FAIL --help no usage"; fail=1 ;; esac

# ---------------------------------------------------------------------------
# Task 2: target reconciliation guard (trust-but-validate the enrolled subset)
# ---------------------------------------------------------------------------

# fixture: two enrolled repos
cat > "$TEST_TMPDIR/repos.json" <<'JSON'
[{"owner":"rossoctl","name":"eventing-lab"},{"owner":"rossoctl","name":"context-service"}]
JSON
FIX="$TEST_TMPDIR/repos.json"

# bare name, one owner -> resolves to owner/name (visible in --dry-run output)
got=$(REPOMAN_REPOS_FILE="$FIX" bash "$RUN" link-health eventing-lab --dry-run 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL resolve-bare rc=$rc: $got"; fail=1; }
case "$got" in *"rossoctl/eventing-lab"*) ;; *) echo "FAIL resolve-bare: [$got]"; fail=1 ;; esac

# owner/name already enrolled -> passes
got=$(REPOMAN_REPOS_FILE="$FIX" bash "$RUN" link-health rossoctl/context-service --dry-run 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL resolve-slug rc=$rc: $got"; fail=1; }

# not-enrolled target -> fail loud naming it
err=$(REPOMAN_REPOS_FILE="$FIX" bash "$RUN" link-health not-a-repo --dry-run 2>&1 >/dev/null); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL unenrolled: expected non-zero"; fail=1; }
case "$err" in *"not-a-repo"*) ;; *) echo "FAIL unenrolled: should name target, got [$err]"; fail=1 ;; esac

# ---------------------------------------------------------------------------
# Task 3: subset projection to env-scoped temp repos.json
# Uses the REPOMAN_RUN_BIN seam to stub the scanner so we can inspect the
# REPOMAN_REPOS_FILE it was handed.
# ---------------------------------------------------------------------------

STUB_DIR="$TEST_TMPDIR/bin"; mkdir -p "$STUB_DIR"
SEEN="$TEST_TMPDIR/seen_repos.json"
# scanner stub: copies whatever repos file it was given so the test can inspect it
cat > "$STUB_DIR/link-health-scanner.sh" <<STUB
#!/usr/bin/env bash
cp "\${REPOMAN_REPOS_FILE:-$FIX}" "$SEEN" 2>/dev/null || true
exit 0
STUB
chmod +x "$STUB_DIR/link-health-scanner.sh"
# minimal stubs so the (later-wired) gate/sync/index steps don't block this case
for s in repoman-check.sh repo-sync.sh repoman-index.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/$s"; chmod +x "$STUB_DIR/$s"
done
# programs dir with output set, so posts_output gate (wired later) passes
PROGDIR="$TEST_TMPDIR/programs"; mkdir -p "$PROGDIR"
echo '{"enabled":true,"output_repo":{"mode":"same"}}' > "$PROGDIR/link-health.json"

# named subset -> scanner sees ONLY that repo
rm -f "$SEEN"
REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$FIX" REPOMAN_PROGRAMS_DIR="$PROGDIR" \
  REPOMAN_INDEX_FILE="$TEST_TMPDIR/_index.json" bash "$RUN" link-health eventing-lab >/dev/null 2>&1
names=$(jq -r '.[].name' "$SEEN" 2>/dev/null | sort | tr '\n' ',')
[ "$names" = "eventing-lab," ] || { echo "FAIL subset-projection: scanner saw [$names] (want eventing-lab,)"; fail=1; }

# no targets -> scanner sees the FULL enrolled set (both repos)
rm -f "$SEEN"
REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$FIX" REPOMAN_PROGRAMS_DIR="$PROGDIR" \
  REPOMAN_INDEX_FILE="$TEST_TMPDIR/_index.json" bash "$RUN" link-health >/dev/null 2>&1
names=$(jq -r '.[].name' "$SEEN" 2>/dev/null | sort | tr '\n' ',')
[ "$names" = "context-service,eventing-lab," ] || { echo "FAIL no-targets: scanner saw [$names] (want full set)"; fail=1; }

# ---------------------------------------------------------------------------
# Task 4: output-routing requirement for posts_output programs
# ---------------------------------------------------------------------------

# missing output_repo -> fail loud "output destination not set"
echo '{"enabled":true}' > "$PROGDIR/link-health.json"
err=$(REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$FIX" REPOMAN_PROGRAMS_DIR="$PROGDIR" \
  bash "$RUN" link-health 2>&1 >/dev/null); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL output-unset: expected non-zero"; fail=1; }
case "$err" in *"output destination not set"*) ;; *) echo "FAIL output-unset msg: [$err]"; fail=1 ;; esac

# mode=central with no repo -> fail loud (malformed)
echo '{"enabled":true,"output_repo":{"mode":"central"}}' > "$PROGDIR/link-health.json"
err=$(REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$FIX" REPOMAN_PROGRAMS_DIR="$PROGDIR" \
  bash "$RUN" link-health 2>&1 >/dev/null); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL output-central-norepo: expected non-zero"; fail=1; }
case "$err" in *"central"*) ;; *) echo "FAIL output-central-norepo msg: [$err]"; fail=1 ;; esac

# mode=same -> ok (program runs)
echo '{"enabled":true,"output_repo":{"mode":"same"}}' > "$PROGDIR/link-health.json"
REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$FIX" REPOMAN_PROGRAMS_DIR="$PROGDIR" \
  REPOMAN_INDEX_FILE="$TEST_TMPDIR/_index.json" bash "$RUN" link-health >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL output-same: rc=$rc"; fail=1; }

# pr-review (posts_output=no) -> no output_repo required, runs without one
cat > "$STUB_DIR/pr-review-scanner.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_DIR/pr-review-scanner.sh"
rm -f "$PROGDIR/pr-review.json"
REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$FIX" REPOMAN_PROGRAMS_DIR="$PROGDIR" \
  bash "$RUN" pr-review >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL pr-review-no-output-gate: rc=$rc"; fail=1; }

# ---------------------------------------------------------------------------
# Task 5: capability gate + clone refresh (profile-gated)
# ---------------------------------------------------------------------------

# instrument stubs to record calls + honor RUN_STUB_*_RC
cat > "$STUB_DIR/repoman-check.sh" <<STUB
#!/usr/bin/env bash
echo "ran-check" >> "$TEST_TMPDIR/calls"
exit "\${RUN_STUB_CHECK_RC:-0}"
STUB
cat > "$STUB_DIR/repo-sync.sh" <<STUB
#!/usr/bin/env bash
echo "ran-sync" >> "$TEST_TMPDIR/calls"
exit "\${RUN_STUB_SYNC_RC:-0}"
STUB
cat > "$STUB_DIR/link-health-scanner.sh" <<STUB
#!/usr/bin/env bash
echo "ran-link-health-scanner" >> "$TEST_TMPDIR/calls"
exit 0
STUB
cat > "$STUB_DIR/automation-health-dashboard.sh" <<STUB
#!/usr/bin/env bash
echo "ran-automation-health-dashboard" >> "$TEST_TMPDIR/calls"
exit 0
STUB
chmod +x "$STUB_DIR"/*.sh
echo '{"enabled":true,"output_repo":{"mode":"same"}}' > "$PROGDIR/link-health.json"

# scope gate fails -> abort non-zero, scanner NOT exec'd
: > "$TEST_TMPDIR/calls"
RUN_STUB_CHECK_RC=1 REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$FIX" \
  REPOMAN_PROGRAMS_DIR="$PROGDIR" REPOMAN_INDEX_FILE="$TEST_TMPDIR/_index.json" \
  bash "$RUN" link-health >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL scope-gate: expected non-zero"; fail=1; }
grep -q "ran-link-health-scanner" "$TEST_TMPDIR/calls" && { echo "FAIL scope-gate: scanner ran anyway"; fail=1; }

# happy path -> check runs, sync runs, scanner runs
: > "$TEST_TMPDIR/calls"
RUN_STUB_CHECK_RC=0 RUN_STUB_SYNC_RC=0 REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$FIX" \
  REPOMAN_PROGRAMS_DIR="$PROGDIR" REPOMAN_INDEX_FILE="$TEST_TMPDIR/_index.json" \
  bash "$RUN" link-health >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL happy-path rc=$rc"; fail=1; }
grep -q "ran-check" "$TEST_TMPDIR/calls" || { echo "FAIL happy-path: check not run"; fail=1; }
grep -q "ran-sync" "$TEST_TMPDIR/calls" || { echo "FAIL happy-path: sync not run"; fail=1; }
grep -q "ran-link-health-scanner" "$TEST_TMPDIR/calls" || { echo "FAIL happy-path: scanner not run"; fail=1; }

# automation-health (index-consumer) -> no check, no sync; dashboard exec'd
: > "$TEST_TMPDIR/calls"
REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$FIX" REPOMAN_PROGRAMS_DIR="$PROGDIR" \
  REPOMAN_INDEX_FILE="$TEST_TMPDIR/_index.json" bash "$RUN" automation-health >/dev/null 2>&1
grep -q "ran-check" "$TEST_TMPDIR/calls" && { echo "FAIL index-consumer ran capability check"; fail=1; }
grep -q "ran-sync" "$TEST_TMPDIR/calls" && { echo "FAIL index-consumer ran clone refresh"; fail=1; }
grep -q "ran-automation-health-dashboard" "$TEST_TMPDIR/calls" || { echo "FAIL index-consumer: dashboard not exec'd"; fail=1; }

# ---------------------------------------------------------------------------
# Task 6: orchestrator owns the index write (single writer)
# ---------------------------------------------------------------------------

# index stub records its args. NOTE: \$* and \$TEST_TMPDIR escaped so they are
# written literally and expand when the STUB runs, not at heredoc creation.
cat > "$STUB_DIR/repoman-index.sh" <<STUB
#!/usr/bin/env bash
echo "index \$*" >> "$TEST_TMPDIR/calls"
exit 0
STUB
chmod +x "$STUB_DIR/repoman-index.sh"
echo '{"enabled":true,"output_repo":{"mode":"same"}}' > "$PROGDIR/link-health.json"

# link-health (writes_index=yes) -> orchestrator invokes index with program+display-name
: > "$TEST_TMPDIR/calls"
RUN_STUB_CHECK_RC=0 RUN_STUB_SYNC_RC=0 REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$FIX" \
  REPOMAN_PROGRAMS_DIR="$PROGDIR" REPOMAN_INDEX_FILE="$TEST_TMPDIR/_index.json" \
  bash "$RUN" link-health >/dev/null 2>&1
grep -q "index .*--program link-health.*--display-name Link Health" "$TEST_TMPDIR/calls" \
  || { echo "FAIL index-write: orchestrator did not write link-health index ($(grep '^index' "$TEST_TMPDIR/calls"))"; fail=1; }

# pr-review (writes_index=no) -> index NOT invoked
: > "$TEST_TMPDIR/calls"
REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$FIX" REPOMAN_PROGRAMS_DIR="$PROGDIR" \
  bash "$RUN" pr-review >/dev/null 2>&1
grep -q "^index " "$TEST_TMPDIR/calls" && { echo "FAIL index-write: pr-review should not be indexed"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: repoman-run" || exit 1
