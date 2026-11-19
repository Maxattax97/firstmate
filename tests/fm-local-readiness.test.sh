#!/usr/bin/env bash
# Public-interface tests for explicit local-only readiness reconciliation.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-local-readiness)
fm_git_identity fmtest fmtest@example.invalid

make_case() {
  local name=$1
  CASE="$TMP_ROOT/$name"
  PROJ="$CASE/project"
  WT="$CASE/worker"
  HOME_DIR="$CASE/home"
  META="$HOME_DIR/state/local-task.meta"
  FAKEBIN="$CASE/bin"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$FAKEBIN"
  fm_git_worktree "$PROJ" "$WT" fm/local-task
  git -C "$WT" commit -q --allow-empty -m reviewed
  HEAD=$(git -C "$WT" rev-parse HEAD)
  printf 'kind=ship\nmode=local-only\nbranch=fm/local-task\nproject=%s\nworktree=%s\nspawn_gen=fixture-1\nwindow=fm-session:fm-local-task\n' \
    "$PROJ" "$WT" > "$META"
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
echo "can't find session: fm-session" >&2
exit 1
SH
  chmod +x "$FAKEBIN/tmux"
}

run_ready() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-local-readiness.sh" local-task "$1"
}

test_reviewed_head_is_pinned() {
  local out
  make_case valid
  out=$(run_ready "$HEAD") || fail "valid reviewed head refused: $out"
  [ "$out" = "ready: local-task $HEAD" ] || fail "unexpected success output: $out"
  [ "$(sed -n 's/^local_done_head=//p' "$META")" = "$HEAD" ] || fail "reviewed head not pinned"
  pass 'reviewed reachable head pins after endpoint and worktree checks'
}

test_status_is_not_required_or_used() {
  make_case no-status
  out=$(run_ready "$HEAD") || fail "explicit evidence unexpectedly required a status claim: $out"
  [ "$(sed -n 's/^local_done_head=//p' "$META")" = "$HEAD" ] || fail 'head not pinned without status'
  pass 'reconciliation does not consume worker status lines'
}

test_wrong_or_abbreviated_head_refuses() {
  local out rc
  make_case wrong-head
  rc=0
  out=$(run_ready "${HEAD:0:12}" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'abbreviated head was accepted'
  rc=0
  out=$(run_ready "$(printf '%040d' 0)" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'head not matching worker branch was accepted'
  [ -z "$(sed -n 's/^local_done_head=//p' "$META")" ] || fail 'invalid head was pinned'
  pass 'abbreviated and mismatched heads refuse'
}

test_dirty_worktree_refuses() {
  local out rc
  make_case dirty
  printf 'unreviewed\n' > "$WT/untracked"
  rc=0
  out=$(run_ready "$HEAD" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'dirty worktree was accepted'
  [ -z "$(sed -n 's/^local_done_head=//p' "$META")" ] || fail 'dirty head was pinned'
  pass 'dirty worktree refuses'
}

test_missing_worktree_refuses() {
  local out rc
  make_case missing-worktree
  mv "$WT" "$WT.gone"
  rc=0
  out=$(run_ready "$HEAD" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'missing worktree was accepted'
  case "$out" in *'worktree is missing or unsafe'*) ;; *) fail "unexpected missing-worktree refusal: $out" ;; esac
  pass 'missing worker worktree refuses'
}

test_unreachable_worker_head_refuses() {
  local out rc copied
  make_case unreachable
  copied="$CASE/worker-copy"
  git clone -q --no-hardlinks --branch fm/local-task "$PROJ" "$copied"
  git -C "$copied" commit -q --allow-empty -m only-in-worker-copy
  WT=$copied
  HEAD=$(git -C "$WT" rev-parse HEAD)
  sed "s|^worktree=.*|worktree=$WT|" "$META" > "$META.next"
  mv "$META.next" "$META"
  rc=0
  out=$(run_ready "$HEAD" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'worker-only commit was accepted'
  case "$out" in *'not reachable outside the worker worktree'*) ;; *) fail "unexpected unreachable-head refusal: $out" ;; esac
  [ -z "$(sed -n 's/^local_done_head=//p' "$META")" ] || fail 'unreachable head was pinned'
  pass 'commit present only in worker clone refuses'
}

test_live_endpoint_refuses() {
  local out rc
  make_case live
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
printf 'fm-local-task\n'
SH
  chmod +x "$FAKEBIN/tmux"
  rc=0
  out=$(run_ready "$HEAD" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'present worker endpoint was accepted'
  case "$out" in *'worker endpoint is not proven stopped'*) ;; *) fail "unexpected live-endpoint refusal: $out" ;; esac
  pass 'present worker endpoint refuses even with a clean reviewed head'
}

