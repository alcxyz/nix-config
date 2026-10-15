#!/usr/bin/env python3
"""Contract tests for t3-thread-time (ADR-0091, #676), against a fixture database."""

import importlib.util
import json
import pathlib
import sqlite3
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "modules/home-manager/programs/ai/t3-thread-time.py"
THREAD = "thread-1"
SECRET = "BODY-TEXT-MUST-NOT-LEAK"


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def check(condition, message):
    if not condition:
        fail(message)


spec = importlib.util.spec_from_file_location("t3_thread_time", SCRIPT)
tt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tt)

# Classification: edits win, heredoc bodies are not read as shell, and a
# word inside a path is not a command.
cases = {
    "rg -n foo src": "explore",
    "cat <<'EOF' > src/a.ts\nexport {}\nEOF": "coding",
    "cd ~/src/apps/app && sed -n 1,20p a.ts": "explore",
    f"cat > src/a.ts <<'EOF'\n{SECRET} deploy pr-review run 3\nEOF": "coding",
    "python3 - <<'EOF'\np.write_text(s)\nEOF\ngit commit -qam fix && pr-review run 7": "coding",
    "cat > /tmp/body.md <<'EOF'\ntext\nEOF\ntea api -X POST /repos/a/b/issues -d @/tmp/body.md": "tracking",
    "git add -A && git commit -q -F - <<'EOF'\nfix: deploy the review\nEOF": "git",
    'git commit -qm "fix: make the build pass with pytest"': "git",
    'git commit -m "docs: explain sed -i"': "git",
    'git commit -m"fix: make the build pass"': "git",
    "git commit -q -F - <<'EOF'\nstyle: format with alejandra and sed -i\nEOF": "git",
    "deploy --hm": "deploy",
    "kubectl -n dev port-forward deploy/app 8080:8080": "verify",
    "corepack pnpm test": "test",
    "corepack pnpm build": "build",
    "tea api '/repos/a/b/actions/tasks?limit=5'": "ci",
    "pr-review run 12": "review",
    "sleep 30": "waiting",
    "frobnicate --now": "other",
}
for command, want in cases.items():
    got = tt.classify_command(command)
    check(got == want, f"{command!r} classified as {got}, want {want}")
check(tt.review_targets("cd ~/src/.worktrees/apps/app/fix && pr-review run 7 --base dev") == ["app#7"],
      "review target not named from its cd")
check(tt.wake_category('Monitor "dev deploy of app 1234567" finished') == "deploy", "deploy wake")
check(tt.wake_category('Subagent "Build the server" finished') == "delegation", "subagent wake")
check(tt.label("cd ~/src/x && timeout 60 FOO=1 pnpm test\nmore") == "pnpm test", "label prefix not stripped")

check(tt.review_targets("cat > notes.md <<'EOF'\npr-review run 42\nEOF") == [], "heredoc text counted as a review")
check(tt.review_targets("pr-review run https://git.example/me/app/pulls/678 --force") == ["app#678"],
      "review by URL not counted")
check(tt.review_targets('pr-review run "https://git.example/me/app/pulls/9"') == ["app#9"], "quoted URL not counted")


def iso_at(seconds):
    return tt.iso(BASE + seconds)


BASE = tt.parse_time("2026-10-12T10:00:00Z")


def direct(runs, items, now_seconds):
    """Run analyse on in-memory rows: runs as (status, start, end or None),
    items as (run index, kind, status, start, end or None, payload). Queued
    and "withdrawn" (cancelled before starting) runs have no startedAt."""
    run_rows = [(f"r{i}", i, "cancelled" if status == "withdrawn" else status, iso_at(t0),
                 None if t1 is None else iso_at(t1),
                 json.dumps({} if status in ("queued", "withdrawn") else {"startedAt": iso_at(t0)}))
                for i, (status, t0, t1) in enumerate(runs)]
    item_rows = [(None if run is None else f"r{run}", n, kind, status,
                  json.dumps({"startedAt": iso_at(t0), "completedAt": None if t1 is None else iso_at(t1), **extra}))
                 for n, (run, kind, status, t0, t1, extra) in enumerate(items)]
    return tt.analyse("t", "T", run_rows, item_rows, 30, BASE + now_seconds)


