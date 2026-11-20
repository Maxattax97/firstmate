#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP=$(mktemp -d)
FAKEBIN="$TMP/bin"
HOME_DIR="$TMP/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state"
chmod 700 "$HOME_DIR/state"
export ROOT TMP HOME_DIR AVIARY_CALL_COUNT="$TMP/calls" AVIARY_WATCH_LOG="$TMP/watch.log"
export PATH="$FAKEBIN:$PATH"
export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT"
source_id=
runner_pid=
cleanup() {
  if [ -n "$source_id" ] && [ -n "$runner_pid" ] && kill -0 "$runner_pid" 2>/dev/null; then
    "$ROOT/bin/fm-procevent.sh" retire "$source_id" >/dev/null 2>&1 || kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
  fi
  rm -rf -- "$TMP"
}
trap cleanup EXIT

cat >"$FAKEBIN/aviary" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
import time

if sys.argv[1] == "watch":
    for event in (
        {"connected": True, "revision": 1},
        {"connected": False, "revision": 1},
        {"connected": True, "revision": 2},
    ):
        print(json.dumps(event), flush=True)
    time.sleep(10)
    raise SystemExit(0)

operation = json.load(sys.stdin)
if operation["op"] == "service_info":
    print(json.dumps({"service": "aviary", "protocol": 2, "database": "/tmp/aviary-test.sqlite", "pid": 12345}))
    raise SystemExit(0)

if operation["op"] == "submit":
    with open(os.environ["AVIARY_SUBMIT_COUNT"], "a", encoding="utf-8") as stream:
        stream.write(operation["request"]["identity"] + "\n")
    submissions = {}
    try:
        with open(os.environ["AVIARY_SUBMISSIONS"], encoding="utf-8") as stream:
            submissions = json.load(stream)
    except FileNotFoundError:
        pass
    identity = operation["request"]["identity"]
    submissions.setdefault(identity, 73)
    with open(os.environ["AVIARY_SUBMISSIONS"], "w", encoding="utf-8") as stream:
        json.dump(submissions, stream)
    try:
        os.unlink(os.environ["AVIARY_LOSE_SUBMIT_REPLY"])
    except FileNotFoundError:
        pass
    else:
        raise SystemExit(8)
    print(json.dumps({"id": submissions[identity]}))
    raise SystemExit(0)

count = 0
try:
    with open(os.environ["AVIARY_CALL_COUNT"], encoding="utf-8") as stream:
        count = int(stream.read())
except FileNotFoundError:
    pass

if operation["op"] == "inbox_page":
    count += 1
    with open(os.environ["AVIARY_CALL_COUNT"], "w", encoding="utf-8") as stream:
        stream.write(str(count))
    if count == 1:
        result = {"messages": [], "next_offset": None}
    else:
        result = {
            "messages": [
                {
                    "id": 41,
                    "message": {
                        "sender": "operator",
                        "body": "Please resume the review." + "x" * 3000,
                        "target": {"kind": "direct", "participant": "firstmate"},
                    },
                }
            ],
            "next_offset": None,
        }
elif operation["op"] == "decision_status":
    if count < 2:
        result = {"id": operation["id"], "answer": None, "deferred_event": None}
    elif operation["after"] < 9:
        result = {"id": operation["id"], "answer": {"type": "custom", "value": "Proceed"}, "deferred_event": 9}
    else:
        result = {"id": operation["id"], "answer": {"type": "custom", "value": "Proceed"}, "deferred_event": None}
else:
    raise SystemExit(2)
print(json.dumps(result))
PY
chmod 700 "$FAKEBIN/aviary"

address=127.0.0.1:7432
participant=firstmate
adapter="$ROOT/bin/fm-procevent-aviary.sh"
"$adapter" arm --address "$address" --participant "$participant" >"$TMP/arm.out"
source_id=$("$adapter" source-id "$address" "$participant")
"$adapter" track-decision --address "$address" --participant "$participant" --id 12 >/dev/null
"$ROOT/bin/fm-procevent.sh" start "$source_id" >"$TMP/start.out" 2>&1 &
runner_pid=$!
result=

for _ in $(seq 1 200); do
  if [ -d "$HOME_DIR/state/procevent-inbox" ]; then
    result=$(find "$HOME_DIR/state/procevent-inbox" -maxdepth 1 -name "$source_id.*.result" -print -quit)
  fi
  [ -n "$result" ] && break
  sleep 0.05
done
if [ -z "$result" ]; then
  cat "$TMP/start.out" >&2
  exit 1
