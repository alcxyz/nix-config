"""Check the restart guard's live-work count and the restart notice hook against fixture state."""

import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time

idle_check, restart_notice = sys.argv[1:]
cases = 0

V2_SCHEMA = """
CREATE TABLE orchestration_v2_projection_runs (
  run_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
  provider TEXT NOT NULL, provider_thread_id TEXT, status TEXT NOT NULL,
  requested_at TEXT NOT NULL, completed_at TEXT, payload_json TEXT NOT NULL);
CREATE TABLE orchestration_v2_projection_provider_threads (
  provider_thread_id TEXT PRIMARY KEY, thread_id TEXT, owner_node_id TEXT,
  provider TEXT NOT NULL, provider_session_id TEXT, status TEXT NOT NULL,
  first_run_ordinal INTEGER, last_run_ordinal INTEGER, updated_at TEXT NOT NULL,
  payload_json TEXT NOT NULL);
CREATE TABLE projection_thread_sessions (
  thread_id TEXT PRIMARY KEY, status TEXT NOT NULL, updated_at TEXT NOT NULL);
"""
LEGACY_SCHEMA = """
CREATE TABLE projection_thread_sessions (
  thread_id TEXT PRIMARY KEY, status TEXT NOT NULL, updated_at TEXT NOT NULL);
"""


def database(root, name, schema, runs=(), threads=(), sessions=()):
    path = root / name
    connection = sqlite3.connect(path)
    connection.executescript(schema)
    for index, (status, payload) in enumerate(runs):
        connection.execute(
            "INSERT INTO orchestration_v2_projection_runs VALUES (?, ?, ?, 'claudeAgent', NULL, ?, 'now', NULL, ?)",
            (f"run:{index}", f"thread:{index}", index, status, json.dumps(payload)),
        )
    for index, (status, payload) in enumerate(threads):
        connection.execute(
            "INSERT INTO orchestration_v2_projection_provider_threads VALUES (?, ?, NULL, 'claudeAgent', NULL, ?, NULL, NULL, 'now', ?)",
            (f"provider-thread:{index}", f"thread:{index}", status, json.dumps(payload)),
        )
    for index, status in enumerate(sessions):
        connection.execute(
            "INSERT INTO projection_thread_sessions VALUES (?, ?, 'now')", (f"thread:{index}", status)
        )
    connection.commit()
    connection.close()
    return path


