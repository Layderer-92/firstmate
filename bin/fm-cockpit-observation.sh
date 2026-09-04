#!/usr/bin/env bash
# fm-cockpit-observation.sh - redacted machine observation for read-only Cockpit consumers.
#
# Usage:
#   fm-cockpit-observation.sh --json
#   fm-cockpit-observation.sh --project-summary <path>
#
# `--json` validates and prints this home's atomically published
# state/cockpit-observation.json without reading any other home state.
# `--project-summary` is the pure projection used by fm-home-summary-refresh.sh
# against its already-produced and validated private summary temporary file.
# Neither mode runs a backend, provider, remote, no-mistakes, or agent command.
#
# This header owns schema `fm-cockpit-observation.v1`.
# The exact document is:
#   schema: "fm-cockpit-observation.v1"
#   data_class: "internal_non_sensitive"
#   observed_at: the owning home summary's generated UTC timestamp
#   observed_epoch: the owning home summary's generated Unix epoch
#   state: unknown|captain_decision|active_child_work|externally_held|no_active_work
#   valid: boolean
#   invalidity: null|missing_backlog|unstructured_current|orphan_in_flight|
#     unowned_current|terminal_in_flight|child_current_unavailable
#   counts: non-negative integer active_children, decisions_open, holds,
#     queued, landed, and endpoints counts
# No home, host, path, task or child identifier, text, endpoint, model, harness,
# lineage, prompt, event, report, or provider field crosses this boundary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PUBLIC_OBSERVATION="$STATE/cockpit-observation.json"
MAX_BYTES=${FM_COCKPIT_OBSERVATION_MAX_BYTES:-65536}

case "$MAX_BYTES" in
  ''|*[!0-9]*|0) MAX_BYTES=65536 ;;
esac

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
}

command -v jq >/dev/null 2>&1 \
  || { echo "fm-cockpit-observation: jq not found" >&2; exit 1; }

regular_file() {  # <path>
  [ -f "$1" ] && [ ! -L "$1" ]
}

regular_bounded_file() {  # <path>
  local path=$1 bytes
  regular_file "$path" || return 1
  bytes=$(LC_ALL=C wc -c < "$path" 2>/dev/null | tr -d '[:space:]') || return 1
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le "$MAX_BYTES" ]
}

public_document_valid() {  # <path>
  jq -e '
    (keys == ["counts","data_class","invalidity","observed_at","observed_epoch","schema","state","valid"])
    and .schema == "fm-cockpit-observation.v1"
    and .data_class == "internal_non_sensitive"
    and (.observed_at | type) == "string"
    and (.observed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.observed_epoch | type) == "number"
    and .observed_epoch >= 0
    and (.observed_epoch | floor) == .observed_epoch
    and (.observed_at | fromdateiso8601) == .observed_epoch
    and (.state == "unknown" or .state == "captain_decision"
      or .state == "active_child_work" or .state == "externally_held"
      or .state == "no_active_work")
    and (.valid | type) == "boolean"
    and (.invalidity == null or .invalidity == "missing_backlog"
      or .invalidity == "unstructured_current" or .invalidity == "orphan_in_flight"
      or .invalidity == "unowned_current" or .invalidity == "terminal_in_flight"
      or .invalidity == "child_current_unavailable")
    and (.valid == (.invalidity == null))
    and (.counts | type) == "object"
    and (.counts | keys == ["active_children","decisions_open","endpoints","holds","landed","queued"])
    and all(.counts[]; type == "number" and . >= 0 and (floor == .))
  ' "$1" >/dev/null 2>&1
}

project_summary() {  # <private-summary-path>
  local source=$1 document bytes
  regular_file "$source" \
    || { echo "fm-cockpit-observation: private summary is missing or unsafe" >&2; return 1; }
  if ! jq -e '
    .schema == "fm-secondmate-home-summary.v1"
    and (.generated | type) == "string"
    and (.generated | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.generated_epoch | type) == "number"
    and .generated_epoch >= 0
    and (.generated_epoch | floor) == .generated_epoch
    and (.generated | fromdateiso8601) == .generated_epoch
    and (.valid | type) == "boolean"
    and (.state == "unknown" or .state == "captain_decision"
      or .state == "active_child_work" or .state == "externally_held"
      or .state == "no_active_work")
    and (.invalidity | type) == "object"
    and (.invalidity.kind == null or .invalidity.kind == "missing_backlog"
      or .invalidity.kind == "unstructured_current" or .invalidity.kind == "orphan_in_flight"
      or .invalidity.kind == "unowned_current" or .invalidity.kind == "terminal_in_flight"
      or .invalidity.kind == "child_current_unavailable")
    and (.valid == (.invalidity.kind == null))
    and (.counts | type) == "object"
    and all([
      .counts.active_children,
      .counts.decisions_open,
      .counts.holds,
      .counts.queued,
      .counts.landed,
      .counts.endpoints
    ][]; type == "number" and . >= 0 and (floor == .))
  ' "$source" >/dev/null 2>&1; then
    echo "fm-cockpit-observation: private summary is malformed" >&2
    return 1
  fi
  document=$(jq -c '
    {
      schema:"fm-cockpit-observation.v1",
      data_class:"internal_non_sensitive",
      observed_at:.generated,
      observed_epoch:.generated_epoch,
      state:.state,
      valid:.valid,
      invalidity:.invalidity.kind,
      counts:{
        active_children:.counts.active_children,
        decisions_open:.counts.decisions_open,
        holds:.counts.holds,
        queued:.counts.queued,
        landed:.counts.landed,
        endpoints:.counts.endpoints
      }
    }
  ' "$source") || return 1
  bytes=$(printf '%s' "$document" | LC_ALL=C wc -c | tr -d '[:space:]') || return 1
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$bytes" -gt "$MAX_BYTES" ]; then
    echo "fm-cockpit-observation: projected observation is oversized" >&2
    return 1
  fi
  printf '%s\n' "$document"
}

case "${1:-}" in
  --json)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    regular_bounded_file "$PUBLIC_OBSERVATION" \
      || { echo "fm-cockpit-observation: public observation is missing, unsafe, or oversized" >&2; exit 1; }
    public_document_valid "$PUBLIC_OBSERVATION" \
      || { echo "fm-cockpit-observation: public observation is malformed" >&2; exit 1; }
    jq -c . "$PUBLIC_OBSERVATION"
    ;;
  --project-summary)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    project_summary "$2"
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