def cat_of(out, name):
    return next(c for c in out["categories"] if c["category"] == name)


# A cancelled run without a completion time lasts until its last item, and
# the wait after it is the background work's.
out = direct([("cancelled", 0, None), ("completed", 600, 660)],
             [(0, "command_execution", "completed", 10, 20, {"input": "pnpm test", "exitCode": 0}),
              (1, "notification", "completed", 600, 600, {"summary": 'Monitor "pr-review for PR 1" finished'})], 700)
check(cat_of(out, "test")["agentSeconds"] == 20 and out["end"] is not None, f"ended run lost: {out['categories']}")
check(cat_of(out, "review")["waitSeconds"] == 580, "wait after an ended run not charged to its work")
# A waiting run is live: its open question waits until now.
out = direct([("waiting", 0, None)], [(0, "user_input_request", "waiting", 100, None, {})], 700)
check(out["userSeconds"] == 600 and out["agentSeconds"] == 100, f"open question: {out['userSeconds']} {out['agentSeconds']}")
# An unfinished tool runs until now, not into the reply.
out = direct([("running", 0, None)],
             [(0, "command_execution", "running", 10, None, {"input": "pytest", "exitCode": None})], 600)
check(cat_of(out, "test")["agentSeconds"] == 600 and cat_of(out, "discussion")["agentSeconds"] == 0,
      f"running tool time misplaced: {cat_of(out, 'test')}")
# The time a question waits for its answer is the user's, also when Claude's
# AskUserQuestion call wraps T3's question item; a long wait is idle.
out = direct([("completed", 0, 1000)],
             [(0, "dynamic_tool", "completed", 90, 910, {"toolName": "AskUserQuestion"}),
              (0, "user_input_request", "completed", 100, 900, {})], 1000)
check(out["userSeconds"] == 820 and out["agentSeconds"] == 180, f"question time: {out['userSeconds']} {out['agentSeconds']}")
out = direct([("completed", 0, 4000)], [(0, "user_input_request", "completed", 100, 3700, {})], 4000)
check(out["idleSeconds"] == 3600 and out["userSeconds"] == 0, "an overnight question wait is not idle")
# A question answered by a later message does not stop the agent.
out = direct([("running", 0, None)],
             [(0, "user_input_request", "pending", 100, None, {"responseMode": "message"}),
              (0, "command_execution", "completed", 200, 500, {"input": "pytest", "exitCode": 0})], 600)
check(cat_of(out, "test")["agentSeconds"] == 500 and out["userSeconds"] == 0, f"async question: {cat_of(out, 'test')}")
# A stale live run that is not the latest ends at its last item.
out = direct([("running", 0, None), ("completed", 600, 660)],
             [(0, "command_execution", "completed", 10, 20, {"input": "pnpm test", "exitCode": 0}),
              (1, "notification", "completed", 600, 600, {"summary": 'Monitor "pr-review for PR 1" finished'})], 86400)
check(cat_of(out, "review")["waitSeconds"] == 580 and out["agentSeconds"] == 80 and out["spanSeconds"] == 660,
      f"stale live run swallowed later runs: {out['agentSeconds']} {out['spanSeconds']}")
# An AskUserQuestion call paired with an async question stops nothing either.
out = direct([("running", 0, None)],
             [(0, "dynamic_tool", "running", 100, None, {"toolName": "AskUserQuestion"}),
              (0, "user_input_request", "pending", 100, None, {"responseMode": "message"}),
              (0, "command_execution", "completed", 200, 500, {"input": "pytest", "exitCode": 0})], 600)
