#!/usr/bin/env bash
set -euo pipefail

# Test harness for extract-broken-links.sh
# Run: bash automation/tests/test-extract-broken-links.sh
# Exit code 0 = all tests pass, 1 = at least one failure.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTOR="$SCRIPT_DIR/../scripts/extract-broken-links.sh"
TMPDIR=$(mktemp -d "/tmp/test-extract-broken-XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

REPO="kagenti-extensions"
REPOS_PREFIX="/home/claw/kagenti/kagenti-extensions/"

PASS=0
FAIL=0

# --- Helper: write a lychee-shaped JSON fixture with a single error_map entry ---
# Args: <out-file> <filepath-key> <url> <status-json>
# status-json is the raw .status object, e.g. '{"text":"Network error"}' or '{"code":404}'.
write_fixture() {
  local out="$1" filepath="$2" url="$3" status="$4"
  jq -n \
    --arg fp "$filepath" \
    --arg url "$url" \
    --argjson status "$status" \
    '{ error_map: { ($fp): [ { url: $url, status: $status } ] } }' \
    > "$out"
}

# --- Helper: run extractor on a fixture, apply a jq check to the JSONL output ---
# Args: <name> <fixture-file> <jq-check> <expected>
# The extractor emits zero-or-more JSON objects (one per line); we slurp them.
run_test() {
  local name="$1" fixture="$2" jq_check="$3" expected="$4"

  local output actual
  output=$("$EXTRACTOR" "$fixture" "$REPO" "$REPOS_PREFIX")
  actual=$(printf '%s\n' "$output" | jq -s -r "$jq_check")

  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    echo "    Expected: $expected"
    echo "    Got:      $actual"
    FAIL=$((FAIL + 1))
  fi
}

# =============================================================================
# Fix #1: bare .svc hostnames must be suppressed
# =============================================================================
echo "Test 1: bare .svc URL is suppressed"
write_fixture "$TMPDIR/svc.json" \
  "authbridge/demos/github-issue/demo-aiac.md" \
  "http://keycloak-service.keycloak.svc:8080/realms/" \
  '{"text":"Network error"}'
run_test "bare .svc suppressed (0 records)" "$TMPDIR/svc.json" 'length' '0'

# =============================================================================
# Regressions: previously-suppressed classes stay suppressed
# =============================================================================
echo "Test 2: .svc.cluster.local still suppressed"
write_fixture "$TMPDIR/clusterlocal.json" \
  "docs/a.md" \
  "http://svc.foo.svc.cluster.local:8080/x" \
  '{"text":"Network error"}'
run_test ".svc.cluster.local suppressed" "$TMPDIR/clusterlocal.json" 'length' '0'

echo "Test 3: .local still suppressed"
write_fixture "$TMPDIR/local.json" \
  "docs/b.md" \
  "http://my-box.local/status" \
  '{"text":"Network error"}'
run_test ".local suppressed" "$TMPDIR/local.json" 'length' '0'

echo "Test 4: RFC1918 ranges still suppressed"
write_fixture "$TMPDIR/rfc10.json" "docs/c.md" \
  "http://10.20.4.11:9090/api" '{"text":"Network error"}'
run_test "10.x suppressed" "$TMPDIR/rfc10.json" 'length' '0'

write_fixture "$TMPDIR/rfc172.json" "docs/c.md" \
  "http://172.16.0.5/api" '{"text":"Network error"}'
run_test "172.16-31.x suppressed" "$TMPDIR/rfc172.json" 'length' '0'

write_fixture "$TMPDIR/rfc192.json" "docs/c.md" \
  "http://192.168.1.1/api" '{"text":"Network error"}'
run_test "192.168.x suppressed" "$TMPDIR/rfc192.json" 'length' '0'

# =============================================================================
# Genuine broken links must still pass through with correct fields
# =============================================================================
echo "Test 5: genuine external broken link passes through"
write_fixture "$TMPDIR/ext.json" \
  "docs/d.md" \
  "https://example.invalid/gone" \
  '{"code":404}'
run_test "external record count" "$TMPDIR/ext.json" 'length' '1'
run_test "external status normalized" "$TMPDIR/ext.json" '.[0].status' '404'
run_test "external category" "$TMPDIR/ext.json" '.[0].category' 'external'
run_test "external repo prefixed" "$TMPDIR/ext.json" '.[0].repo' 'kagenti/kagenti-extensions'
run_test "external file prefix stripped" "$TMPDIR/ext.json" '.[0].file' 'docs/d.md'
run_test "external url preserved" "$TMPDIR/ext.json" '.[0].url' 'https://example.invalid/gone'

echo "Test 6: kagenti GitHub URL is category internal"
write_fixture "$TMPDIR/int.json" \
  "docs/e.md" \
  "https://github.com/kagenti/kagenti/blob/main/missing.md" \
  '{"code":404}'
run_test "internal category" "$TMPDIR/int.json" '.[0].category' 'internal'

echo "Test 7: text status normalized to unreachable"
write_fixture "$TMPDIR/unreach.json" \
  "docs/f.md" \
  "https://real-host.example.org/x" \
  '{"text":"Connection refused"}'
run_test "unreachable status token" "$TMPDIR/unreach.json" '.[0].status' 'unreachable'

# =============================================================================
# Edge cases: empty / missing error_map yields no output; valid JSONL
# =============================================================================
echo "Test 8: missing error_map yields no output"
echo '{"total":5,"errors":0}' > "$TMPDIR/noerrors.json"
run_test "no error_map -> empty" "$TMPDIR/noerrors.json" 'length' '0'

echo "Test 9: empty error_map yields no output"
echo '{"error_map":{}}' > "$TMPDIR/emptymap.json"
run_test "empty error_map -> empty" "$TMPDIR/emptymap.json" 'length' '0'

echo "Test 10: non-URL error entries are skipped"
jq -n '{ error_map: { "docs/g.md": [ { url: "Error building URL", status: {text:"Invalid"} } ] } }' \
  > "$TMPDIR/nonurl.json"
run_test "non-URL entry skipped" "$TMPDIR/nonurl.json" 'length' '0'

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
