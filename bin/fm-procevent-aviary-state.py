#!/usr/bin/env python3
"""Private durable state and polling support for fm-procevent-aviary.sh."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import selectors
import sqlite3
import subprocess
import sys
from pathlib import Path
from typing import Any


SCHEMA = "firstmate.aviary-wake.v1"
MAX_BATCH = 25
MAX_PREVIEW = 2000


class ServiceIdentityError(RuntimeError):
    pass


def validate_decision_request(request: Any, participant: str, identity: str) -> dict[str, Any]:
    allowed = {
        "identity",
        "agent",
        "question",
        "explanation",
        "context",
        "activity",
        "options",
        "importance",
        "recommendation",
        "reason",
    }
    if not isinstance(request, dict) or set(request) - allowed:
        raise RuntimeError("Aviary decision request has an unsupported shape")
    if request.get("identity") != identity or not identity:
        raise RuntimeError("Aviary request identity must match --identity")
    if request.get("agent") != participant:
        raise RuntimeError("Aviary decision request agent must match the configured participant")
    if not isinstance(request.get("question"), str) or not request["question"]:
        raise RuntimeError("Aviary decision question must be non-empty text")
    options = request.get("options")
    if not isinstance(options, list) or any(not isinstance(option, str) or not option for option in options):
        raise RuntimeError("Aviary decision options must be an array of non-empty strings")
    importance = request.get("importance", 0)
    if type(importance) is not int or not 0 <= importance <= 5:
        raise RuntimeError("Aviary decision importance must be an integer from 0 to 5")
    recommendation = request.get("recommendation")
    reason = request.get("reason")
    if recommendation is not None:
        if type(recommendation) is not int or not 0 <= recommendation < len(options):
            raise RuntimeError("Aviary recommendation must select an existing option")
        if not isinstance(reason, str) or not reason:
            raise RuntimeError("Aviary recommendation requires a non-empty reason")
    elif reason is not None:
        raise RuntimeError("Aviary reason requires a recommendation")
    for field in ("explanation", "context"):
        if field in request and request[field] is not None and not isinstance(request[field], str):
            raise RuntimeError(f"Aviary decision {field} must be text or null")
    if "activity" in request and request["activity"] is not None:
        if not isinstance(request["activity"], str) or not request["activity"]:
            raise RuntimeError("Aviary decision activity must be non-empty text or null")
    return request


def connect(db_path: str) -> sqlite3.Connection:
    path = Path(db_path)
    if path.is_symlink():
        raise RuntimeError("Aviary state database must not be a symlink")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    old_umask = os.umask(0o077)
    try:
        db = sqlite3.connect(path, timeout=10)
    finally:
        os.umask(old_umask)
    os.chmod(path, 0o600)
    db.execute("PRAGMA synchronous=FULL")
    db.execute("PRAGMA journal_mode=DELETE")
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS decisions (
            id INTEGER PRIMARY KEY,
            deferred_after INTEGER NOT NULL DEFAULT 0,
            answer TEXT
        );
        CREATE TABLE IF NOT EXISTS decision_submissions (
            identity TEXT PRIMARY KEY,
            request_json TEXT NOT NULL,
            decision_id INTEGER
        );
        """
    )
    schema = db.execute("SELECT value FROM metadata WHERE key = 'schema'").fetchone()
    if schema is None:
        db.execute("INSERT INTO metadata(key, value) VALUES ('schema', '1')")
    elif schema[0] != "1":
        raise RuntimeError("Aviary state database schema is unsupported")
    return db


def call(address: str, operation: dict[str, Any]) -> dict[str, Any]:
    request = json.dumps(operation, ensure_ascii=False, separators=(",", ":"))
    result = subprocess.run(
        ["aviary", "call", address, "-"],
        input=request,
        text=True,
        capture_output=True,
        timeout=15,
        check=False,
    )
    if result.returncode:
        raise RuntimeError("Aviary request failed")
    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("Aviary returned invalid JSON") from exc
    if not isinstance(response, dict) or "error" in response:
        raise RuntimeError("Aviary rejected the request")
    return response


def service_identity(db: sqlite3.Connection, address: str) -> None:
    identity = call(address, {"op": "service_info"})
    if identity.get("service") != "aviary" or identity.get("protocol") != 2:
        raise ServiceIdentityError("aviary-protocol-changed")
    database = identity.get("database")
    expected = db.execute("SELECT value FROM metadata WHERE key = 'service-database'").fetchone()
    if not isinstance(database, str) or expected is None or database != expected[0]:
        raise ServiceIdentityError("aviary-database-changed")


