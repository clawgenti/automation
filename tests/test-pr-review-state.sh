#!/usr/bin/env bash
set -euo pipefail

# Unit test for scripts/pr-review-lib.sh (Phase 7 state envelope).
# Offline, no gh. Verifies envelope<->working conversion and legacy migration.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/../scripts"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/program-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/pr-review-lib.sh"

TMPDIR=$(mktemp -d "/tmp/test-pr-review-state-XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if eval "$cond"; then echo "  PASS: $name"; PASS=$((PASS+1))
  else echo "  FAIL: $name"; FAIL=$((FAIL+1)); fi
}

echo "=== pr-review-lib state envelope test ==="

# --- Case 1: missing file -> empty working shape ---
missing="$TMPDIR/nope.json"
w=$(pr_review_state_load "$missing")
check "missing: reviewed is empty array" \
  "[ \"\$(echo '$w' | jq -c '.reviewed')\" = '[]' ]"
check "missing: in_progress is empty array" \
  "[ \"\$(echo '$w' | jq -c '.in_progress')\" = '[]' ]"

# --- Case 2: legacy file -> passed through as working shape ---
legacy="$TMPDIR/legacy.json"
cat > "$legacy" <<'JSON'
{"in_progress":[{"repo":"o/r","number":5,"head_sha":"deadbeef","started_at":"2026-10-01T00:00:00Z"}],
 "reviewed":[{"repo":"o/r","number":9,"head_sha":"cafef00d","reviewed_at":"2026-10-02T00:00:00Z"}]}
JSON
w=$(pr_review_state_load "$legacy")
check "legacy: reviewed entry preserved" \
  "[ \"\$(echo '$w' | jq -r '.reviewed[0].head_sha')\" = 'cafef00d' ]"
check "legacy: in_progress entry preserved" \
  "[ \"\$(echo '$w' | jq -r '.in_progress[0].number')\" = '5' ]"

# --- Case 3: round-trip write -> envelope v1 on disk, load back to working ---
dest="$TMPDIR/state.json"
echo "$w" > "$TMPDIR/working.json"
pr_review_state_write "$TMPDIR/working.json" "$dest" "pr-review-scanner"
check "write: schema_version == 1" \
  "[ \"\$(jq -r '.schema_version' '$dest')\" = '1' ]"
check "write: program recorded" \
  "[ \"\$(jq -r '.program' '$dest')\" = 'pr-review-scanner' ]"
check "write: reviewed -> acted_on keyed repo:number" \
  "[ \"\$(jq -r '.acted_on[\"o/r:9\"].head_sha' '$dest')\" = 'cafef00d' ]"
check "write: acted_on carries at = reviewed_at" \
  "[ \"\$(jq -r '.acted_on[\"o/r:9\"].at' '$dest')\" = '2026-10-02T00:00:00Z' ]"
check "write: acted_on carries ttl_days 30" \
  "[ \"\$(jq -r '.acted_on[\"o/r:9\"].ttl_days' '$dest')\" = '30' ]"
check "write: in_progress -> program_data.in_progress" \
  "[ \"\$(jq -r '.program_data.in_progress[0].number' '$dest')\" = '5' ]"
# load the envelope back -> working shape identical in content
w2=$(pr_review_state_load "$dest")
check "round-trip: reviewed head_sha survives" \
  "[ \"\$(echo '$w2' | jq -r '.reviewed[0].head_sha')\" = 'cafef00d' ]"
check "round-trip: reviewed_at reconstructed from at" \
  "[ \"\$(echo '$w2' | jq -r '.reviewed[0].reviewed_at')\" = '2026-10-02T00:00:00Z' ]"
check "round-trip: in_progress survives" \
  "[ \"\$(echo '$w2' | jq -r '.in_progress[0].started_at')\" = '2026-10-01T00:00:00Z' ]"

# --- Case 4: invalid JSON -> empty working shape, non-destructively ---
bad="$TMPDIR/bad.json"
echo 'not json {' > "$bad"
w=$(pr_review_state_load "$bad" 2>/dev/null)
check "invalid: falls back to empty reviewed" \
  "[ \"\$(echo '$w' | jq -c '.reviewed')\" = '[]' ]"
# The spec promises the fallback is non-destructive: the bad file is logged to
# stderr but NOT rewritten. Assert the on-disk content is byte-for-byte intact.
check "invalid: bad file left untouched (non-destructive)" \
  "[ \"\$(cat '$bad')\" = 'not json {' ]"

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
