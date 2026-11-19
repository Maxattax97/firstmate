#!/usr/bin/env bash
# Explicitly reconcile a reviewed local-only ship head into its readiness latch.
# The caller supplies the full commit ID after reviewing the work; no status
# line or harness lifecycle claim is treated as completion proof.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  echo "Usage: fm-local-readiness.sh <task-id> <full-commit-id>" >&2
  echo "Operator attests the exact reviewed HEAD; this records readiness, not merge approval." >&2
}

if [ "$#" -ne 2 ] || ! fm_pr_task_id_valid "$1"; then
  usage
  exit 2
fi

ID=$1
REQUESTED_HEAD=$2
case "$REQUESTED_HEAD" in
  *[!0-9a-f]*|'') echo "error: expected a full lowercase commit ID" >&2; exit 2 ;;
esac
case ${#REQUESTED_HEAD} in
  40|64) ;;
  *) echo "error: expected a full lowercase commit ID" >&2; exit 2 ;;
esac

fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: readiness reconciliation refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || {
  echo "error: task metadata missing or unsafe for $ID" >&2
  exit 1
}

CONTROL_LOCK="$STATE/.control-$ID.lock"
META_LOCK=$(fm_meta_lock_path "$META") || {
  echo "error: cannot resolve task metadata lock" >&2
  exit 1
}
LOCKED_CONTROL=
LOCKED_META=
SCAN_DIR=
release_locks() {
  [ -z "$LOCKED_META" ] || fm_lock_release "$LOCKED_META" || true
  [ -z "$LOCKED_CONTROL" ] || fm_lock_release "$LOCKED_CONTROL" || true
  if [ -n "$SCAN_DIR" ]; then
    rm -f -- "$SCAN_DIR/results" "$SCAN_DIR/errors"
    rmdir -- "$SCAN_DIR" 2>/dev/null || true
  fi
}
trap release_locks EXIT
fm_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: task lifecycle is active; refusing readiness reconciliation" >&2
  exit 1
}
LOCKED_CONTROL=$CONTROL_LOCK
fm_lock_try_acquire "$META_LOCK" || {
  echo "error: task metadata is active; refusing readiness reconciliation" >&2
  exit 1
}
LOCKED_META=$META_LOCK

fm_backlog_meta_spawn_gen_optional "$META" "$STATE" || {
  echo "error: readiness reconciliation refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
EXPECTED_GEN=$FM_BACKLOG_META_SPAWN_GEN

field_count() {
  awk -F= -v key="$2" '$1 == key { n++ } END { print n+0 }' "$1"
}
for field in kind mode branch worktree project spawn_gen; do
  [ "$(field_count "$META" "$field")" = 1 ] || {
    echo "error: task metadata has missing or duplicate $field" >&2
    exit 1
  }
done

KIND=$(fm_dod_meta_value "$META" kind)
MODE=$(fm_dod_meta_value "$META" mode)
BRANCH=$(fm_dod_meta_value "$META" branch)
WT=$(fm_dod_meta_value "$META" worktree)
PROJECT=$(fm_dod_meta_value "$META" project)
[ "$KIND" = ship ] && [ "$MODE" = local-only ] || {
  echo "error: readiness reconciliation only accepts local-only ship tasks" >&2
  exit 1
}
BACKEND=$(fm_backend_of_meta "$META")
TARGET=$(fm_backend_target_of_meta "$META")
[ -n "$TARGET" ] || {
  echo "error: task has no verifiable worker endpoint" >&2
  exit 1
}
case "$(fm_backend_agent_state "$BACKEND" "$TARGET")" in
  dead|missing) ;;
  *) echo "error: worker endpoint is not proven stopped; refusing readiness reconciliation" >&2; exit 1 ;;
esac
[ -d "$WT" ] && [ ! -L "$WT" ] || {
  echo "error: recorded worker worktree is missing or unsafe" >&2
  exit 1
}
[ -d "$PROJECT" ] && [ ! -L "$PROJECT" ] || {
  echo "error: recorded project checkout is missing or unsafe" >&2
  exit 1
}