check(cat_of(out, "test")["agentSeconds"] == 400 and out["userSeconds"] == 0, f"paired async question: {cat_of(out, 'test')}")
# Runs count in the order they started, not their request order.
out = direct([("completed", 0, 60), ("completed", 360, 660), ("completed", 60, 360)], [], 700)
check(out["agentSeconds"] == 660 and out["userSeconds"] == 0, f"run order: {out['agentSeconds']} {out['userSeconds']}")
# A withdrawn run that never started does not make the live run stale.
out = direct([("running", 0, None), ("withdrawn", 300, None)],
             [(0, "command_execution", "running", 10, None, {"input": "pytest", "exitCode": None})], 600)
check(cat_of(out, "test")["agentSeconds"] == 600, f"withdrawn run made the live run stale: {cat_of(out, 'test')}")
# A background call stops owning time when the agent starts its next call.
out = direct([("completed", 0, 1200)],
             [(0, "subagent", "completed", 10, 1100, {"title": "Build it"}),
              (0, "command_execution", "completed", 100, 400, {"input": "pnpm test", "exitCode": 0}),
              (0, "dynamic_tool", "completed", 500, 510, {"toolName": "Edit"})], 1200)
check(cat_of(out, "delegation")["agentSeconds"] == 100 and cat_of(out, "test")["agentSeconds"] == 300
      and cat_of(out, "coding")["agentSeconds"] == 110, f"background call swallowed later calls: {out['categories']}")
check([r["seconds"] for r in out["longest"]] == [300, 90, 10], f"longest uses the time a call owned: {out['longest']}")
# Parallel calls in one batch block the agent until the last returns.
out = direct([("completed", 0, 1200)],
             [(0, "command_execution", "completed", 10, 310, {"input": "pnpm test", "exitCode": 0}),
              (0, "dynamic_tool", "completed", 10.5, 12, {"toolName": "Read"}),
              (0, "dynamic_tool", "completed", 400, 410, {"toolName": "Edit"})], 1200)
check(cat_of(out, "test")["agentSeconds"] == 310 and cat_of(out, "coding")["agentSeconds"] == 100,
      f"parallel foreground call cut short: {cat_of(out, 'test')}")
out = direct([("completed", 0, 1400)],
             [(0, "subagent", "completed", 10, 1210, {"title": "A"}),
              (0, "subagent", "completed", 10.2, 311, {"title": "B"}),
              (0, "dynamic_tool", "completed", 1300, 1310, {"toolName": "Edit"})], 1400)
check(cat_of(out, "delegation")["agentSeconds"] == 1210, f"parallel subagents: {cat_of(out, 'delegation')}")
# A background call in a batch with a foreground call does not take its time.
out = direct([("completed", 0, 1200)],
             [(0, "dynamic_tool", "running", 10, None, {"toolName": "Monitor", "input": {"description": "CI"}}),
              (0, "command_execution", "completed", 10.4, 310, {"input": "pnpm test", "exitCode": 0}),
              (0, "dynamic_tool", "completed", 400, 410, {"toolName": "Edit"})], 1200)
check(cat_of(out, "test")["agentSeconds"] == 310 and cat_of(out, "coding")["agentSeconds"] == 100
      and cat_of(out, "waiting")["agentSeconds"] == 0, f"background call in a batch: {out['categories']}")
# Bookkeeping before a run's notice does not hide that a notice started it.
out = direct([("completed", 0, 60), ("completed", 600, 660)],
             [(1, "subagent", "completed", 590, 600, {"title": "Build it"}),
              (1, "notification", "completed", 600, 600, {"summary": 'Monitor "pr-review for PR 1" finished'})], 700)
check(out["churn"]["wakeups"] == 1 and cat_of(out, "review")["waitSeconds"] == 540, f"wake hidden: {out['churn']}")
# A long wait ended by a generic notice is idle.
out = direct([("completed", 0, 60), ("completed", 7200, 7260)],
             [(1, "notification", "completed", 7200, 7200, {"summary": "Background activity updated"})], 7300)