fi
result_name=${result##*/}
sequence=${result_name#"$source_id."}
sequence=${sequence%.result}
cp "$result" "$TMP/result.json"
marker="$HOME_DIR/state/procevent-inbox/$source_id.$sequence.handled"
for _ in $(seq 1 200); do
  [ -f "$marker" ] && break
  sleep 0.05
done
if [ ! -f "$marker" ]; then
  cat "$TMP/start.out" >&2
  exit 1
fi

jq -e '.messages[0].id == 41 and .messages[0].message.body_truncated == true and (.messages[0].message.body | length) == 2000' "$TMP/result.json" >/dev/null
jq -e '.decisions[0].id == 12 and .decisions[0].deferred_events == [9] and .decisions[0].answer.value == "Proceed"' "$TMP/result.json" >/dev/null
[ "$("$adapter" classify "$TMP/result.json")" = delta ]
"$adapter" message --address "$address" --participant "$participant" --id 41 >"$TMP/message.json"
jq -e '.body | startswith("Please resume the review.") and length > 2000' "$TMP/message.json" >/dev/null

db=$(find "$HOME_DIR/state/aviary" -maxdepth 1 -name '*.sqlite' -print -quit)
[ -n "$db" ]
python3 - "$db" <<'PY'
import sqlite3
import sys
db = sqlite3.connect(sys.argv[1])
assert db.execute("SELECT id FROM messages").fetchall() == [(41,)]
cursor, answer = db.execute("SELECT deferred_after, answer FROM decisions WHERE id = 12").fetchone()
assert cursor == 9
assert len(answer) == 64
PY

request_file="$TMP/request.json"
cat >"$request_file" <<'JSON'
{"identity":"fm-aviary-test-decision-identity","agent":"firstmate","question":"Proceed with the bounded test?","options":["No","Yes"],"recommendation":1,"reason":"Verify durable submission and ID tracking."}
JSON
touch "$TMP/lose-submit-reply"
export AVIARY_SUBMIT_COUNT="$TMP/submitted-identities" \
  AVIARY_SUBMISSIONS="$TMP/submissions.json" \
  AVIARY_LOSE_SUBMIT_REPLY="$TMP/lose-submit-reply"
if "$adapter" submit-decision --address "$address" --participant "$participant" \
  --identity fm-aviary-test-decision-identity --request-file "$request_file" >"$TMP/lost-submit.out" 2>&1; then
  printf 'Aviary submission did not simulate its unknown outcome\n' >&2
  exit 1
fi
python3 - "$db" <<'PY'
import sqlite3
import sys
db = sqlite3.connect(sys.argv[1])
assert db.execute(
    "SELECT decision_id FROM decision_submissions WHERE identity = ?",
    ("fm-aviary-test-decision-identity",),
).fetchone() == (None,)
PY
[ "$("$adapter" retry-submissions --address "$address" --participant "$participant")" = 'submitted: 73' ]
[ "$("$adapter" submit-decision --address "$address" --participant "$participant" \
  --identity fm-aviary-test-decision-identity --request-file "$request_file")" = 'submitted: 73' ]
cat >"$TMP/conflict.json" <<'JSON'
{"identity":"fm-aviary-test-decision-identity","agent":"firstmate","question":"Different request under same identity?","options":["No","Yes"],"recommendation":1,"reason":"Must be rejected locally."}
JSON
if "$adapter" submit-decision --address "$address" --participant "$participant" \
  --identity fm-aviary-test-decision-identity --request-file "$TMP/conflict.json" >/dev/null 2>&1; then
  printf 'Aviary submission identity accepted conflicting request content\n' >&2
  exit 1
fi
python3 - "$db" "$AVIARY_SUBMIT_COUNT" "$AVIARY_SUBMISSIONS" <<'PY'
import json
import sqlite3
import sys
db = sqlite3.connect(sys.argv[1])
assert db.execute("SELECT id FROM decisions ORDER BY id").fetchall() == [(12,), (73,)]
assert db.execute(
    "SELECT decision_id FROM decision_submissions WHERE identity = ?",
    ("fm-aviary-test-decision-identity",),
).fetchone() == (73,)
assert open(sys.argv[2], encoding="utf-8").read().splitlines() == [
    "fm-aviary-test-decision-identity",
    "fm-aviary-test-decision-identity",
]
assert json.load(open(sys.argv[3], encoding="utf-8")) == {
    "fm-aviary-test-decision-identity": 73
}
PY

"$ROOT/bin/fm-procevent.sh" retire "$source_id" >/dev/null
wait "$runner_pid" || true
runner_pid=

"$adapter" autohandle "$source_id" "$sequence" "$TMP/result.json" >/dev/null
"$adapter" autohandle "$source_id" "$sequence" "$TMP/result.json" >/dev/null
[ -f "$HOME_DIR/state/procevent-inbox/$source_id.$sequence.handled" ]
python3 - "$db" <<'PY'
import sqlite3
import sys
db = sqlite3.connect(sys.argv[1])
assert db.execute("SELECT id FROM messages").fetchall() == [(41,)]
cursor, answer = db.execute("SELECT deferred_after, answer FROM decisions WHERE id = 12").fetchone()
assert cursor == 9
assert len(answer) == 64
PY

if "$adapter" terminal "$TMP/result.json"; then
  printf 'Aviary watch was incorrectly classified as terminal\n' >&2
  exit 1
fi

printf '# fm-procevent-aviary tests passed\n'
