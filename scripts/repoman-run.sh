#!/usr/bin/env bash
# repoman run <program> [target...] — the RepoMan run-path orchestrator.
#
# Pure glue: resolves a program to its step profile, (optionally) narrows to a
# named enrolled subset, runs the capability gate + clone refresh as the profile
# requires, execs the program, and writes its _index.json entry. Non-interactive
# (output routing must be set beforehand via repoman-setup.sh set-output).
#
# Spec: docs/specs/2026-10-18-repoman-run-path-design.md
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/program-lib.sh
. "$SCRIPT_DIR/program-lib.sh"

usage() {
  cat <<'EOF'
Usage: repoman-run.sh <program> [target...] [--dry-run] [--help]

Run a RepoMan program against the enrolled repos (or a named subset).
<program> is one of: link-health dep-bump pr-review weekly-report automation-health
[target...] are owner/name slugs or bare names ALREADY reconciled by the skill.
Non-interactive: output routing must be set beforehand (repoman-setup.sh set-output).
EOF
}

# Per-program step table. One row per program. Fields (tab-separated):
#   program  profile  needs_clone_refresh  posts_output  writes_index  scanner_script  display_name  report_path
# Must stay consistent with KNOWN_PROGRAMS in repoman-setup.sh (unify = #76).
_PROGRAM_TABLE="\
link-health	scanner	yes	yes	yes	link-health-scanner.sh	Link Health	$HOME/reports/link-health
dep-bump	scanner	yes	yes	yes	dep-bump-scanner.sh	Dependency Bumps	$HOME/reports/dep-bump
pr-review	scanner	no	no	no	pr-review-scanner.sh	PR Review
weekly-report	scanner	no	no	no	weekly-report.sh	Weekly Report
automation-health	index-consumer	no	no	no	automation-health-dashboard.sh	Automation Health	"

# _program_row <program> -> echoes the tab-separated row, or returns 1 if unknown.
# NOTE: the `while` runs in a subshell (right side of a pipe), so a `return`
# inside it cannot set this function's status; the trailing `grep .` detects
# whether any row matched and sets the exit status. bash 3.2-safe.
_program_row() {
  local want="$1"
  printf '%s\n' "$_PROGRAM_TABLE" | awk -F'\t' -v w="$want" '$1==w {print; exit}' | grep .
}

# _known_programs -> space-separated list of known program ids.
_known_programs() {
  printf '%s\n' "$_PROGRAM_TABLE" | awk -F'\t' 'NF {printf "%s ", $1}'
}

# _row_field <row> <n> -> the n-th tab-separated field (1-indexed).
_row_field() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '{print $n}'; }

# _resolve_targets <target...> -> newline-delimited owner/name set, or non-zero
# on an unknown/unenrolled target. Trusts the skill's reconciliation; only
# VALIDATES enrollment (defensive). Bare name -> repoman_match_name. With no
# targets, emits nothing (caller treats as the whole enrolled set).
_resolve_targets() {
  [ "$#" -gt 0 ] || return 0
  local t resolved
  for t in "$@"; do
    case "$t" in
      */*)
        if is_enrolled "$t"; then
          printf '%s\n' "$t"
        else
          echo "ERROR: target '$t' is not enrolled" >&2; return 1
        fi ;;
      *)
        if ! resolved=$(repoman_match_name "$t"); then
          echo "ERROR: failed resolving target '$t'" >&2; return 1
        fi
        if [ -z "$resolved" ]; then
          echo "ERROR: target '$t' matches no enrolled repo" >&2; return 1
        fi
        printf '%s\n' "$resolved" ;;
    esac
  done
}

# Run-scoped temp dir for subset projection; cleaned on any exit (success,
# error, or signal). Only a hard kill -9 leaks, and $TMPDIR is OS-reclaimed.
RUN_TMPDIR=""
_cleanup_run_tmp() { [ -n "$RUN_TMPDIR" ] && rm -rf "$RUN_TMPDIR"; }
trap _cleanup_run_tmp EXIT

# _project_subset <newline-delimited owner/name> -> path to a throwaway
# repos.json holding exactly that subset. Lives in $TMPDIR (NOT under
# ~/.repoman/); written directly as a projection, which is allowed because it
# is outside the guarded dir (HARD INVARIANT guards only ~/.repoman/ state).
_project_subset() {
  local set_in="$1"
  if ! RUN_TMPDIR=$(mktemp -d); then
    echo "ERROR: mktemp -d failed; cannot project repo subset" >&2; return 1
  fi
  local out="$RUN_TMPDIR/repos.json"
  if ! printf '%s\n' "$set_in" \
      | jq -R 'select(length>0) | {owner: (split("/")[0]), name: (split("/")[1])}' \
      | jq -s '.' > "$out"; then
    echo "ERROR: failed writing subset repos file" >&2; return 1
  fi
  printf '%s\n' "$out"
}

# _bin <name> -> path to a sibling script, overridable by REPOMAN_RUN_BIN (tests
# inject stubs there).
_bin() { echo "${REPOMAN_RUN_BIN:-$SCRIPT_DIR}/$1"; }

main() {
  local program="" dry_run=false
  local -a targets=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --help|-h) usage; return 0 ;;
      --dry-run) dry_run=true; shift ;;
      -*) echo "ERROR: unknown flag: $1" >&2; usage >&2; return 2 ;;
      *) if [ -z "$program" ]; then program="$1"; else targets+=("$1"); fi; shift ;;
    esac
  done
  [ -n "$program" ] || { echo "ERROR: no program given" >&2; usage >&2; return 2; }

  local row
  if ! row=$(_program_row "$program"); then
    echo "ERROR: unknown program '$program'. Known programs: $(_known_programs)" >&2
    return 2
  fi

  local profile; profile=$(_row_field "$row" 2)

  local scanner_script; scanner_script=$(_row_field "$row" 6)

  # Validate / resolve any named targets against the enrolled set (defensive;
  # the skill has already reconciled them). Empty -> whole enrolled set.
  local resolved_set
  if ! resolved_set=$(_resolve_targets "${targets[@]+"${targets[@]}"}"); then
    return 1
  fi

  # Narrow to a subset via a throwaway repos file when targets were named.
  # index-consumer programs scan nothing, so they never project a subset.
  if [ "$profile" != "index-consumer" ] && [ -n "$resolved_set" ]; then
    local subset_file
    if ! subset_file=$(_project_subset "$resolved_set"); then
      return 1
    fi
    export REPOMAN_REPOS_FILE="$subset_file"
  fi

  # (gate + clone refresh wired in Task 5; index write in Task 6.)

  if "$dry_run"; then
    echo "[dry-run] would run $program (profile=$profile)"
    [ -n "$resolved_set" ] && printf 'targets:\n%s\n' "$resolved_set"
    return 0
  fi

  # Exec the program.
  if ! "$(_bin "$scanner_script")"; then
    echo "ERROR: $program exec failed" >&2; return 1
  fi
  return 0
}

main "$@"
