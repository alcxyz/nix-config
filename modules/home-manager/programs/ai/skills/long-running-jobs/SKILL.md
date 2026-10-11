---
name: long-running-jobs
description: Start, watch and resume unattended work that must survive the agent session, such as model batches, long builds, migrations or release waits, and get notified when it ends. Use before starting a command that may run long enough for the thread to settle or T3 to restart, or when asked to monitor a job, CI run or deployment.
---

# Long-running jobs

T3 runs each agent session in its own systemd scope. Settling a thread, a T3
restart or a crashed session ends everything the session started, including
its background commands. A 200-document batch was killed at 195/200 this way.
`agent-job` runs the work as a transient systemd user unit instead, which keeps
running on its own; the session only waits for it. Tracking: nix-config #612.

## Choose the mechanism

- **Work you wait on in this session**, such as a test run or `pr-review run`:
  run it normally, or as an ordinary background command.
- **Unattended local work that must survive the session**, such as long
  batches, builds or release waits: `agent-job`, below.
- **Outside state** such as PR checks, CI runs or deployments: do not start a
  local poller. In T3, use `watch_pull_request` for a PR (T3 wakes the thread
  when checks finish, someone comments or the branch conflicts) and
  `schedule_task` for other periodic checks. Elsewhere, check again on the next
  turn.

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

- **Claude Code:** run `agent-job wait <name>` as a background command with a
  long timeout (up to the two-hour maximum). You are re-invoked when it exits.
  If the wait times out while the job still runs, start another wait. If the
  session ends, only the wait is lost; the job continues.
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
