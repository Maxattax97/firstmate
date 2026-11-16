#!/usr/bin/env bash
# Aviary TUI message and decision wake adapter for the generic process-event runner.
#
# Usage:
#   fm-procevent-aviary.sh arm --address 127.0.0.1:7432 --participant firstmate
#   fm-procevent-aviary.sh submit-decision --address ADDRESS --participant LABEL --identity KEY --request-file REQUEST.json
#   fm-procevent-aviary.sh retry-submissions --address ADDRESS --participant LABEL
#   fm-procevent-aviary.sh track-decision --address ADDRESS --participant LABEL --id ID
#   fm-procevent-aviary.sh message --address ADDRESS --participant LABEL --id ID
#   fm-procevent-aviary.sh source-id ADDRESS PARTICIPANT
#   fm-procevent-aviary.sh classify RESULT_FILE
#   fm-procevent-aviary.sh autohandle SOURCE_ID SEQUENCE RESULT_FILE
#   fm-procevent-aviary.sh terminal RESULT_FILE
#   fm-procevent-aviary.sh relisten
#   fm-procevent-aviary.sh retire --address ADDRESS --participant LABEL
#
# Aviary submission identities and exact request content are durably staged
# before send. Retries reuse the same identity, and returned IDs become tracked
# in the same local transaction. Notifications are hints; the poller subscribes
# first, then reconciles retained inbox messages and tracked decisions.
#
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

source "$SCRIPT_DIR/fm-pr-lib.sh"
source "$SCRIPT_DIR/fm-wake-lib.sh"
source "$SCRIPT_DIR/fm-procevent-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

valid_participant() {
  local value=${1-} LC_ALL=C
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

validate_endpoint() {
  local address=${1-}
  python3 - "$address" <<'PY'
import ipaddress
import sys

address = sys.argv[1]
host, sep, port = address.rpartition(":")
if not sep or not port.isdigit() or not 1 <= int(port) <= 65535:
    raise SystemExit(1)
try:
    if not ipaddress.ip_address(host).is_loopback:
        raise SystemExit(1)
except ValueError:
    raise SystemExit(1)
PY
}

parse_identity() {
  ADDRESS=${1-}
  PARTICIPANT=${2-}
  [ -n "$ADDRESS" ] || die "Aviary address is required explicitly"
  validate_endpoint "$ADDRESS" || die "Aviary endpoint must be an explicit loopback host and port"
  valid_participant "$PARTICIPANT" || die "Aviary participant label is invalid"
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s\0%s' "$ADDRESS" "$PARTICIPANT" | shasum -a 256 | awk '{print $1}')
  else
    digest=$(printf '%s\0%s' "$ADDRESS" "$PARTICIPANT" | sha256sum | awk '{print $1}')
  fi
  [ "${#digest}" -eq 64 ] || die "cannot derive Aviary source identity"
  SOURCE_ID="aviary-${digest:0:24}"
}

state_database() {
  local state_root state_dir
  state_root=$(fm_procevent_state_root_resolve "$STATE") || die "Firstmate state directory is not a safe private directory"
  state_dir="$state_root/aviary"
  if [ -e "$state_dir" ] || [ -L "$state_dir" ]; then
    fm_procevent_private_directory_valid "$state_dir" 1 || die "Aviary state directory is unsafe"
  else
    (umask 077; mkdir "$state_dir") || die "cannot create Aviary state directory"
    chmod 700 "$state_dir" || die "cannot protect Aviary state directory"
  fi
  printf '%s/%s.sqlite\n' "$state_dir" "$SOURCE_ID"
}

call_aviary() {
  local address=$1 operation=$2 output rc=0
  output=$(printf '%s' "$operation" | aviary call "$address" - 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || die "cannot reach the configured Aviary service"
  printf '%s\n' "$output" | jq -e '.service == "aviary" and .protocol == 2 and (.database | type == "string") and (.pid | type == "number")' >/dev/null \
    || die "Aviary rejected the service identity request"
  printf '%s\n' "$output"
}

cmd_source_id() {
  [ "$#" -eq 2 ] || usage
  parse_identity "$1" "$2"
  printf '%s\n' "$SOURCE_ID"
}

cmd_arm() {
  local address='' participant='' db=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --address) [ -n "${2-}" ] || die "--address needs an endpoint"; address=$2; shift 2 ;;
      --participant) [ -n "${2-}" ] || die "--participant needs a label"; participant=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  parse_identity "$address" "$participant"
  command -v aviary >/dev/null 2>&1 || die "aviary CLI is missing"
  command -v jq >/dev/null 2>&1 || die "jq is missing"
  local identity database
  identity=$(call_aviary "$ADDRESS" '{"op":"service_info"}')
  database=$(printf '%s\n' "$identity" | jq -r '.database')
  db=$(state_database)
  python3 "$SCRIPT_DIR/fm-procevent-aviary-state.py" init "$db" "$ADDRESS" "$PARTICIPANT" "$database"
  "$SCRIPT_DIR/fm-procevent.sh" register aviary "$SOURCE_ID" -- \
    "$SCRIPT_DIR/fm-procevent-aviary.sh" poll --address "$ADDRESS" --participant "$PARTICIPANT"
  printf 'armed: %s\nparticipant: %s\naddress: %s\n' "$SOURCE_ID" "$PARTICIPANT" "$ADDRESS"
  printf 'Existing retained inbox messages will be surfaced on the first reconciliation.\n'
}