def guard(path, expected, label, settle="0", during=None):
    """path is one database file or one state directory holding statev2.sqlite and/or state.sqlite."""
    global cases
    cases += 1
    env = {**os.environ, "T3CODE_STATE_DATABASE": str(path), "T3CODE_SETTLE_SECONDS": settle}
    with subprocess.Popen([idle_check], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
        if during is not None:
            time.sleep(1)
            during()
        stdout, stderr = process.communicate()
    assert process.returncode == expected, (label, process.returncode, stdout, stderr)


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    guard(database(root, "idle.sqlite", V2_SCHEMA,
                   runs=[("completed", {}), ("cancelled", {}), ("queued", {"queueHeld": 1})],
                   threads=[("idle", {"pendingBackgroundTasks": []}), ("not_loaded", {})],
                   # The copied legacy table is stale in a V2 database and must not count.
                   sessions=["running"]),
          0, "v2 idle")
    guard(database(root, "running.sqlite", V2_SCHEMA, runs=[("running", {})]), 75, "v2 running turn")
    guard(database(root, "waiting.sqlite", V2_SCHEMA, runs=[("waiting", {})]), 75, "v2 waiting turn")
    guard(database(root, "queued.sqlite", V2_SCHEMA, runs=[("queued", {})]), 75, "v2 queued turn")
    guard(database(root, "background.sqlite", V2_SCHEMA,
                   runs=[("completed", {})],
                   threads=[("idle", {"pendingBackgroundTasks": [{"taskId": "b1", "kind": "command"}]})]),
          75, "v2 background work between turns")
    guard(database(root, "active.sqlite", V2_SCHEMA, threads=[("active", {})]), 75, "v2 active provider thread")
    guard(database(root, "legacy-idle.sqlite", LEGACY_SCHEMA, sessions=["ready", "stopped"]), 0, "legacy idle")
    guard(database(root, "legacy-running.sqlite", LEGACY_SCHEMA, sessions=["running"]), 75, "legacy running")
    guard(root / "missing.sqlite", 0, "missing database")
    broken = root / "broken.sqlite"
    broken.write_text("not a database\n")
    guard(broken, 75, "unreadable database")

    # State directories: the most recently written database is the live one
    # (#575). Mtimes are set explicitly; `live` names the newer file.
    def state_dir(name, v2=None, legacy=None, live="statev2.sqlite"):
        directory = root / name
        directory.mkdir()
        if v2 is not None:
            database(directory, "statev2.sqlite", V2_SCHEMA, **v2)
        if legacy is not None:
            database(directory, "state.sqlite", LEGACY_SCHEMA, **legacy)
        for file in directory.iterdir():
            os.utime(file, (1_000_000, 2_000_000 if file.name == live else 1_000_000))
        return directory

    guard(state_dir("dir-empty"), 0, "directory without databases")
    guard(state_dir("dir-v2-busy-legacy-idle", v2={"runs": [("running", {})]}, legacy={"sessions": ["ready"]}),
          75, "running turn in statev2 beside an idle frozen state.sqlite")
    guard(state_dir("dir-v2-idle-legacy-idle", v2={"runs": [("completed", {})]}, legacy={"sessions": ["ready", "stopped"]}),
          0, "both databases idle")
    guard(state_dir("dir-legacy-only-busy", legacy={"sessions": ["running"]}), 75, "pre-V2 build with a running turn")
    guard(state_dir("dir-legacy-busy-v2-idle", v2={"runs": [("completed", {})]}, legacy={"sessions": ["running"]}, live="state.sqlite"),
          75, "rolled-back build writing state.sqlite beside an idle statev2.sqlite")
    guard(state_dir("dir-stale-legacy", v2={"runs": [("completed", {})]}, legacy={"sessions": ["running"]}),
          0, "stale running row in the frozen state.sqlite is ignored while statev2.sqlite is live")
    guard(state_dir("dir-stale-v2", v2={"runs": [("running", {})]}, legacy={"sessions": ["ready"]}, live="state.sqlite"),
          0, "stale running row in statev2.sqlite is ignored after a rollback")
    wal = state_dir("dir-wal", v2={"runs": [("running", {})]}, legacy={"sessions": ["ready"]}, live="state.sqlite")
    (wal / "statev2.sqlite-wal").write_bytes(b"wal frame")
    os.utime(wal / "statev2.sqlite-wal", (3_000_000, 3_000_000))
    guard(wal, 75, "a newer non-empty WAL marks statev2.sqlite as live")
    # A read-only open creates an empty WAL with a fresh mtime; it is not a write.
    reader = state_dir("dir-reader-wal", v2={"runs": [("running", {})]}, legacy={"sessions": ["ready"]})
    os.utime(reader / "statev2.sqlite", ns=(time.time_ns() - 7200 * 10**9, time.time_ns() - 7200 * 10**9))
    os.utime(reader / "state.sqlite", ns=(time.time_ns() - 86400 * 10**9, time.time_ns() - 86400 * 10**9))
    (reader / "state.sqlite-wal").write_text("")
    guard(reader, 75, "an empty WAL created by a reader does not make the frozen file live")
    tie = state_dir("dir-tie", v2={"runs": [("completed", {})]}, legacy={"sessions": ["running"]})
    for file in tie.iterdir():
        os.utime(file, ns=(1_000_000_000_000_000, 1_000_000_000_000_000))
    guard(tie, 75, "an exact tie counts both databases")
    sub = state_dir("dir-subsecond", v2={"runs": [("completed", {})]}, legacy={"sessions": ["running"]})
    os.utime(sub / "statev2.sqlite", ns=(1_000_000_000_000_000, 1_000_000_000_000_000))
    os.utime(sub / "state.sqlite", ns=(1_000_000_000_000_000, 1_000_000_000_500_000))
    guard(sub, 75, "a legacy database written later within the same second is live")
    # Both databases written within the last hour of each other count, so
    # a stale file touched during a transition cannot hide live work.
    recent = state_dir("dir-recent-both", v2={"runs": [("completed", {})]}, legacy={"sessions": ["running"]})
    os.utime(recent / "statev2.sqlite", None)
    os.utime(recent / "state.sqlite", ns=(time.time_ns() - 600 * 10**9, time.time_ns() - 600 * 10**9))
    guard(recent, 75, "a frozen state.sqlite written ten minutes before the live statev2.sqlite still counts")
    # The live database is chosen on every sample, so one created during
    # the settle window, after an idle first sample, is seen.
    late = state_dir("dir-late", legacy={"sessions": ["ready"]})
    guard(late, 75, "statev2.sqlite created during the settle window", settle="2",
          during=lambda: database(late, "statev2.sqlite", V2_SCHEMA, runs=[("running", {})]))
    unreadable = state_dir("dir-v2-unreadable", legacy={"sessions": ["ready"]})
    (unreadable / "statev2.sqlite").write_text("not a database\n")
    guard(unreadable, 75, "unreadable statev2.sqlite beside an idle state.sqlite")

    # Restart notice: restarts after the session's first entry are reported once per session.
    now = datetime.now(timezone.utc)
    transcript = root / "transcript.jsonl"
    log = root / "restarts.log"
    cgroup = root / "cgroup"
    notified = root / "notified"
    counter = [0]

    def notice(entries, restarts, source="resume", unit="t3code.service",
               restarted="t3code.service t3code-bn.service", session=None):
        global cases
        cases += 1
        counter[0] += 1
        session = session or f"session-{counter[0]}"
        # Transcripts also hold metadata records without timestamps.
        transcript.write_text(
            json.dumps({"type": "file-history-snapshot", "messageId": "m1"}) + "\n"
            + "".join(json.dumps({"type": "assistant", "timestamp": stamp}) + "\n" for stamp in entries)
        )
        log.write_text("".join(f"{stamp}\tt3code-ai-stack-switch\t{restarted}\tT3 a -> b\n" for stamp in restarts))
        cgroup.write_text(f"0::/user.slice/user-1000.slice/user@1000.service/app.slice/{unit}\n")
        payload = json.dumps({"source": source, "transcript_path": str(transcript), "session_id": session})
        env = {**os.environ, "T3CODE_RESTART_LOG": str(log), "T3CODE_CGROUP_FILE": str(cgroup),
               "T3CODE_NOTICE_STATE": str(notified)}
        result = subprocess.run([restart_notice], env=env, input=payload, capture_output=True, text=True)
        assert result.returncode == 0, (result.returncode, result.stderr)
        return result.stdout

    def iso(delta):
        return (now - delta).isoformat()

    after = notice([iso(timedelta(hours=2))], [iso(timedelta(hours=1))], session="s-after")
    assert "t3code.service, the server behind this session, restarted" in after, after
    assert "restarted by t3code-ai-stack-switch (T3 a -> b)" in after, after
    # Reported once; a later restart is reported on the next resume.
    assert notice([iso(timedelta(hours=2))], [iso(timedelta(hours=1))], session="s-after") == ""
    again = notice([iso(timedelta(hours=2))], [iso(timedelta(hours=1)), iso(timedelta(minutes=10))], session="s-after")
    assert again.count("restarted by") == 1 and iso(timedelta(minutes=10)) in again, again
    bn = notice([iso(timedelta(hours=2))], [iso(timedelta(hours=1))], unit="t3code-bn.service")
    assert "t3code-bn.service, the server behind this session" in bn, bn
    # Sessions outside a T3 unit, or under a unit that did not restart, get nothing.
    assert notice([iso(timedelta(hours=2))], [iso(timedelta(hours=1))], unit="tmux.service") == ""
    assert notice([iso(timedelta(hours=2))], [iso(timedelta(hours=1))], unit="t3code-bn.service", restarted="t3code.service") == ""
    # A session that started after the restart was not interrupted by it.
    assert notice([iso(timedelta(hours=1))], [iso(timedelta(hours=2))]) == ""
    # A turn cut off mid-stream wrote entries up to the kill; the record,
    # written after the restart, is still reported. So is a very young session.
    cut = notice([iso(timedelta(hours=2)), iso(timedelta(minutes=59, seconds=59))], [iso(timedelta(hours=1))])
    assert "restarted" in cut, cut
    young = notice([iso(timedelta(seconds=14))], [iso(timedelta(seconds=3))])
    assert "restarted" in young, young
    assert notice([iso(timedelta(hours=2))], [iso(timedelta(hours=1))], source="clear") == ""
    assert notice([iso(timedelta(days=10))], [iso(timedelta(days=9))]) == ""
print(f"T3 restart guard: {cases} cases passed")