def stage_submission(
    db: sqlite3.Connection,
    address: str,
    participant: str,
    identity: str,
    request_path: str,
) -> int | None:
    service_identity(db, address)
    with open(request_path, "r", encoding="utf-8") as stream:
        request = validate_decision_request(json.load(stream), participant, identity)
    request_json = json.dumps(
        request, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False
    )
    row = db.execute(
        "SELECT request_json, decision_id FROM decision_submissions WHERE identity = ?",
        (identity,),
    ).fetchone()
    if row is not None:
        if row[0] != request_json:
            raise RuntimeError("Aviary submission identity is already bound to different request content")
        return row[1]
    db.execute(
        "INSERT INTO decision_submissions(identity, request_json) VALUES (?, ?)",
        (identity, request_json),
    )
    return None


def submit_one(db: sqlite3.Connection, address: str, identity: str) -> int:
    service_identity(db, address)
    row = db.execute(
        "SELECT request_json, decision_id FROM decision_submissions WHERE identity = ?",
        (identity,),
    ).fetchone()
    if row is None:
        raise RuntimeError("Aviary decision submission is not staged")
    request_json, existing_id = row
    if existing_id is not None:
        return existing_id

    response = call(address, {"op": "submit", "request": json.loads(request_json)})
    decision_id = response.get("id")
    if type(decision_id) is not int or decision_id <= 0:
        raise RuntimeError("Aviary returned an invalid decision ID")
    status = call(address, {"op": "decision_status", "id": decision_id, "after": 0})
    if status.get("id") != decision_id:
        raise RuntimeError("Aviary decision status did not match the submitted ID")

    with db:
        current = db.execute(
            "SELECT request_json, decision_id FROM decision_submissions WHERE identity = ?",
            (identity,),
        ).fetchone()
        if current is None or current[0] != request_json:
            raise RuntimeError("Aviary decision submission changed while in flight")
        if current[1] is not None and current[1] != decision_id:
            raise RuntimeError("Aviary submission identity resolved to conflicting decision IDs")
        db.execute("INSERT OR IGNORE INTO decisions(id) VALUES (?)", (decision_id,))
        db.execute(
            "UPDATE decision_submissions SET decision_id = ? WHERE identity = ?",
            (decision_id, identity),
        )
    return decision_id


def retry_submissions(db: sqlite3.Connection, address: str) -> list[tuple[str, int]]:
    pending = db.execute(
        "SELECT identity FROM decision_submissions WHERE decision_id IS NULL ORDER BY identity"
    ).fetchall()
    return [(identity, submit_one(db, address, identity)) for (identity,) in pending]


def pages(address: str, participant: str):
    offset = 0
    seen_offsets: set[int] = set()
    while True:
        if offset in seen_offsets:
            raise RuntimeError("Aviary inbox pagination did not advance")
        seen_offsets.add(offset)
        page = call(address, {"op": "inbox_page", "participant": participant, "offset": offset})
        batch = page.get("messages")
        if not isinstance(batch, list):
            raise RuntimeError("Aviary inbox response is malformed")
        for item in batch:
            if not isinstance(item, dict) or not isinstance(item.get("id"), int):
                raise RuntimeError("Aviary inbox item is malformed")
            if not isinstance(item.get("message"), dict):
                raise RuntimeError("Aviary inbox item is malformed")
            yield item
        next_offset = page.get("next_offset")
        if next_offset is None:
            break
        if not isinstance(next_offset, int) or next_offset <= offset:
            raise RuntimeError("Aviary inbox pagination did not advance")
        offset = next_offset
def decision_updates(db: sqlite3.Connection, address: str) -> list[dict[str, Any]]:
    updates: list[dict[str, Any]] = []
    offset = 0
    while len(updates) < MAX_BATCH:
        tracked = db.execute(
            "SELECT id, deferred_after, answer FROM decisions ORDER BY id LIMIT 50 OFFSET ?",
            (offset,),
        ).fetchall()
        if not tracked:
            break
        offset += len(tracked)
        for decision_id, cursor, previous_answer in tracked:
            deferred: list[int] = []
            after = cursor
            status: dict[str, Any]
            for _ in range(MAX_BATCH):
                status = call(address, {"op": "decision_status", "id": decision_id, "after": after})
                if status.get("id") != decision_id:
                    raise RuntimeError("Aviary decision status did not match the requested ID")
                event = status.get("deferred_event")
                if event is None:
                    break
                if not isinstance(event, int) or event <= after:
                    raise RuntimeError("Aviary decision event cursor did not advance")
                deferred.append(event)
                after = event
            answer = status.get("answer")
            answer_text = None if answer is None else json.dumps(
                answer, ensure_ascii=False, sort_keys=True, separators=(",", ":")
            )
            answer_digest = None if answer_text is None else hashlib.sha256(answer_text.encode()).hexdigest()
            if deferred or (answer_digest is not None and answer_digest != previous_answer):
                preview: Any = answer
                if answer_text is not None and len(answer_text) > MAX_PREVIEW:
                    preview = {"preview": answer_text[:MAX_PREVIEW], "truncated": True}
                updates.append(
                    {
                        "id": decision_id,
                        "deferred_events": deferred,
                        "answer": preview,
                        "answer_digest": answer_digest,
                    }
                )
                if len(updates) == MAX_BATCH:
                    break
        if len(tracked) < 50:
            break
    return updates


