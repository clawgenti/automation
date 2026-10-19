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

  # Remaining pipeline (resolve/project/gate/sync/exec/index) wired in later tasks.
  "$dry_run" && echo "[dry-run] would run $program (profile=$profile) with ${#targets[@]} target(s)"
  return 0
}

main "$@"