test_open_worktree_process_refuses() {
  local out rc pid
  make_case open-process
  printf 'held open\n' > "$WT/open-file"
  git -C "$WT" add open-file
  git -C "$WT" commit -q -m 'track process fixture'
  HEAD=$(git -C "$WT" rev-parse HEAD)
  tail -f "$WT/open-file" >/dev/null 2>&1 &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' RETURN
  rc=0
  out=$(run_ready "$HEAD" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'process holding a worktree file open was accepted'
  case "$out" in *'process still has files open'*) ;; *) fail "unexpected open-process refusal: $out" ;; esac
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  trap - RETURN
  pass 'process with an open worktree file refuses'
}

test_branch_move_during_reconciliation_refuses() {
  local out rc moved tree
  make_case moved-branch
  tree=$(git -C "$WT" rev-parse 'HEAD^{tree}')
  moved=$(git -C "$WT" commit-tree "$tree" -p "$HEAD" -m moved)
  cat > "$FAKEBIN/lsof" <<'SH'
#!/usr/bin/env bash
"$REAL_GIT" -C "$RACE_WT" update-ref refs/heads/fm/local-task "$RACE_HEAD"
  exec "$REAL_LSOF" "$@"
SH
  chmod +x "$FAKEBIN/lsof"
  rc=0
  out=$(REAL_GIT="$(command -v git)" REAL_LSOF="$(command -v lsof)" RACE_WT="$WT" RACE_HEAD="$moved" run_ready "$HEAD" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'branch moved during reconciliation was accepted'
  case "$out" in *'worker branch moved during readiness reconciliation'*) ;; *) fail "unexpected branch-race refusal: $out" ;; esac
  [ -z "$(sed -n 's/^local_done_head=//p' "$META")" ] || fail 'raced branch head was pinned'
  pass 'branch movement during worktree inspection refuses'
}

test_generation_change_during_reconciliation_refuses() {
  local out rc
  make_case changed-during-check
  cat > "$FAKEBIN/lsof" <<'SH'
#!/usr/bin/env bash
"$REAL_SED" 's/^spawn_gen=.*/spawn_gen=fixture-2/' "$RACE_META" > "$RACE_META.next"
mv "$RACE_META.next" "$RACE_META"
exec "$REAL_LSOF" "$@"
SH
  chmod +x "$FAKEBIN/lsof"
  rc=0
  out=$(REAL_SED="$(command -v sed)" REAL_LSOF="$(command -v lsof)" RACE_META="$META" run_ready "$HEAD" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'changed task generation was accepted'
  case "$out" in *'task incarnation changed'*) ;; *) fail "unexpected generation-change refusal: $out" ;; esac
  [ -z "$(sed -n 's/^local_done_head=//p' "$META")" ] || fail 'head was pinned for changed generation'
  pass 'task generation change during inspection refuses'
}

test_incarnation_change_refuses() {
  local out rc
  make_case changed-generation
  # A pinned head from another task incarnation is never overwritten.
  printf 'local_done_head=%s\n' "$(printf '%040d' 0)" >> "$META"
  rc=0
  out=$(run_ready "$HEAD" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'existing conflicting pin was accepted'
  pass 'conflicting preexisting readiness refuses'
}

fm_test_run \
  test_reviewed_head_is_pinned \
  test_status_is_not_required_or_used \
  test_wrong_or_abbreviated_head_refuses \
  test_dirty_worktree_refuses \
  test_missing_worktree_refuses \
  test_unreachable_worker_head_refuses \
  test_live_endpoint_refuses \
  test_open_worktree_process_refuses \
  test_branch_move_during_reconciliation_refuses \
  test_generation_change_during_reconciliation_refuses \
  test_incarnation_change_refuses
