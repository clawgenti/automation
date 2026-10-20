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

# Shared stub bin + programs dir (used by resolution/projection/gate cases).
# The scanner stub copies the repos file it was handed so the test can inspect
# which repos a run would scan.
STUB_DIR="$TEST_TMPDIR/bin"; mkdir -p "$STUB_DIR"
SEEN="$TEST_TMPDIR/seen_repos.json"
cat > "$STUB_DIR/link-health-scanner.sh" <<STUB
#!/usr/bin/env bash
cp "\${REPOMAN_REPOS_FILE:-$FIX}" "$SEEN" 2>/dev/null || true
exit 0
STUB
chmod +x "$STUB_DIR/link-health-scanner.sh"
for s in repoman-check.sh repo-sync.sh repoman-index.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/$s"; chmod +x "$STUB_DIR/$s"
done
PROGDIR="$TEST_TMPDIR/programs"; mkdir -p "$PROGDIR"
echo '{"enabled":true,"output_repo":{"mode":"same"}}' > "$PROGDIR/link-health.json"

runlh() { # run link-health with the stub env; args are passed through
  REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$FIX" REPOMAN_PROGRAMS_DIR="$PROGDIR" \
    REPOMAN_INDEX_FILE="$TEST_TMPDIR/_index.json" bash "$RUN" "$@"
}

# Task 2: bare name, one owner -> scanner sees exactly that repo (resolution OK)
rm -f "$SEEN"; runlh link-health eventing-lab >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL resolve-bare rc=$rc"; fail=1; }
[ "$(jq -r '.[].name' "$SEEN" 2>/dev/null)" = "eventing-lab" ] \
  || { echo "FAIL resolve-bare: scanner saw [$(jq -rc '[.[].name]' "$SEEN" 2>/dev/null)]"; fail=1; }

# Task 2: owner/name already enrolled -> passes
rm -f "$SEEN"; runlh link-health rossoctl/context-service >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL resolve-slug rc=$rc"; fail=1; }

# Task 2: not-enrolled target -> fail loud naming it (resolution aborts first)
err=$(runlh link-health not-a-repo 2>&1 >/dev/null); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL unenrolled: expected non-zero"; fail=1; }
case "$err" in *"not-a-repo"*) ;; *) echo "FAIL unenrolled: should name target, got [$err]"; fail=1 ;; esac

# Ambiguous bare name (enrolled under TWO owners) -> fail loud, do NOT silently
# expand to both. Uses a fixture where "shared" exists under two owners.
AMBIG="$TEST_TMPDIR/repos-ambig.json"
cat > "$AMBIG" <<'JSON'
[{"owner":"rossoctl","name":"shared"},{"owner":"alice","name":"shared"}]
JSON
err=$(REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$AMBIG" REPOMAN_PROGRAMS_DIR="$PROGDIR" \
  REPOMAN_INDEX_FILE="$TEST_TMPDIR/_index.json" bash "$RUN" link-health shared 2>&1 >/dev/null); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL ambiguous: expected non-zero on 2-owner bare name"; fail=1; }
case "$err" in
  *"ambiguous"*|*"rossoctl/shared"*) ;;
  *) echo "FAIL ambiguous: should name the candidates, got [$err]"; fail=1 ;;
esac

# Duplicate targets -> deduped (scanner sees the repo once, run succeeds)
rm -f "$SEEN"
runlh link-health eventing-lab eventing-lab >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL dedup rc=$rc"; fail=1; }
dupn=$(jq -r '[.[].name] | length' "$SEEN" 2>/dev/null)
[ "$dupn" = "1" ] || { echo "FAIL dedup: scanner saw $dupn entries (want 1)"; fail=1; }

# ---------------------------------------------------------------------------
# Task 3: subset projection to env-scoped temp repos.json
# ---------------------------------------------------------------------------

# named subset -> scanner sees ONLY that repo
rm -f "$SEEN"; runlh link-health eventing-lab >/dev/null 2>&1
names=$(jq -r '.[].name' "$SEEN" 2>/dev/null | sort | tr '\n' ',')
[ "$names" = "eventing-lab," ] || { echo "FAIL subset-projection: scanner saw [$names] (want eventing-lab,)"; fail=1; }

# named subset -> the EXIT trap cleans the temp dir (no leak). Count mktemp
# dirs under $TMPDIR before/after; a subset run must not increase the count.
tmproot="${TMPDIR:-/tmp}"
before_n=$(find "$tmproot" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | wc -l | tr -d ' ')
runlh link-health eventing-lab >/dev/null 2>&1
after_n=$(find "$tmproot" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | wc -l | tr -d ' ')
[ "$after_n" -le "$before_n" ] \
  || { echo "FAIL subset-leak: temp dir not cleaned (before=$before_n after=$after_n)"; fail=1; }

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

# ---------------------------------------------------------------------------
# Task 7: total clone-sync failure is fatal (partial is handled inside repo-sync)
# ---------------------------------------------------------------------------

echo '{"enabled":true,"output_repo":{"mode":"same"}}' > "$PROGDIR/link-health.json"

