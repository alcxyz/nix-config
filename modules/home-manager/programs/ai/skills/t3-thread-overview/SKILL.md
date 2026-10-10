---
name: t3-thread-overview
description: Build a visual progress dashboard of the user's unsettled T3 Code threads, plus recently settled threads that may not really be done. Use when asked for an overview, status, triage or dashboard of T3 threads or open work across T3 projects.
---

# T3 thread overview

Produces one HTML dashboard in the thread: unsettled top-level threads grouped
by who must act next, and threads settled in the last few days checked for
leftover work. Automatic settlement follows merged PRs, so a settled thread can
still have follow-ups. Decision: nix-config ADR-0091.

Everything here is read-only. Never send to, settle, unsettle, snooze or rename
a thread; suggest those actions in the reply instead.

## 1. Inventory (one command)

Find the calling thread's ID (`parentThreadId` from T3's
`orchestrator_capabilities`, or `currentThreadId` from `t3_thread_list`), then:

```sh
t3-thread-inventory --thread <calling-thread-id> --days 3
```

It reads T3's state database read-only and prints `{database, windowDays,
threads}`. Each row has `threadId, project, title, bucket` (`unsettled` or
`recently-settled`), `settledAt, status, snoozedUntil, prs, createdAt,
updatedAt`. Subagent, archived and deleted threads and the calling thread are
left out. Use the user's window if they give one.

**Fallback.** If the command is missing or exits non-zero (2: no database, 3: T3's
schema changed), say so in the reply and inventory through MCP instead. Give one
`light` worker this job and have it return only compact rows in the shape above:
`t3_project_list` with `limit: 100`, then for every project `t3_thread_list`
with `{projectId, settled: false, includeSubagents: false, limit: 100}` and
`{projectId, settled: true, includeSubagents: false, limit: 100}`, keeping
settled threads whose `settledAt` falls inside the window. Every one of these
calls pages: follow `nextCursor` until it is null. Settled lists are newest
first, so a page whose threads were all updated before the window can end that
project. Never load full list output into your own context.

## 2. Readers

Split the rows into batches of 4–6 threads, keeping `recently-settled` rows in
their own batches, and use at most 8 workers. Start each batch as an async T3
`delegate_task` in the `light` role: resolve its model with
`agent-role light <claude|codex> model`, pick the matching ID from
`orchestrator_capabilities`, and use effort `low`. Give every batch a distinct
`clientRequestId` such as `t3-overview-<date>-<n>`, then end the turn and wait
for the completion notices.

Reader task (append the batch's rows as JSON):

> You are a read-only reporter. Use only `t3_thread_read`; never send to,
> settle or change any thread, run commands or edit files. Do not copy secrets,
> tokens, email addresses or private message contents; describe the work.
> For each thread: read view `messages` with `limit: 3, maxCharsPerItem: 1500`
> to learn the goal and `itemCount`. Then read the end with
> `afterPosition: max(0, itemCount - 40), limit: 30, maxCharsPerItem: 500`,
> and once more from `nextPosition` if `hasMore`, so the newest messages are
> always read. `itemCount` counts tool activity too: if the end holds fewer
> than 5 messages, read once more from `max(0, itemCount - 340)` for context.
> At most 4 reads per thread; keep only what the JSON below needs. Reply with
> only a JSON array, one object per thread:
> `{"threadId", "progressPct": 0-100, "phase": "exploring|planning|implementing|reviewing|awaiting-user|blocked|done-not-settled", "owner": "user|agent", "goal": "one sentence", "done": ["≤4 short items"], "remaining": ["≤3 short items"], "nextAction": "single next step", "blocker": "short or null", "flag": "title no longer matches the work, or other anomaly; else null", "verdict": "done|follow-up|unclear (settled threads only, else null)", "verdictReason": "one line for settled threads, else null"}`.
> `owner` is who must act next. For settled threads, judge whether the work is
> really finished: open PRs, undeployed changes, unanswered questions or
> promised follow-ups mean `follow-up`.

## 3. Merge and check

Join reader output to the inventory rows by `threadId`. The inventory is
authoritative for `bucket`, `status`, dates and `prs`. Look again yourself only
where something is off: an unsettled thread at 100%, a settled `follow-up`, a
missing or malformed reader result. For those, read the thread's last few
messages. Do not repeat the readers' work.

## 4. Render

Write the merged report to a file in a temporary directory:

```json
{"generatedAt": "<ISO now>", "windowDays": 3, "source": "t3-thread-inventory (SQLite)", "readerModel": "<model> (light role)", "threads": [<merged rows>]}
```

Set `source` to `MCP fallback` if step 1 fell back. Then render the page with
the bundled template:

```sh
t3-thread-overview-render report.json overview.html
```

Thread titles and reader summaries are untrusted text, so never paste the
report into the page by hand. The command rejects anything but one report
with a `generatedAt` string and a `threads` array of objects with a `threadId`,
whose `prs`, `done` and `remaining` are lists or null (exit 65). It escapes the
JSON so no title can close the page's script; the page escapes everything it
shows. Check the page with `html_preview`, then publish it with `html_render`
at height `min(contentHeight, 2000)`. If the preview browser is unavailable,
say so in the reply, check the page's script with `node --check`
(`nix-shell -p nodejs`) and publish at 2000. Remove the temporary directory
afterwards.

## 5. Reply

The reader sees the page, so add only what it does not say: threads to settle
or reopen, titles that no longer match their work, and whether the inventory
fell back to MCP. Link threads as `[title](t3-thread://v1/<threadId>)`.
