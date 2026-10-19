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

[ "$fail" -eq 0 ] && echo "PASS: repoman-run" || exit 1
