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

[ "$fail" -eq 0 ] && echo "PASS: repoman-run" || exit 1
