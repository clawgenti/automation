#!/usr/bin/env bash
# PR Review state library (RepoMan Phase 7).
#
# Converts pr-review's state between the on-disk ENVELOPE and the in-memory
# WORKING shape the scanner/fixer jq blocks operate on. Automation-only: NOT
# vendored to agent-skills, NOT part of core.sh/program-lib.sh. Source this
# AFTER program-lib.sh (it relies on core.sh's atomic_write_file).
#
# Envelope v1 (on disk):
#   {schema_version:1, program, acted_on:{"<repo>:<number>":{at,ttl_days,head_sha}},
#    program_data:{in_progress:[...]}}
# Working shape (in memory):
#   {reviewed:[{repo,number,head_sha,reviewed_at}], in_progress:[{repo,number,head_sha,started_at}]}

# Empty working shape (same literal the scripts used pre-envelope).
PRREVIEW_WORKING_DEFAULT='{"in_progress": [], "reviewed": []}'

PRREVIEW_TTL_DAYS=30
PRREVIEW_SCHEMA_VERSION=1

# prreview_state_load <state_file>
# Prints the WORKING shape JSON to stdout. Handles: envelope v1, legacy
# {in_progress,reviewed}, missing file, invalid JSON.
prreview_state_load() {
  local file="$1"

  # Missing or unreadable -> empty working shape.
  if [ ! -f "$file" ]; then
    printf '%s\n' "$PRREVIEW_WORKING_DEFAULT"
    return 0
  fi

  # Invalid JSON -> empty working shape (mirrors validate_json_schema's
  # reset-on-invalid behavior, but non-destructive: we do not rewrite the file).
  if ! jq empty "$file" 2>/dev/null; then
    echo "WARN: $file is not valid JSON, using empty state." >&2
    printf '%s\n' "$PRREVIEW_WORKING_DEFAULT"
    return 0
  fi

  # Envelope v1 (has schema_version) -> unwrap to working shape.
  # Legacy (no schema_version) with array reviewed/in_progress -> pass through.
  # Anything else -> empty working shape.
  jq -c '
    if (.schema_version // null) != null then
      {
        reviewed: ([ (.acted_on // {}) | to_entries[]
          | { repo: (.value.repo // (.key | split(":")[0])),
              number: (.value.number // (.key | split(":")[1] | tonumber)),
              head_sha: .value.head_sha,
              reviewed_at: .value.at } ]),
        in_progress: ((.program_data.in_progress) // [])
      }
    elif ((.reviewed | type) == "array" and (.in_progress | type) == "array") then
      { reviewed: .reviewed, in_progress: .in_progress }
    else
      {reviewed: [], in_progress: []}
    end
  ' "$file" 2>/dev/null || printf '%s\n' "$PRREVIEW_WORKING_DEFAULT"
}

# prreview_state_write <working_json_file> <dest_file> <program_id>
# Wraps the working shape into envelope v1 and atomically writes it to dest.
prreview_state_write() {
  local src="$1" dst="$2" program="$3"
  local tmp="${dst}.env.$$"

  jq -c \
    --argjson sv "$PRREVIEW_SCHEMA_VERSION" \
    --arg program "$program" \
    --argjson ttl "$PRREVIEW_TTL_DAYS" '
    {
      schema_version: $sv,
      program: $program,
      acted_on: ( reduce (.reviewed[]?) as $r ({};
        . + { ("\($r.repo):\($r.number)"): {
                repo: $r.repo, number: $r.number,
                head_sha: $r.head_sha, at: $r.reviewed_at, ttl_days: $ttl } } ) ),
      program_data: { in_progress: (.in_progress // []) }
    }
  ' "$src" > "$tmp"

  atomic_write_file "$tmp" "$dst"
  rm -f "$tmp"
}
