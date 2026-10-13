#!/usr/bin/env bash
set -euo pipefail

# Verifies repoman_match_name() in org.sh (loaded via program-lib.sh):
#   - bare name, one enrolled owner  -> emits that one owner/name
#   - bare name, two enrolled owners -> emits both, one per line, file order
#   - bare name, no enrolled owner   -> no output, return 0
#   - substring (not whole-name)     -> no output (no false positive)
#   - owner-looking token            -> no output (matches names, not owners)
#   - empty/malformed repos.json     -> fails loud (propagates repoman_get_repos)
# Hermetic: drives via $REPOMAN_REPOS_FILE pointing at a scratch fixture.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../scripts/program-lib.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

# Fixture: two owners share "cortex"; "automation" is unique to rossoctl.
cat > "$TEST_TMPDIR/repos.json" <<'JSON'
[
  {"owner": "rossoctl", "name": "automation"},
  {"owner": "rossoctl", "name": "cortex"},
  {"owner": "alice",    "name": "cortex"}
]
JSON
FIX="$TEST_TMPDIR/repos.json"

# --- one enrolled owner -> that one owner/name ---
got=$(REPOMAN_REPOS_FILE="$FIX" repoman_match_name "automation")
[ "$got" = "rossoctl/automation" ] \
  || { echo "FAIL one-owner: got [$got] want [rossoctl/automation]"; fail=1; }

# --- two enrolled owners -> both, one per line, in file order ---
got=$(REPOMAN_REPOS_FILE="$FIX" repoman_match_name "cortex")
want=$'rossoctl/cortex\nalice/cortex'
[ "$got" = "$want" ] \
  || { echo "FAIL two-owner: got [$got] want [$want]"; fail=1; }

# --- no enrolled owner -> no output, return 0 ---
got=$(REPOMAN_REPOS_FILE="$FIX" repoman_match_name "nonesuch") \
  || { echo "FAIL no-match: should return 0 on zero matches"; fail=1; }
[ -z "$got" ] || { echo "FAIL no-match: expected empty, got [$got]"; fail=1; }

# --- substring must NOT match (whole-name only) ---
got=$(REPOMAN_REPOS_FILE="$FIX" repoman_match_name "cort")
[ -z "$got" ] || { echo "FAIL substring: 'cort' must not match 'cortex', got [$got]"; fail=1; }

# --- owner-looking token must NOT match a name ---
got=$(REPOMAN_REPOS_FILE="$FIX" repoman_match_name "rossoctl")
[ -z "$got" ] || { echo "FAIL owner-token: 'rossoctl' is an owner, not a name, got [$got]"; fail=1; }

# --- empty repos.json -> fail loud (propagated from repoman_get_repos) ---
echo '[]' > "$TEST_TMPDIR/empty.json"
if REPOMAN_REPOS_FILE="$TEST_TMPDIR/empty.json" repoman_match_name "cortex" >/dev/null 2>&1; then
  echo "FAIL empty: should propagate repoman_get_repos failure"; fail=1
fi

# --- missing repos.json -> fail loud ---
if REPOMAN_REPOS_FILE="$TEST_TMPDIR/nope.json" repoman_match_name "cortex" >/dev/null 2>&1; then
  echo "FAIL missing: should propagate repoman_get_repos failure"; fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS: repoman_match_name (one/two/zero owners, whole-name match, fail-loud)" || exit 1