check(out["idleSeconds"] == 7140 and out["waitSeconds"] == 0, f"generic long wake: {out['idleSeconds']}")
# Items stored without a run (older threads, native subagent threads) are
# measured from their messages.
out = direct([], [(None, "user_message", "completed", 0, 0, {"inputIntent": "turn_start", "text": "build"}),
                  (None, "command_execution", "completed", 10, 600, {"input": "nix build .#x", "exitCode": 0}),
                  (None, "assistant_message", "completed", 610, 620, {}),
                  (None, "user_message", "completed", 700, 700, {"inputIntent": "turn_start", "text": "thanks"}),
                  (None, "assistant_message", "completed", 700, 710, {})], 800)
check(cat_of(out, "build")["agentSeconds"] == 600 and out["userSeconds"] == 80 and len(out["requests"]) == 2,
      f"run-less thread: {cat_of(out, 'build')} {out['userSeconds']}")
# Preparing a run between its request and its start is a wait, and the span
# starts at the first request that ran.
prep_runs = [("r0", 0, "completed", iso_at(0), iso_at(660), json.dumps({"startedAt": iso_at(600)})),
             ("r1", 1, "completed", iso_at(700), iso_at(760), json.dumps({"startedAt": iso_at(730)}))]
out = tt.analyse("t", "T", prep_runs, [], 30, BASE + 800)
check(out["spanSeconds"] == 760 and cat_of(out, "waiting")["waitSeconds"] == 600 + 30
      and out["userSeconds"] == 40, f"preparation: {out['spanSeconds']} {cat_of(out, 'waiting')} {out['userSeconds']}")
# Preparation as long as an idle gap is idle (a host asleep overnight).
prep_runs = [("r0", 0, "completed", iso_at(0), iso_at(7260), json.dumps({"startedAt": iso_at(7200)}))]
out = tt.analyse("t", "T", prep_runs, [], 30, BASE + 7300)
check(out["idleSeconds"] == 7200 and out["waitSeconds"] == 0, f"long preparation: {out['idleSeconds']}")
# A run-less thread counts as finished: work still running counts only up to
# its start, and never until now. A steer does not split its turn.
out = direct([], [(None, "user_message", "completed", 0, 0, {"inputIntent": "turn_start", "text": "build"}),
                  (None, "command_execution", "running", 10, None, {"input": "nix build .#x", "exitCode": None}),
                  (None, "dynamic_tool", "completed", 10.5, 12, {"toolName": "Read"})], 86400)
check(out["agentSeconds"] == 12, f"run-less thread measured as live: {out['agentSeconds']}")
out = direct([], [(None, "user_message", "completed", 0, 0, {"inputIntent": "turn_start", "text": "go"}),
                  (None, "subagent", "completed", 10, 590, {"title": "Build it"}),
                  (None, "user_message", "completed", 100, 100, {"inputIntent": "steer", "text": "also"}),
                  (None, "dynamic_tool", "completed", 200, 210, {"toolName": "Edit"}),
                  (None, "assistant_message", "completed", 610, 620, {})], 620)
check(cat_of(out, "coding")["agentSeconds"] == 10 and cat_of(out, "delegation")["agentSeconds"] == 200,
      f"steer split a run-less turn: {cat_of(out, 'coding')} {cat_of(out, 'delegation')}")
# Background work left running does not keep a finished run-less turn live,
# and a queued message does not cut the turn before it.
out = direct([], [(None, "user_message", "completed", 0, 0, {"inputIntent": "turn_start", "text": "go"}),
                  (None, "command_execution", "running", 10, None, {"input": "pnpm dev", "exitCode": None}),
                  (None, "dynamic_tool", "completed", 100, 110, {"toolName": "Edit"}),
                  (None, "assistant_message", "completed", 590, 600, {})], 86400)
check(out["agentSeconds"] == 600, f"background item kept a run-less turn live: {out['agentSeconds']}")
out = direct([], [(None, "user_message", "completed", 0, 0, {"inputIntent": "turn_start", "text": "build"}),
                  (None, "command_execution", "completed", 10, 590, {"input": "nix build .#x", "exitCode": 0}),
                  (None, "user_message", "completed", 100, 100, {"inputIntent": "queued_turn", "text": "next"}),
                  (None, "assistant_message", "completed", 590, 600, {})], 600)