actual_wt=$(cd "$WT" && pwd -P)
actual_project=$(cd "$PROJECT" && pwd -P)
[ "$actual_wt" = "$WT" ] && [ "$actual_project" = "$PROJECT" ] || {
  echo "error: recorded worktree and project paths must be canonical" >&2
  exit 1
}
[ "$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "$BRANCH" ] || {
  echo "error: worker worktree is not on the recorded task branch" >&2
  exit 1
}
[ -z "$(git -C "$WT" status --porcelain --untracked-files=all)" ] || {
  echo "error: worker worktree is not clean" >&2
  exit 1
}
verify_worker_head() {
  local actual ref
  actual=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  ref=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  [ "$actual" = "$REQUESTED_HEAD" ] && [ "$ref" = "$BRANCH" ]
}
verify_worker_head || {
  echo "error: supplied commit does not match worker branch HEAD" >&2
  exit 1
}
command -v lsof >/dev/null 2>&1 || {
  echo "error: lsof is required to check for processes using the worker worktree" >&2
  exit 1
}
SCAN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-local-readiness.XXXXXX") || {
  echo "error: cannot create a private directory for the worktree process scan" >&2
  exit 1
}
if LC_ALL=C lsof -V -t +D "$WT" > "$SCAN_DIR/results" 2> "$SCAN_DIR/errors"; then
  LSOF_STATUS=0
else
  LSOF_STATUS=$?
fi
SCAN_EMPTY=0
SCAN_PIDS=0
SCAN_INVALID=0
while IFS= read -r scan_line; do
  case "$scan_line" in
    *[!0-9]*|'')
      case "$scan_line" in
        'lsof: no file use located: '*)
          scan_path=${scan_line#lsof: no file use located: }
          case "$scan_path" in
            "$WT"|"$WT"/*) SCAN_EMPTY=$((SCAN_EMPTY + 1)) ;;
            *) SCAN_INVALID=1 ;;
          esac
          ;;
        *) SCAN_INVALID=1 ;;
      esac
      ;;
    *) SCAN_PIDS=$((SCAN_PIDS + 1)) ;;
  esac
done < "$SCAN_DIR/results"
if [ -s "$SCAN_DIR/errors" ] || [ "$LSOF_STATUS" -gt 1 ] \
  || [ "$SCAN_INVALID" -ne 0 ] \
  || { [ "$SCAN_EMPTY" -eq 0 ] && [ "$SCAN_PIDS" -eq 0 ]; }; then
  echo "error: lsof process scan failed or was incomplete" >&2
  exit 1
fi
if [ "$SCAN_PIDS" -gt 0 ]; then
  echo "error: a process still has files open in the worker worktree" >&2
  exit 1
fi

fm_dod_named_head_reachable_outside_worktree "$WT" "$PROJECT" local-only "$REQUESTED_HEAD" || {
  echo "error: supplied commit is not reachable outside the worker worktree" >&2
  exit 1
}
verify_worker_head || {
  echo "error: worker branch moved during readiness reconciliation" >&2
  exit 1
}
[ -z "$(git -C "$WT" status --porcelain --untracked-files=all)" ] || {
  echo "error: worker worktree changed during readiness reconciliation" >&2
  exit 1
}

CAPTURED_META=$(cat "$META")
[ "$(fm_dod_meta_value "$META" spawn_gen)" = "$EXPECTED_GEN" ] || {
  echo "error: task incarnation changed during readiness reconciliation" >&2
  exit 1
}
fm_dod_pin_local_done_head "$STATE" "$ID" "$META" "$REQUESTED_HEAD" "$CAPTURED_META" meta-locked || {
  echo "error: readiness could not be published safely; task metadata changed or already has a different head" >&2
  exit 1
}

echo "ready: $ID $REQUESTED_HEAD"
