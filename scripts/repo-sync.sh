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

# Scratch file for capturing a per-repo git command's stderr, so its one-line
# error can be attached to that repo's summary entry (fail-loud: check mktemp's rc).
giterr=$(mktemp) || { echo "ERROR: mktemp failed" >&2; exit 1; }
trap 'rm -f "$giterr"' EXIT

while IFS= read -r full; do
  [ -n "$full" ] || continue
  owner="${full%%/*}"; name="${full#*/}"
  dir="$REPOS_DIR/$owner/$name"
  if [ -d "$dir/.git" ]; then
    if git -C "$dir" pull --ff-only 2>"$giterr"; then
      pulled=$((pulled + 1))
    else
      msg=$(head -n1 "$giterr")
      failed=$((failed + 1)); failures="$failures  $full (pull): $msg"$'\n'
    fi
  else
    if ! mkdir -p "$REPOS_DIR/$owner"; then
      failed=$((failed + 1)); failures="$failures  $full (mkdir failed)"$'\n'
      continue
    fi
    if git clone "https://github.com/$owner/$name.git" "$dir" 2>"$giterr"; then
      cloned=$((cloned + 1))
    else
      msg=$(head -n1 "$giterr")
      failed=$((failed + 1)); failures="$failures  $full (clone): $msg"$'\n'
    fi
  fi
done <<< "$ENROLLED"

echo "repo-sync: pulled $pulled cloned $cloned failed $failed"
if [ "$failed" -gt 0 ]; then
  echo "failed repos:"
  printf '%s' "$failures"
fi

# --- optional skills refresh (opt-in; fatal on failure; no bootstrap-clone) ---
rc=0
if [ "$REFRESH_SKILLS" -eq 1 ]; then
  skills_dir="${REPOMAN_SKILLS_DIR:-$HOME/agent-skills}"
  if [ -d "$skills_dir/.git" ]; then
    if git -C "$skills_dir" pull --ff-only; then
      echo "repo-sync: refreshed skills clone at $skills_dir"
    else
      echo "ERROR: skills refresh failed: git pull in $skills_dir" >&2
      rc=1
    fi
  else
    echo "ERROR: --refresh-skills requested but no skills clone at $skills_dir" >&2
    echo "  (repo-sync does not bootstrap the skills clone; create it first)" >&2
    rc=1
  fi
fi
exit "$rc"
