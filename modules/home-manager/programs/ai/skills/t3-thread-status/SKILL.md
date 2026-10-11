---
name: t3-thread-status
description: Report whether a T3 Code thread is done and ready to settle, from shared facts, ending with a one-line Settle verdict and optionally an HTML status card. Use at a structured-work handoff, when the user asks whether this thread is done or ready to settle ("are we done?"), or when asked for the status of another thread by ID.
---

# T3 thread status

Answers "is this thread ready to settle?" from the same facts every time, for
this thread or another one. Decision: nix-config ADR-0091 (#631).

Never settle, unsettle, snooze, rename or send to any thread, including your
own: the user decides. Everything here is read-only.

## Facts

```sh
t3-thread-status --self <this-thread-id>   # your own thread
t3-thread-status <thread-id>...            # other threads
```

Find your own thread ID as `parentThreadId` from T3's
`orchestrator_capabilities`, or `currentThreadId` from `t3_thread_list`.

It reads T3's state database and the thread's worktree read-only (git
without fetching, so remote branches are as of the last fetch) and prints
`{database, generatedAt, threads}`. Each thread has:

- `run` (latest run status), `idleSince`, `idleMinutes`;
- `waitingOn`: background work T3 counts, as in `t3-thread-overview`. Any
  kind but `command` will wake the agent;
- `prs`: linked pull requests with `state` and `watched`;
- `worktree`: `branch` (the thread's), `head` (what the worktree has checked
  out), `changed`, `untracked`, and `branches`: commit facts for the thread's
  branch and, if different, the checked-out one, each with `unpushed`
  (commits on no remote branch once the upstream is gone), `upstreamGone`,
  `base`, `aheadOfBase`, `inBase` (whether its changes are in the base
  branch, by file content or as one squashed commit) and `missing` (gone from
  the worktree, so unknown). `worktree` is null when the thread has no
  worktree, has `exists: false` when it was removed, and `error` when git
  cannot read it;
- `settle`: the `Settle:` line, only if it is the last non-empty line of the
  newest finished assistant message, with `verdict`, the `owner` it names, and
  `stale` when a user message came after it;
- `checks`: pass (`true`), fail (`false`) or not applicable (`null`) rows;
- `verdict`: `waiting` (a run or held background work), `ready` or `not-yet`
  (from a current `Settle:` line), `stalled` (no current `Settle:` line,
  and uncommitted or unpushed work, a failed, interrupted or cancelled run,
  or idle past `--stale-hours`, default 24), else `not-yet`;
  `stallReasons` says why. With `--self`, `settle`, `verdict` and the run and
  `Settle:` checks are null, since this reply decides them, and `waitingOn`
  lists your own background tasks and pull request watches.

Exit 2 means no database or thread was found, 3 that T3's schema changed. Then
say so and fall back to `t3_thread_read` and `t3_worktree_status`.

## Your own thread

Run it at a structured-work handoff, or when the user asks whether the thread
is done or ready to settle. Read the failing checks, add what the facts cannot
show (what remains and who owns it), and end the final message with exactly
one of these as its last line:

- `**Settle:** ready.`
- `**Settle:** not yet: <what remains>, <owner>.`

Writing the line only reports readiness; agents never settle threads. Say
`ready` when nothing is left for this thread: the structured-work steps it owns
are done (for a delegated thread, its brief's definition of done, reported
back), its merged work passed `pr-review` and CI on its head, and no
background work you will act on is running. Explain any failing check you still
call ready, such as an untracked file the user keeps. Steps for the user, such
as a deploy, go on a `**Left for you:**` line before it and do not block
`ready`; leave the issue open with its status naming the user as owner of that
step and of the validation or closing that follows. While you wait on a review,
CI or a monitor, the thread is `not yet` and the agent owns it.

The overview and other threads read only the last non-empty line of your
newest message, so keep it last and unformatted beyond the bold label, and end
`not yet` with `user` or `agent` as the owner. A routine
handoff needs only the line; render the card when the user asks for it.

## Another thread

Run `t3-thread-status <id>`, then read its newest messages with
`t3_thread_read` (view `messages`, from `afterPosition: max(0, itemCount - 40)`,
`maxCharsPerItem: 800`) to learn what remains and who owns it. Do not copy
secrets, tokens or private message contents; describe the work. Report the
verdict, the failing checks and what remains, and render the card. A thread
that never handed off shows as `stalled`: say what it left behind
(`stallReasons`) and what the user could do, such as resuming or settling it.

## Card

Write the facts and your notes to files in a temporary directory, then
render the bundled template:

```sh
t3-thread-status [--self] <id> >status.json
t3-thread-status-render status.json notes.json card.html
```

`notes.json` holds what the facts cannot show:
`{"verdict": "ready|not-yet|waiting|stalled", "summary": "one line",
"remaining": ["..."], "owner": "user|agent", "leftForYou": ["..."]}`. All
fields are optional except `verdict` for a `--self` report; for another
thread, leave it out to use the script's verdict. The command rejects
anything else (exit 65) and escapes the JSON so no title can close the page's
script. Check the page with `html_preview`, then publish it with
`html_render` at its `contentHeight`. If the preview browser is unavailable,
say so and check the script with `node --check`. Remove the temporary
directory afterwards.