check(cat_of(out, "build")["agentSeconds"] == 590, f"queued message cut the turn: {cat_of(out, 'build')}")
# Loose items in a thread with real runs do not make its live run stale.
out = direct([("running", 0, None)],
             [(0, "command_execution", "running", 10, None, {"input": "pnpm test", "exitCode": None}),
              (None, "user_message", "completed", 300, 300, {"inputIntent": "turn_start", "text": "old"})], 600)
check(cat_of(out, "test")["agentSeconds"] >= 290, f"loose item made the live run stale: {cat_of(out, 'test')}")
# The last batch has no next batch to show a call was in the background, and a
# call that returns exactly when the next batch starts was in the foreground.
out = direct([("running", 0, None)],
             [(0, "command_execution", "running", 10, None, {"input": "pnpm test", "exitCode": None}),
              (0, "dynamic_tool", "completed", 10.5, 12, {"toolName": "Read"})], 600)
check(cat_of(out, "test")["agentSeconds"] == 600, f"live call in the last batch lost: {cat_of(out, 'test')}")
out = direct([("completed", 0, 400)],
             [(0, "command_execution", "completed", 10, 310, {"input": "pnpm test", "exitCode": 0}),
              (0, "dynamic_tool", "completed", 10.5, 12, {"toolName": "Read"}),
              (0, "dynamic_tool", "completed", 310, 320, {"toolName": "Edit"})], 400)
check(cat_of(out, "test")["agentSeconds"] == 310, f"call ending at the next batch lost: {cat_of(out, 'test')}")
# A later batch is a boundary for every call before it.
out = direct([("completed", 0, 1200)],
             [(0, "dynamic_tool", "completed", 10, 10.5, {"toolName": "Read"}),
              (0, "subagent", "completed", 11, 1100, {"title": "Build it"}),
              (0, "command_execution", "completed", 12, 400, {"input": "pnpm test", "exitCode": 0}),
              (0, "dynamic_tool", "completed", 500, 510, {"toolName": "Edit"})], 1200)
check(cat_of(out, "test")["agentSeconds"] >= 388 and cat_of(out, "delegation")["agentSeconds"] <= 11,
      f"subagent skipped the next batch: {out['categories']}")
# An approval inside a running command is the user's wait; the command keeps
# the rest of its run.
out = direct([("completed", 0, 800)],
             [(0, "command_execution", "completed", 10, 700, {"input": "pnpm test", "exitCode": 0}),
              (0, "approval_request", "completed", 100, 600, {})], 800)
check(cat_of(out, "test")["agentSeconds"] == 200 and out["userSeconds"] == 500,
      f"approval inside a command: {cat_of(out, 'test')} {out['userSeconds']}")
check(out["longest"][0]["seconds"] == 190, f"longest keeps the approval wait: {out['longest']}")
# Longest items show the time a call owned, also across overlapping runs.
out = direct([("completed", 0, 600), ("completed", 300, 660)],
             [(1, "command_execution", "completed", 400, 650, {"input": "pnpm test", "exitCode": 0})], 700)
check(out["longest"][0]["seconds"] == 50, f"longest across overlapping runs: {out['longest']}")
# A cd inside a subshell does not move the shell.
out = direct([("completed", 0, 100)],
             [(0, "command_execution", "completed", 5, 6, {"input": "cd ~/src/apps/a && ls", "exitCode": 0}),
              (0, "command_execution", "completed", 10, 20, {"input": "(cd ~/src/apps/b && pr-review run 7)", "exitCode": 0}),
              (0, "command_execution", "completed", 30, 40, {"input": "pr-review run 7", "exitCode": 0})], 100)
check(out["reviewRuns"]["prs"] == 2, f"subshell cd moved the shell: {out['reviewRuns']}")
# Waiting for an approval is the user's time, and is not a longest item.
out = direct([("completed", 0, 800)], [(0, "approval_request", "completed", 100, 700, {})], 800)
check(out["userSeconds"] == 600 and out["longest"] == [], f"approval wait: {out['userSeconds']}")
# A delegated task's notification charges the wait to delegation.
out = direct([("completed", 0, 60), ("completed", 600, 660)],
             [(1, "notification", "completed", 600, 600,
               {"summary": 'Delegated task "Review the patch" finished', "source": {"kind": "delegated_task"}})], 700)
