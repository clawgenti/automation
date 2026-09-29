#!/usr/bin/env bash
# repo-sync: keep the enrolled repo clones current. Reads the enrolled set from
# ~/.repoman/repos.json, clones-if-missing / pulls-if-present each repo under
# $REPOS_DIR/<owner>/<name>/. Read-only toward GitHub. Per-repo failures are
# logged and non-fatal; every other failure is surfaced to the caller.
set -uo pipefail

# --- Load shared library ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/program-lib.sh"

usage() {
  cat <<'EOF'
Usage: repo-sync.sh [--refresh-skills] [--help]

Sync enrolled repo clones (from ~/.repoman/repos.json) under
<repos_dir>/<owner>/<name>/. Clones if missing, pulls (--ff-only) if present.
Read-only toward GitHub. A per-repo clone/pull failure is logged and does not
abort the run.

  --refresh-skills   Also pull a local agent-skills clone (see REPOMAN_SKILLS_DIR).
  --help             Show this help and exit 0.
EOF
}

REFRESH_SKILLS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --refresh-skills) REFRESH_SKILLS=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Fail-loud inputs (rc surfaced): config sets REPOS_DIR/FORK_OWNER; enrolled set.
repoman_config || exit 1
ENROLLED=$(repoman_get_repos) || exit 1

pulled=0; cloned=0; failed=0
failures=""

while IFS= read -r full; do
  [ -n "$full" ] || continue
  owner="${full%%/*}"; name="${full#*/}"
  dir="$REPOS_DIR/$owner/$name"
  if [ -d "$dir/.git" ]; then
    if git -C "$dir" pull --ff-only; then
      pulled=$((pulled + 1))
    else
      failed=$((failed + 1)); failures="$failures  $full (pull failed)"$'\n'
    fi
  else
    mkdir -p "$REPOS_DIR/$owner"
    if git clone "https://github.com/$owner/$name.git" "$dir"; then
      cloned=$((cloned + 1))
    else
      failed=$((failed + 1)); failures="$failures  $full (clone failed)"$'\n'
    fi
  fi
done <<< "$ENROLLED"

echo "repo-sync: pulled $pulled cloned $cloned failed $failed"
if [ "$failed" -gt 0 ]; then
  echo "failed repos (git error printed above per repo):"
  printf '%s' "$failures"
fi
exit 0