cmd_track_decision() {
  local address='' participant='' id='' db=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --address) [ -n "${2-}" ] || die "--address needs an endpoint"; address=$2; shift 2 ;;
      --participant) [ -n "${2-}" ] || die "--participant needs a label"; participant=$2; shift 2 ;;
      --id) [ -n "${2-}" ] || die "--id needs a positive decision ID"; id=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ "$id" =~ ^[1-9][0-9]*$ ]] || die "decision ID must be a positive integer"
  parse_identity "$address" "$participant"
  db=$(state_database)
  python3 "$SCRIPT_DIR/fm-procevent-aviary-state.py" track "$db" "$ADDRESS" "$PARTICIPANT" "$id"
  printf 'tracked: %s\n' "$id"
}

cmd_submit_decision() {
  local address='' participant='' identity='' request_file='' db='' decision_id=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --address) [ -n "${2-}" ] || die "--address needs an endpoint"; address=$2; shift 2 ;;
      --participant) [ -n "${2-}" ] || die "--participant needs a label"; participant=$2; shift 2 ;;
      --identity) [ -n "${2-}" ] || die "--identity needs a stable submission key"; identity=$2; shift 2 ;;
      --request-file) [ -n "${2-}" ] || die "--request-file needs a JSON file"; request_file=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$identity" ] || die "--identity is required"
  [ -n "$request_file" ] && [ -f "$request_file" ] || die "--request-file must name an existing file"
  parse_identity "$address" "$participant"
  db=$(state_database)
  python3 "$SCRIPT_DIR/fm-procevent-aviary-state.py" \
    stage-submission "$db" "$ADDRESS" "$PARTICIPANT" "$identity" "$request_file" >/dev/null
  decision_id=$(python3 "$SCRIPT_DIR/fm-procevent-aviary-state.py" \
    submit "$db" "$ADDRESS" "$PARTICIPANT" "$identity") \
    || die "Aviary submission remains durably staged; retry with the same identity and request file"
  printf 'submitted: %s\n' "$decision_id"
}

cmd_retry_submissions() {
  local address='' participant='' db=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --address) [ -n "${2-}" ] || die "--address needs an endpoint"; address=$2; shift 2 ;;
      --participant) [ -n "${2-}" ] || die "--participant needs a label"; participant=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  parse_identity "$address" "$participant"
  db=$(state_database)
  python3 "$SCRIPT_DIR/fm-procevent-aviary-state.py" \
    retry-submissions "$db" "$ADDRESS" "$PARTICIPANT"
}

cmd_message() {
  local address='' participant='' id='' db=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --address) [ -n "${2-}" ] || die "--address needs an endpoint"; address=$2; shift 2 ;;
      --participant) [ -n "${2-}" ] || die "--participant needs a label"; participant=$2; shift 2 ;;
      --id) [ -n "${2-}" ] || die "--id needs a positive message ID"; id=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ "$id" =~ ^[1-9][0-9]*$ ]] || die "message ID must be a positive integer"
  parse_identity "$address" "$participant"
  db=$(state_database)
  python3 "$SCRIPT_DIR/fm-procevent-aviary-state.py" message "$db" "$ADDRESS" "$PARTICIPANT" "$id"
}

cmd_poll() {
  local address='' participant='' db=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --address) [ -n "${2-}" ] || die "--address needs an endpoint"; address=$2; shift 2 ;;
      --participant) [ -n "${2-}" ] || die "--participant needs a label"; participant=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  parse_identity "$address" "$participant"
  db=$(state_database)
  exec python3 "$SCRIPT_DIR/fm-procevent-aviary-state.py" poll "$db" "$ADDRESS" "$PARTICIPANT"
}

cmd_classify() {
  [ "$#" -eq 1 ] || usage
  jq -er '
    if .schema == "firstmate.aviary-wake.v1" and ((.messages | type) == "array") and ((.decisions | type) == "array") then
      if has("error") then "error" else "delta" end
    else error("invalid Aviary result") end
  ' "$1"
}

cmd_autohandle() {
  [ "$#" -eq 3 ] || usage
  local id=$1 seq=$2 result=$3 address participant db
  fm_procevent_source_id_valid "$id" || die "invalid Aviary source ID"
  [[ "$seq" =~ ^[1-9][0-9]*$ ]] || die "invalid result sequence"
  jq -e '.schema == "firstmate.aviary-wake.v1"' "$result" >/dev/null || die "invalid Aviary result"
  address=$(jq -r '.binding.address // empty' "$result")
  participant=$(jq -r '.binding.participant // empty' "$result")
  [ -n "$address" ] && [ -n "$participant" ] || die "Aviary result has no source binding"
  parse_identity "$address" "$participant"
  [ "$SOURCE_ID" = "$id" ] || die "Aviary result belongs to a different source"
  db=$(state_database)
  python3 "$SCRIPT_DIR/fm-procevent-aviary-state.py" apply "$db" "$ADDRESS" "$PARTICIPANT" "$result"
  "$SCRIPT_DIR/fm-procevent.sh" handled "$id" "$seq"
}

cmd_retire() {
  local address='' participant=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --address) [ -n "${2-}" ] || die "--address needs an endpoint"; address=$2; shift 2 ;;
      --participant) [ -n "${2-}" ] || die "--participant needs a label"; participant=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  parse_identity "$address" "$participant"
  "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID"
}

case "${1-}" in
  arm) shift; cmd_arm "$@" ;;
  submit-decision) shift; cmd_submit_decision "$@" ;;
  retry-submissions) shift; cmd_retry_submissions "$@" ;;
  track-decision) shift; cmd_track_decision "$@" ;;
  message) shift; cmd_message "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  poll) shift; cmd_poll "$@" ;;
  classify) shift; cmd_classify "$@" ;;
  autohandle) shift; cmd_autohandle "$@" ;;
  terminal) [ "$#" -eq 2 ] || usage; exit 1 ;;
  relisten) [ "$#" -eq 1 ] || usage; exit 0 ;;
  retire) shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
