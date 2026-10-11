---
name: long-running-jobs
description: Start, watch and resume unattended work that must survive the agent session, such as model batches, long builds, migrations or release waits, and get notified when it ends. Use before starting a command that may run long enough for the thread to settle or T3 to restart, before starting a server or watcher to test it, when asked to monitor a job, or when waiting on a CI run, deployment or PR check, even one you started yourself, or before ending a turn to wait for a background command.
---

# Long-running jobs

T3 runs each agent session in its own systemd scope. Settling a thread, a T3
restart or a crashed session ends everything the session started, including
its background commands. A 200-document batch was killed at 195/200 this way,
and a CI build finished unnoticed after the session sleeping on it ended.
`agent-job` runs the work as a transient systemd user unit instead, which keeps
running on its own; the session only waits for it. Tracking: nix-config #612.

## Choose the mechanism

- **Work you wait on in this session**, such as a test run or `pr-review run`:
  run it normally, or as an ordinary background command while you keep
  working. To end your turn and resume when it finishes, wait through a
  Monitor in Claude Code ([below](#wait-across-a-turn-end-claude-code)).
- **A server or watcher you start only to test it**: bound it with
  `timeout -k 5 <duration> <command>`, which also kills it if it ignores
  SIGTERM, and keep the duration under your tool's own command limit. To send
  it requests, start it and the client in the same command, for example
  `timeout -k 5 60 <server> & pid=$!; <wait for the port>; curl ...; kill $pid; wait`.
  Do not start it in one command and kill it in a later one: a missed kill
  leaves an orphan holding ports or connections.
- **Unattended local work that must survive the session**, such as long
  batches, builds or release waits: `agent-job`, below.
- **Outside state** such as PR checks, CI runs or deployments: do not use a
  `sleep` in the session as a reminder. In T3, use `watch_pull_request` for an
  open PR (T3 wakes the thread when checks finish, someone comments or the
  branch conflicts). A merge ends what that watch covers and makes the thread
  a candidate for automatic settlement, so poll a short wait after it, such as
  a rollout, through a Monitor in Claude Code
  ([below](#wait-across-a-turn-end-claude-code)). Use `schedule_task` for
  longer or recurring checks, with an interval matched to the expected
  duration. Scheduled tasks recur, so delete yours with
  `delete_scheduled_task` once the wait is over. Elsewhere, check again on the
  next turn.

## Wait across a turn end (Claude Code)

T3 records a background Bash command as finished work, like a server left
running. If you end your turn while one runs, the thread shows Completed, the
completion alert fires, and automatic settlement can settle it (right after a
PR merges, for example). Settling ends the command. T3 treats a task started
with the **Monitor** tool as work that will wake the agent: the thread shows
Waiting and is not settled automatically (nix-config #627).

So when you end your turn to wait for a result you will act on, let a Monitor
do the waiting. A Monitor lasts at most 30 minutes (`timeout_ms` 1800000) and
kills its command when it expires, so it should only wait, never run the work:

1. Get a log path from `mktemp`, then start the work as a background command
   that writes a marker when it ends, for example
   `pr-review run <pr> >"<log>" 2>&1; echo "exit $?" >"<log>.done"`. Give it a
   `timeout` above the work's own limit (the Bash tool allows up to 7200000).
2. Wait for the marker with a Monitor:
   `until [ -s "<log>.done" ]; do sleep 10; done; cat "<log>.done"`, with
   `timeout_ms` 1800000. If it expires before the marker appears, start
   another one while the background command still runs; if that command has
   ended without a marker, it was killed, so treat the work as failed. Then
   read the log.

- Poll outside state, such as a rollout, directly in the Monitor: the poll is
  only a wait. Exit on every end state, not only success, and sleep 30 seconds
  or more between remote checks.
- Run work that must survive a manual settle or a T3 restart with `agent-job`,
  and wait on it through a Monitor ([below](#get-notified)).
- Keep plain background commands for servers and work you do not wait on.

Codex waits in the foreground, so T3 already shows its thread as running.

## Start

```sh
agent-job start <name> -- <command> [args...]
```

- `<name>`: lowercase letters, digits and dashes, unique and descriptive
  (`paperless-retitle`, not `job1`). The unit is `agent-job-<name>.service`.
- The job runs in the current directory with your `PATH` and the systemd user
  manager's environment: the session variables T3 itself runs with, including
  the `*_FILE` pointers that reviewed clients use to read activated credential
  files. Variables you exported and direnv's environment do not carry over, so
  make the command self-contained, for example with
  `nix-shell -p <pkg> --run '...'` or a project script that sets up the rest.
- Never put secrets in the arguments: they are stored in the job directory and
  visible in process listings. Credentials reach the job only through reviewed
  clients that read activated credential files themselves.
- Jobs survive logout only where the user has lingering enabled (xyz does).
- Tell the user the job name and that `agent-job status <name>` shows it.

## Get notified

- **Claude Code:** run `agent-job wait <name>` through the Monitor tool with
  `timeout_ms` 1800000, so the thread shows Waiting
  ([above](#wait-across-a-turn-end-claude-code)). You are re-invoked when it
  exits. If the Monitor expires while the job still runs, only the wait ends:
  start another. If the session ends, only the wait is lost; the job
  continues.
- **Codex** has no background notification. Check `agent-job status <name>` when
  you next act, or wait in the foreground in bounded steps:
  `timeout 600 agent-job wait <name> 30` (exit 124 means it is still running).

`agent-job wait <name> [seconds]` polls every 10 seconds by default, then prints
the result, with the job's own exit status, and the last 20 log lines. It exits
with:

| Exit | Meaning |
| --- | --- |
| 0 | the job exited with status 0 |
| 1 | the job failed, was killed or was stopped; the summary line shows how |
| 70 | the unit ended without recording a result, for example after a reboot |
| 66 | no job with that name |

## Pick up a job later

```sh
agent-job list                 # every job and its state
agent-job status <name>        # state, directory, command and log path
agent-job log <name> [lines]   # end of the log (default 50 lines)
```

Files live in `~/.local/state/agent-jobs/<name>/`: `log`, `info`, `result`,
`argv`, and a garbage-collector root for the `agent-job` version that records
the result. `journalctl --user -u agent-job-<name>` shows when the unit started
and stopped.

## Stop and clean up

- `agent-job stop <name>` stops a running job. Ask before stopping a job
  another thread started.
- `agent-job clean <name>` removes a finished job's directory. A name stays
  taken until it is cleaned. Clean your own jobs once you have read and
  reported the result; leave other threads' jobs alone.