check(cat_of(out, "delegation")["waitSeconds"] == 540, "delegated task wait misfiled")
# A bare `pr-review run N` belongs to the repository the shell last entered.
out = direct([("completed", 0, 100)],
             [(0, "command_execution", "completed", 10, 20, {"input": "cd ~/src/apps/app && pr-review run 7", "exitCode": 0}),
              (0, "command_execution", "completed", 30, 40, {"input": "pr-review run 7 --response ok", "exitCode": 0})], 100)
check(out["reviewRuns"]["prs"] == 1 and out["reviewRuns"]["total"] == 2, f"review identity: {out['reviewRuns']}")
# Messages of a queued run that never started still count, and the queued run
# does not make the live one before it look stale.
out = direct([("running", 0, None), ("queued", 300, None)],
             [(0, "command_execution", "running", 10, None, {"input": "pytest", "exitCode": None}),
              (1, "user_message", "completed", 300, 300, {"inputIntent": "queued_turn", "text": "next"})], 600)
check(out["churn"]["userMessages"] == 1 and len(out["requests"]) == 1, "queued message dropped")
check(cat_of(out, "test")["agentSeconds"] == 600, f"queued run made the live run stale: {cat_of(out, 'test')}")
# Only the AskUserQuestion call is paired with an async question, not a
# tool call started beside it.
out = direct([("completed", 0, 600)],
             [(0, "user_input_request", "completed", 100, 100, {"responseMode": "message"}),
              (0, "dynamic_tool", "completed", 101, 400, {"toolName": "Bash", "input": {"command": "pnpm test"}})], 600)
check(cat_of(out, "test")["agentSeconds"] == 400, f"parallel tool zeroed: {cat_of(out, 'test')}")
# Shell tool calls count like command items; direct steers count as steers.
out = direct([("completed", 0, 100)],
             [(0, "user_message", "completed", 0, 0, {"inputIntent": "steer", "text": "go"}),
              (0, "dynamic_tool", "failed", 10, 20,
               {"toolName": "Bash", "input": {"command": "cd ~/src/apps/app && pr-review run 3"}})], 100)
check(out["reviewRuns"]["total"] == 1 and out["churn"]["steers"] == 1 and cat_of(out, "review")["failed"] == 1,
      f"shell tool or steer missed: {out['reviewRuns']} {out['churn']}")
check(out["longest"][0]["label"].startswith("pr-review run 3"), "shell tool labelled by its name")
# A cancelled run without a completion time does not charge the gap twice.
out = direct([("completed", 0, 60), ("cancelled", 300, None), ("completed", 600, 660)], [], 700)
check(out["userSeconds"] == 240 + 300, f"gap charged twice: {out['userSeconds']}")


def ts(minutes, seconds=0):
    return f"2026-10-12T10:{minutes:02d}:{seconds:02d}.000Z" if minutes < 60 else \
        f"2026-10-12T{10 + minutes // 60}:{minutes % 60:02d}:{seconds:02d}.000Z"