def reconcile(db: sqlite3.Connection, address: str, participant: str) -> dict[str, Any] | None:
    new_messages: list[dict[str, Any]] = []
    for item in pages(address, participant):
        known = db.execute("SELECT 1 FROM messages WHERE id = ?", (item["id"],)).fetchone()
        if known is None:
            new_messages.append(item)
            if len(new_messages) == MAX_BATCH:
                break
    decisions = decision_updates(db, address)
    db.execute("DELETE FROM metadata WHERE key = 'last-error'")
    if not new_messages and not decisions:
        return None
    bounded_messages = []
    for item in new_messages:
        message = dict(item["message"])
        for field in ("body", "context", "activity"):
            value = message.get(field)
            if isinstance(value, str) and len(value) > MAX_PREVIEW:
                message[field] = value[:MAX_PREVIEW]
                message[f"{field}_truncated"] = True
        bounded_messages.append({"id": item["id"], "message": message})
    return {
        "schema": SCHEMA,
        "binding": {"address": address, "participant": participant},
        "messages": bounded_messages,
        "decisions": decisions,
    }


def show_message(db: sqlite3.Connection, address: str, participant: str, message_id: int) -> None:
    service_identity(db, address)
    for item in pages(address, participant):
        if item["id"] == message_id:
            print(json.dumps(item["message"], ensure_ascii=False, separators=(",", ":")))
            return
    raise RuntimeError("Aviary message ID is not present in this participant inbox")


