#!/usr/bin/env bash
set -euo pipefail

# Verifies the repo-selection helpers in program-lib.sh:
#   get_core_repos        -- reads the allowlist, strips comments/blanks, fails loud
#   core_repo_names       -- strips the owner prefix
#   canonical_repo_for_dir-- maps clone-dir basenames to canonical repo names
#
# Uses $CORE_REPOS_FILE to point the reader at fixtures rather than the real
# config/core-repos.txt, so the test is hermetic.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../scripts/program-lib.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

fail=0

# --- Fixture: a well-formed allowlist with comments, blanks, and trailing ws ---
cat > "$TEST_TMPDIR/good.txt" <<'EOF'
# a comment
rossoctl/rossoctl

rossoctl/cortex
  rossoctl/agent-skills
EOF

# --- get_core_repos: parses to exactly the three entries, in order ---
got=$(CORE_REPOS_FILE="$TEST_TMPDIR/good.txt" get_core_repos)
want=$'rossoctl/rossoctl\nrossoctl/cortex\nrossoctl/agent-skills'
[ "$got" = "$want" ] || { echo "FAIL get_core_repos parse: got [$got]"; fail=1; }

# --- get_core_repos: comments and blank lines are excluded ---
count=$(CORE_REPOS_FILE="$TEST_TMPDIR/good.txt" get_core_repos | grep -c .)
[ "$count" = "3" ] || { echo "FAIL get_core_repos count: got $count want 3"; fail=1; }

# --- core_repo_names: owner prefix stripped ---
names=$(CORE_REPOS_FILE="$TEST_TMPDIR/good.txt" core_repo_names)
want_names=$'rossoctl\ncortex\nagent-skills'
[ "$names" = "$want_names" ] || { echo "FAIL core_repo_names: got [$names]"; fail=1; }

# --- get_core_repos: FAIL LOUD when the file is missing ---
if CORE_REPOS_FILE="$TEST_TMPDIR/does-not-exist.txt" get_core_repos >/dev/null 2>&1; then
  echo "FAIL get_core_repos should error on missing file"; fail=1
fi

# --- get_core_repos: FAIL LOUD when the file has no real entries ---
printf '# only a comment\n\n' > "$TEST_TMPDIR/empty.txt"
if CORE_REPOS_FILE="$TEST_TMPDIR/empty.txt" get_core_repos >/dev/null 2>&1; then
  echo "FAIL get_core_repos should error on empty allowlist"; fail=1
fi

# --- is_core_repo: membership test against the allowlist (exact, whole-line) ---
CORE_REPOS_FILE="$TEST_TMPDIR/good.txt" is_core_repo "rossoctl" \
  || { echo "FAIL is_core_repo: rossoctl should be in allowlist"; fail=1; }
if CORE_REPOS_FILE="$TEST_TMPDIR/good.txt" is_core_repo "not-a-repo"; then
  echo "FAIL is_core_repo: not-a-repo should NOT match"; fail=1
fi
# Guard against substring false positives (rosso is a prefix of rossoctl).
if CORE_REPOS_FILE="$TEST_TMPDIR/good.txt" is_core_repo "rosso"; then
  echo "FAIL is_core_repo: partial 'rosso' must not match 'rossoctl'"; fail=1
fi

# --- canonical_repo_for_dir: remaps the two renamed dirs, identity otherwise ---
[ "$(canonical_repo_for_dir kagenti)" = "rossoctl" ] \
  || { echo "FAIL canonical: kagenti -> rossoctl"; fail=1; }
[ "$(canonical_repo_for_dir kagenti-extensions)" = "cortex" ] \
  || { echo "FAIL canonical: kagenti-extensions -> cortex"; fail=1; }
[ "$(canonical_repo_for_dir automation)" = "automation" ] \
  || { echo "FAIL canonical: automation identity"; fail=1; }
[ "$(canonical_repo_for_dir operator)" = "operator" ] \
  || { echo "FAIL canonical: operator identity"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: core-repos helpers (parse, names, fail-loud, canonical remap)" || exit 1