# total sync failure (repo-sync exits 1) -> abort non-zero, scanner NOT exec'd
: > "$TEST_TMPDIR/calls"
RUN_STUB_CHECK_RC=0 RUN_STUB_SYNC_RC=1 REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$FIX" \
  REPOMAN_PROGRAMS_DIR="$PROGDIR" REPOMAN_INDEX_FILE="$TEST_TMPDIR/_index.json" \
  bash "$RUN" link-health >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL total-sync: expected abort"; fail=1; }
grep -q "ran-link-health-scanner" "$TEST_TMPDIR/calls" \
  && { echo "FAIL total-sync: scanner ran after total sync failure"; fail=1; }

# partial sync (repo-sync exits 0, handled internally) -> run proceeds to exec
: > "$TEST_TMPDIR/calls"
RUN_STUB_CHECK_RC=0 RUN_STUB_SYNC_RC=0 REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$FIX" \
  REPOMAN_PROGRAMS_DIR="$PROGDIR" REPOMAN_INDEX_FILE="$TEST_TMPDIR/_index.json" \
  bash "$RUN" link-health >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL partial-sync: expected success rc=$rc"; fail=1; }
grep -q "ran-link-health-scanner" "$TEST_TMPDIR/calls" \
  || { echo "FAIL partial-sync: scanner should have run"; fail=1; }

# ---------------------------------------------------------------------------
# Dry-run passthrough: --dry-run is forwarded to programs that support it,
# and NOT to those that don't (weekly-report).
# ---------------------------------------------------------------------------

ARGSEEN="$TEST_TMPDIR/argseen"
cat > "$STUB_DIR/link-health-scanner.sh" <<STUB
#!/usr/bin/env bash
echo "lh-args: \$*" > "$ARGSEEN"
exit 0
STUB
cat > "$STUB_DIR/weekly-report.sh" <<STUB
#!/usr/bin/env bash
echo "wr-args: \$*" > "$ARGSEEN"
exit 0
STUB
chmod +x "$STUB_DIR/link-health-scanner.sh" "$STUB_DIR/weekly-report.sh"
echo '{"enabled":true,"output_repo":{"mode":"same"}}' > "$PROGDIR/link-health.json"

# link-health (supports_dry_run=yes) + --dry-run -> scanner receives --dry-run
rm -f "$ARGSEEN"; runlh link-health --dry-run >/dev/null 2>&1
grep -q -- "--dry-run" "$ARGSEEN" 2>/dev/null \
  || { echo "FAIL dry-run-fwd: link-health did not receive --dry-run ($(cat "$ARGSEEN" 2>/dev/null))"; fail=1; }

# link-health WITHOUT --dry-run -> scanner receives no --dry-run
rm -f "$ARGSEEN"; runlh link-health >/dev/null 2>&1
grep -q -- "--dry-run" "$ARGSEEN" 2>/dev/null \
  && { echo "FAIL no-dry-run: link-health wrongly received --dry-run"; fail=1; }

# weekly-report (supports_dry_run=no) + --dry-run -> NOT forwarded
rm -f "$ARGSEEN"
REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$FIX" REPOMAN_PROGRAMS_DIR="$PROGDIR" \
  bash "$RUN" weekly-report --dry-run >/dev/null 2>&1
grep -q -- "--dry-run" "$ARGSEEN" 2>/dev/null \
  && { echo "FAIL weekly-dry-run: --dry-run wrongly forwarded to weekly-report"; fail=1; }

# --- needs_live forwarding: automation-health (previews by default, publishes
# only on --live) must get --live on a normal run and --dry-run on a dry run ---
cat > "$STUB_DIR/automation-health-dashboard.sh" <<STUB
#!/usr/bin/env bash
echo "ah-args: \$*" > "$ARGSEEN"
exit 0
STUB
chmod +x "$STUB_DIR/automation-health-dashboard.sh"

# normal run -> dashboard receives --live (so a scheduled run actually publishes)
rm -f "$ARGSEEN"
REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$FIX" REPOMAN_PROGRAMS_DIR="$PROGDIR" \
  REPOMAN_INDEX_FILE="$TEST_TMPDIR/_index.json" bash "$RUN" automation-health >/dev/null 2>&1
grep -q -- "--live" "$ARGSEEN" 2>/dev/null \
  || { echo "FAIL needs-live: automation-health did not receive --live on a normal run ($(cat "$ARGSEEN" 2>/dev/null))"; fail=1; }

# dry run -> dashboard receives --dry-run, NOT --live
rm -f "$ARGSEEN"
REPOMAN_RUN_BIN="$STUB_DIR" REPOMAN_REPOS_FILE="$FIX" REPOMAN_PROGRAMS_DIR="$PROGDIR" \
  REPOMAN_INDEX_FILE="$TEST_TMPDIR/_index.json" bash "$RUN" automation-health --dry-run >/dev/null 2>&1
grep -q -- "--dry-run" "$ARGSEEN" 2>/dev/null \
  || { echo "FAIL needs-live-dry: automation-health did not receive --dry-run on a dry run"; fail=1; }
grep -q -- "--live" "$ARGSEEN" 2>/dev/null \
  && { echo "FAIL needs-live-dry: --live wrongly forwarded alongside --dry-run"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: repoman-run" || exit 1