def build(path, drop_completed=False):
    db = sqlite3.connect(path)
    db.executescript("""
      CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, project_id TEXT, title TEXT,
        created_at TEXT, updated_at TEXT, payload_json TEXT);
      CREATE TABLE orchestration_v2_projection_runs (run_id TEXT PRIMARY KEY, thread_id TEXT, ordinal INTEGER,
        status TEXT, requested_at TEXT, completed_at TEXT, payload_json TEXT);
      CREATE TABLE orchestration_v2_projection_turn_items (turn_item_id TEXT PRIMARY KEY, thread_id TEXT,
        run_id TEXT, ordinal INTEGER, type TEXT, status TEXT, payload_json TEXT);
    """)
    db.execute("INSERT INTO orchestration_v2_projection_threads VALUES (?, 'p', 'Fixture thread', ?, ?, '{}')",
               (THREAD, ts(0), ts(0)))
    runs = [(1, ts(0), ts(10)), (2, ts(20), ts(21)), (3, ts(25), ts(26)), (4, ts(120), ts(121)),
            (5, ts(120, 30), ts(121, 30))]
    for ordinal, start, end in runs:
        db.execute("INSERT INTO orchestration_v2_projection_runs VALUES (?, ?, ?, 'completed', ?, ?, ?)",
                   (f"run-{ordinal}", THREAD, ordinal, start, end, json.dumps({"startedAt": start})))
    n = 0

    def item(run, kind, start, end, status="completed", **payload):
        nonlocal n
        n += 1
        body = {"startedAt": start, "completedAt": end, **payload}
        if drop_completed and n == 3:
            del body["completedAt"]
        db.execute("INSERT INTO orchestration_v2_projection_turn_items VALUES (?, ?, ?, ?, ?, ?, ?)",
                   (f"item-{n}", THREAD, f"run-{run}", run * 1000 + n, kind, status, json.dumps(body)))

    # Run 1, started by the user: 40 s exploring, 141 s writing an edit, 64 s
    # starting a review, 6 s on a Monitor, then the reply.
    item(1, "user_message", ts(0), ts(0), inputIntent="turn_start")
    item(1, "command_execution", ts(0, 30), ts(0, 40), input="rg -n foo src", exitCode=0)
    item(1, "command_execution", ts(3), ts(3, 1), input=f"cat > src/a.ts <<'EOF'\n{SECRET}\nEOF", exitCode=0)
    item(1, "command_execution", ts(4), ts(4, 5), input="cd ~/src/apps/app && git push -q && pr-review run 7",
         exitCode=0)
    # Starts while the push runs: the push stops owning time when it starts,
    # so no second is counted twice.
    item(1, "dynamic_tool", ts(4, 2), ts(4, 3), toolName="Read")
    item(1, "dynamic_tool", ts(4, 10), ts(4, 11), toolName="Monitor", input={"description": "pr-review for PR 7"})
    # Run 2, woken by a generic notice: the 10 minutes before it are a review wait.
    item(2, "notification", ts(20), ts(20), summary="Background activity updated")
    item(2, "command_execution", ts(20, 10), ts(20, 50), status="failed", input="corepack pnpm test", exitCode=1)
    # Run 3, the user's reply 4 minutes later, steering.
    item(3, "user_message", ts(25), ts(25), inputIntent="promoted_queued_to_steer")
    item(3, "dynamic_tool", ts(25, 20), ts(25, 21), toolName="Edit")
    item(3, "compaction", ts(25, 30), ts(25, 30))
    # Run 4, after an idle gap above 30 minutes.
    item(4, "user_message", ts(120), ts(120), inputIntent="turn_start")
    # Run 5 was queued and overlaps run 4: only its last 30 s are new.
    item(5, "user_message", ts(120, 30), ts(120, 30), inputIntent="queued_turn")
    db.commit()
    db.close()


def run(*args):
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True)