def canonical_result(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as stream:
        result = json.load(stream)
    if not isinstance(result, dict) or result.get("schema") != SCHEMA:
        raise RuntimeError("Aviary capture has an unsupported schema")
    if not isinstance(result.get("messages"), list) or not isinstance(result.get("decisions"), list):
        raise RuntimeError("Aviary capture is malformed")
    return result


def apply(db: sqlite3.Connection, result_path: str) -> None:
    result = canonical_result(result_path)
    if "error" in result:
        if result["error"] not in {"aviary-read-failed", "aviary-protocol-changed", "aviary-database-changed"}:
            raise RuntimeError("Aviary capture contains an unknown error")
        db.execute(
            "INSERT OR REPLACE INTO metadata(key, value) VALUES ('last-error', ?)",
            (result["error"],),
        )
        return
    for item in result["messages"]:
        if not isinstance(item, dict) or not isinstance(item.get("id"), int):
            raise RuntimeError("Aviary capture contains an invalid message ID")
        db.execute("INSERT OR IGNORE INTO messages(id) VALUES (?)", (item["id"],))
    for item in result["decisions"]:
        if not isinstance(item, dict) or not isinstance(item.get("id"), int):
            raise RuntimeError("Aviary capture contains an invalid decision ID")
        row = db.execute("SELECT deferred_after, answer FROM decisions WHERE id = ?", (item["id"],)).fetchone()
        if row is None:
            raise RuntimeError("Aviary capture references an untracked decision")
        cursor, old_answer = row
        events = item.get("deferred_events")
        if not isinstance(events, list) or any(not isinstance(event, int) for event in events):
            raise RuntimeError("Aviary capture contains invalid deferral events")
        answer = item.get("answer")
        answer_digest = item.get("answer_digest")
        if answer is not None and (not isinstance(answer_digest, str) or len(answer_digest) != 64):
            raise RuntimeError("Aviary capture contains an invalid answer digest")
        answer_text = old_answer if answer is None else answer_digest
        db.execute(
            "UPDATE decisions SET deferred_after = ?, answer = ? WHERE id = ?",
            (max([cursor, *events]), answer_text, item["id"]),
        )


def watch_poll(db: sqlite3.Connection, address: str, participant: str) -> None:
    process = subprocess.Popen(
        ["aviary", "watch", address],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=0,
    )
    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    last_revision: int | None = None
    pending = b""
    try:
        while True:
            ready = selector.select()
            if not ready:
                if process.poll() is not None:
                    raise RuntimeError("Aviary watch exited")
                continue
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                if not pending:
                    raise RuntimeError("Aviary watch closed its output")
                pending += b"\n"
            else:
                pending += chunk
            while b"\n" in pending:
                raw_line, pending = pending.split(b"\n", 1)
                if not raw_line:
                    continue
                try:
                    event = json.loads(raw_line)
                except json.JSONDecodeError as exc:
                    raise RuntimeError("Aviary watch returned invalid JSON") from exc
                if not isinstance(event, dict):
                    raise RuntimeError("Aviary watch event is malformed")
                connected = event.get("connected")
                revision = event.get("revision")
                if not isinstance(connected, bool) or not isinstance(revision, int):
                    raise RuntimeError("Aviary watch event is malformed")
                if not connected or (last_revision is not None and revision == last_revision):
                    continue
                last_revision = revision
                try:
                    service_identity(db, address)
                    result = reconcile(db, address, participant)
                    # The poll remains open while callers update the same ledger.
                    db.commit()
                except ServiceIdentityError as exc:
                    error_code = str(exc)
                    previous = db.execute("SELECT value FROM metadata WHERE key = 'last-error'").fetchone()
                    if previous is None:
                        db.execute(
                            "INSERT OR REPLACE INTO metadata(key, value) VALUES ('last-error', ?)",
                            (error_code,),
                        )
                        print(
                            json.dumps(
                                {
                                    "schema": SCHEMA,
                                    "binding": {"address": address, "participant": participant},
                                    "messages": [],
                                    "decisions": [],
                                    "error": error_code,
                                },
                                separators=(",", ":"),
                            ),
                            flush=True,
                        )
                        return
                    continue
                except (RuntimeError, subprocess.SubprocessError, OSError):
                    previous = db.execute("SELECT value FROM metadata WHERE key = 'last-error'").fetchone()
                    if previous is None:
                        db.execute(
                            "INSERT OR REPLACE INTO metadata(key, value) VALUES ('last-error', 'aviary-read-failed')"
                        )
                        print(
                            json.dumps(
                                {
                                    "schema": SCHEMA,
                                    "binding": {"address": address, "participant": participant},
                                    "messages": [],
                                    "decisions": [],
                                    "error": "aviary-read-failed",
                                },
                                separators=(",", ":"),
                            ),
                            flush=True,
                        )
                        return
                    continue
                if result is not None:
                    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")), flush=True)
                    return
            if not chunk:
                raise RuntimeError("Aviary watch closed its output")
    finally:
        selector.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command",
        choices=("init", "track", "poll", "apply", "message", "stage-submission", "submit", "retry-submissions"),
    )
    parser.add_argument("database")
    parser.add_argument("address")
    parser.add_argument("participant")
    parser.add_argument("value", nargs="?")
    parser.add_argument("extra", nargs="?")
    args = parser.parse_args()
    try:
        db = connect(args.database)
        with db:
            if args.command == "init":
                if not args.value:
                    raise RuntimeError("Aviary service database identity is required")
                existing = db.execute(
                    "SELECT value FROM metadata WHERE key = 'service-database'"
                ).fetchone()
                if existing is not None and existing[0] != args.value:
                    raise RuntimeError("Configured Aviary service database identity changed")
                db.execute(
                    "INSERT OR IGNORE INTO metadata(key, value) VALUES ('service-database', ?)",
                    (args.value,),
                )
            elif args.command == "track":
                decision_id = int(args.value or "0")
                if decision_id <= 0:
                    raise RuntimeError("Decision ID must be positive")
                service_identity(db, args.address)
                status = call(
                    args.address,
                    {"op": "decision_status", "id": decision_id, "after": 0},
                )
                if status.get("id") != decision_id:
                    raise RuntimeError("Aviary decision status did not match the requested ID")
                db.execute("INSERT OR IGNORE INTO decisions(id) VALUES (?)", (decision_id,))
            elif args.command == "stage-submission":
                if not args.value or not args.extra:
                    raise RuntimeError("Aviary submission identity and request file are required")
                existing_id = stage_submission(
                    db, args.address, args.participant, args.value, args.extra
                )
                if existing_id is None:
                    print("staged")
                else:
                    print(f"already-submitted: {existing_id}")
            elif args.command == "submit":
                if not args.value:
                    raise RuntimeError("Aviary submission identity is required")
                print(submit_one(db, args.address, args.value))
            elif args.command == "retry-submissions":
                completed = retry_submissions(db, args.address)
                if completed:
                    for _, decision_id in completed:
                        print(f"submitted: {decision_id}")
                else:
                    print("no pending Aviary decision submissions")
            elif args.command == "apply":
                if not args.value:
                    raise RuntimeError("Capture result path is required")
                apply(db, args.value)
            elif args.command == "message":
                message_id = int(args.value or "0")
                if message_id <= 0:
                    raise RuntimeError("Message ID must be positive")
                show_message(db, args.address, args.participant, message_id)
            else:
                watch_poll(db, args.address, args.participant)
        db.close()
    except (OSError, sqlite3.Error, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
