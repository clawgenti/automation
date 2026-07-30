#!/usr/bin/env bash
set -euo pipefail

# Verifies load_org_profile() in program-lib.sh:
#   - resolves each fact by precedence: flag > env > profile > default
#   - PROFILE_-prefixed profile files cannot clobber env-provided values
#   - fails loud on missing profile and unresolvable ORG
# Hermetic: points the loader at fixture profiles via $ORG_PROFILE + a
# temp config dir is not needed because the loader resolves the profile
# path relative to program-lib.sh; instead we drive it with PROFILE_* env
# by sourcing fixture files directly is avoided — we use $ORG_PROFILE against
# fixtures placed next to the real config.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../scripts/program-lib.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

# Fixture profile with PROFILE_-prefixed keys.
cat > "$TEST_TMPDIR/org.fix.env" <<'EOF'
PROFILE_ORG=profileorg
PROFILE_FORK_OWNER=profilefork
PROFILE_MAIN_REPO=profileorg/mainrepo
PROFILE_REPOS_DIR=/tmp/profiledir
PROFILE_REMAP="oldname:newname"
EOF

# Helper: run the loader in a clean subshell with a given environment,
# then echo the four resolved facts. $PROFILE_PATH points directly at a file.
run_loader() {
  # args are VAR=VAL assignments applied before the call
  (
    for kv in "$@"; do export "$kv"; done
    # Point loader at the fixture by absolute path override.
    ORG_PROFILE_FILE="$TEST_TMPDIR/org.fix.env"
    load_org_profile >/dev/null 2>&1 || { echo "LOADER_FAILED"; exit 0; }
    echo "$ORG|$FORK_OWNER|$MAIN_REPO|$REPOS_DIR|$REMAP"
  )
}

# --- profile tier: with nothing else set, profile values win ---
got=$(run_loader)
want='profileorg|profilefork|profileorg/mainrepo|/tmp/profiledir|oldname:newname'
[ "$got" = "$want" ] || { echo "FAIL profile tier: got [$got]"; fail=1; }

# --- env beats profile (the clobber-safety guarantee) ---
got=$(run_loader "ORG=envorg")
case "$got" in
  envorg\|*) ;;
  *) echo "FAIL env>profile for ORG: got [$got]"; fail=1 ;;
esac

# --- flag beats env beats profile ---
got=$(run_loader "ORG=envorg" "ORG_FLAG=flagorg")
case "$got" in
  flagorg\|*) ;;
  *) echo "FAIL flag>env for ORG: got [$got]"; fail=1 ;;
esac

# --- MAIN_REPO defaults to $ORG/$ORG when profile omits it ---
cat > "$TEST_TMPDIR/org.nomain.env" <<'EOF'
PROFILE_ORG=solo
EOF
got=$(
  ORG_PROFILE_FILE="$TEST_TMPDIR/org.nomain.env"
  load_org_profile >/dev/null 2>&1
  echo "$MAIN_REPO|$REPOS_DIR|$FORK_OWNER"
)
[ "$got" = "solo/solo|$HOME/solo|clawgenti" ] \
  || { echo "FAIL defaults: got [$got]"; fail=1; }

# --- fail loud: missing profile file ---
if ( ORG_PROFILE_FILE="$TEST_TMPDIR/nope.env"; load_org_profile ) >/dev/null 2>&1; then
  echo "FAIL should error on missing profile"; fail=1
fi

# --- fail loud: profile present but ORG unresolvable ---
cat > "$TEST_TMPDIR/org.noorg.env" <<'EOF'
PROFILE_FORK_OWNER=x
EOF
if ( ORG_PROFILE_FILE="$TEST_TMPDIR/org.noorg.env"; load_org_profile ) >/dev/null 2>&1; then
  echo "FAIL should error when ORG cannot be resolved"; fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS: load_org_profile (precedence, clobber-safety, defaults, fail-loud)" || exit 1