with tempfile.TemporaryDirectory() as tmp:
    good = f"{tmp}/good.sqlite"
    build(good)
    result = run("--db", f"{tmp}/missing.sqlite", "--db", good, THREAD)
    check(result.returncode == 0, f"run failed: {result.stderr}")
    check(SECRET not in result.stdout, "command text leaked into the output")
    out = json.loads(result.stdout)
    cats = {c["category"]: c for c in out["categories"]}
    check([c["category"] for c in out["categories"]] == tt.CATEGORIES, "categories out of order")
    check(cats["explore"]["agentSeconds"] == 41, f"explore {cats['explore']}")
    check(cats["coding"]["agentSeconds"] == 141 + 20 + 1, f"coding {cats['coding']}")
    check(cats["review"]["agentSeconds"] == 61 and cats["review"]["waitSeconds"] == 600,
          f"review {cats['review']}")
    check(cats["test"]["agentSeconds"] == 50 and cats["test"]["failed"] == 1, f"test {cats['test']}")
    check(cats["waiting"]["agentSeconds"] == 8, f"waiting {cats['waiting']}")
    check(cats["explore"]["items"] == 2, "overlapping Read not counted as an item")
    check(out["userSeconds"] == 240 and out["idleSeconds"] == 94 * 60, f"user {out['userSeconds']} idle {out['idleSeconds']}")
    check(out["agentSeconds"] + out["waitSeconds"] == out["activeSeconds"], "active time does not add up")
    check(out["agentSeconds"] == 600 + 60 + 60 + 60 + 30, f"agent time {out['agentSeconds']} is not the runs' total")
    check(out["churn"] == {"runs": 5, "userMessages": 4, "steers": 1, "wakeups": 1, "compactions": 1,
                           "interruptedRuns": 0, "failedRuns": 0, "failedItems": 1}, f"churn {out['churn']}")
    check(out["reviewRuns"] == {"total": 1, "prs": 1, "top": []}, f"review runs {out['reviewRuns']}")
    requests = out["requests"]
    check([r["activeSeconds"] for r in requests] == [1260, 60, 30, 60], f"request times {requests}")
    check(requests[0]["seconds"]["user"] == 240 and requests[1]["seconds"]["idle"] == 94 * 60,
          "a user message does not own the wait for its reply")
    check(requests[1]["intent"] == "promoted_queued_to_steer", "steer intent missing")
    for row in out["timeline"]:
        check(sum(row["seconds"].values()) <= out["binMinutes"] * 60 + len(row["seconds"]),
              f"bin at {row['start']} holds more time than it spans")
    binned = sum(sum(b["seconds"].values()) for b in out["timeline"])
    entries = sum(len(b["seconds"]) for b in out["timeline"])
    check(abs(binned - (out["activeSeconds"] + out["userSeconds"] + out["idleSeconds"])) <= entries,
          "timeline does not cover the span")

    check(run("--db", good, "nope").returncode == 2, "unknown thread should exit 2")
    drift = f"{tmp}/drift.sqlite"
    build(drift, drop_completed=True)
    check(run("--db", drift, THREAD).returncode == 3, "missing completedAt should exit 3")
    check(run(THREAD).returncode == 64, "no database should exit 64")
    broken = f"{tmp}/broken.sqlite"
    sqlite3.connect(broken).execute("CREATE TABLE unrelated (x)").connection.close()
    result = run("--db", broken, "--db", good, THREAD)
    check(result.returncode == 0, f"an unqueryable database before the right one should be skipped: {result.stderr}")
    check(run("--db", broken, THREAD).returncode == 3, "only an unqueryable database should exit 3")
    db = sqlite3.connect(good)
    db.execute("UPDATE orchestration_v2_projection_runs SET payload_json = 'not json' WHERE ordinal = 2")
    db.commit()
    db.close()
    check(run("--db", good, THREAD).returncode == 3, "a run payload that is not JSON should exit 3")
    for payload, status, want in [('{"startedAt": null}', "failed", 0), ("{}", "completed", 3)]:
        db = sqlite3.connect(good)
        db.execute("UPDATE orchestration_v2_projection_runs SET payload_json = ?, status = ?, completed_at = NULL"
                   " WHERE ordinal = 2", (payload, status))
        db.commit()
        db.close()
        result = run("--db", good, THREAD)
        check(result.returncode == want, f"run payload {payload} ({status}) exited {result.returncode}: {result.stderr}")
    db = sqlite3.connect(good)
    db.execute("UPDATE orchestration_v2_projection_turn_items SET payload_json ="
               " json_set(payload_json, '$.completedAt', json('null')) WHERE turn_item_id = 'item-2'")
    db.execute("UPDATE orchestration_v2_projection_runs SET payload_json = '{\"startedAt\": null}' WHERE ordinal = 2")
    db.commit()
    db.close()
    check(run("--db", good, THREAD).returncode == 3, "a finished item without completedAt should exit 3")

print("ok: t3-thread-time")
