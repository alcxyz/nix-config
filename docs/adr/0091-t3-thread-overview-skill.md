# ADR-0091: Deploy a T3 thread overview skill that reads T3 state directly

**Status:** Accepted
**Date:** 2026-10-10 (amended 2026-10-11 for #631, and 2026-10-11: skills move to nix-secrets; 2026-10-15 for #676; 2026-10-18: overview sections and acknowledged threads)
**Applies to:** `modules/home-manager/programs/ai/`, `flake/checks/default.nix`,
the user modules that enable `programs.ai`

## Context

An overview of unsettled T3 Code threads, read by cheap helper agents and
rendered as one HTML page, proved useful enough to repeat. Building the first
one showed that T3's MCP interface makes the inventory expensive:
`t3_thread_list` covers one project per call, so the overview needed one call
per project (48 here) before any thread was read, and listing without
`includeSubagents: false` returned tens of thousands of characters of
subagent rows. T3 also settles threads automatically when their linked pull
request merges, so a recently settled thread can still have follow-up work.

T3 keeps every thread's settlement state, lineage and linked pull requests in
its local SQLite projection (`<baseDir>/userdata/statev2.sqlite`), one
database per T3 instance. The MCP server derives `settled` from the same
`settledOverride` field.

## Decision

`programs.ai` installs a `t3-thread-overview` skill for both Claude Code and
Codex, and a `t3-thread-inventory` command. The command runs one read-only
query against the state database of the instance that holds the calling
thread, and lists unsettled top-level threads plus those settled within a
window (three days by default). The skill hands batches of those threads to
`light`-role readers, asks them whether recently settled work is really done,
and renders a shared HTML template.

The query depends on T3 internals, so the command first checks that every
thread payload carries the fields it relies on. When that check or the query
fails, it exits with a distinct status and the skill falls back to per-project
MCP listing by a single helper. A contract test pins the query's behaviour
against a fixture database.

## Alternatives and consequences

- **MCP only:** stays on the supported interface but keeps about two list calls
  per project for every overview.
- **Add cross-project listing to T3:** the cleanest long-term fix; the skill can
  switch to it once T3 offers it, and the inventory command can then go.

A T3 update that renames these fields breaks the fast path loudly rather than
silently, and costs only the fallback's extra calls until the query is
updated. The skill was the first one this repository deployed; skills now live
in nix-secrets (see the last amendment).

## Amendment: shared thread facts (#631)

Users kept asking threads whether they were done, each agent rebuilt the
answer by hand, and threads that stalled before a handoff could not answer at
all. `programs.ai` therefore also installs `t3-thread-status`, a
`t3-thread-status` skill for both clients, and `t3-thread-status-render`.

- **One fact source.** `t3-thread-status` reports, for one or more threads,
  the latest run, idle time, held background work, linked pull requests, the
  worktree's uncommitted and unpushed work (read-only git, no fetch) and the
  thread's own `Settle:` line, plus pass/fail checks and a verdict: `waiting`,
  `ready`, `not-yet` or `stalled`. The inventory and the status command share
  the database selection and schema checks (`t3-state-db.sh`) and the
  background-work rules, as temporary views over the read-only connection
  (`t3-thread-common.sql`), so the two cannot drift apart.
- **Threads report on themselves.** At a handoff an agent runs the command on
  its own thread and ends with `**Settle:** ready.` or `**Settle:** not yet:
  <what remains, owner>`. Agents never settle threads; the user decides.
- **The overview prefers those facts.** It runs the command for every
  unsettled thread; a thread's own current `Settle:` line beats the reader's
  guess, and threads that never handed off are flagged as stalled.
- **Cards are rendered, not written.** Like the overview, the status card is a
  fixed template filled by a script that escapes the JSON, so no thread text is
  pasted into a page by hand.

The status command depends on the same T3 internals, plus each thread's
`worktreePath`, `branch` and message text, and checks them the same way: a
missing field fails loudly (exit 3) and the skill falls back to T3's MCP tools.

## Amendment: skills live in nix-secrets

The skills this ADR introduced (`t3-thread-overview`, `t3-thread-status`) and
the others that followed its `home.file` pattern (`long-running-jobs`,
`dispatch-thread`, `pr-review`) move to the private nix-secrets
`shared/skills/`, under nix-secrets ADR-0016's 2026-10-11 amendment. The owner
prefers not to publish agent procedures while they change daily, and keeping
them private removes the need to vet every edit for private detail.

- nix-secrets' `agentSkills` Home Manager module links each skill for both
  clients from the local checkout, like `~/AGENTS.md`. The user modules that
  enable `programs.ai` (xyz and xps) import it beside `programs.ai`, so skills
  reach only hosts that have the commands they call, as before.
  `programs.ai` no longer installs skills.
- The commands, their SQL, the HTML templates they bundle and their checks stay
  here. The templates move out of the skill directories, to
  `t3-thread-overview.html` and `t3-thread-status-card.html` beside their
  render scripts.
- New skills start in nix-secrets. Earlier versions remain in this repository's
  history; they hold generic procedures, so no history rewrite is planned.

## Amendment: settled threads judged from facts (#639)

Every recently settled thread cost the overview a reader, and settling runs at
several threads a day, so a week's window held about 50 of them. With shared
facts (#631) most can be judged without one.

- `t3-thread-status` gives a settled thread its own verdict: `done` when its
  current `Settle: ready` line and every other check agree, `left-for-you`
  when that line comes with steps for the user, and `check` otherwise. A git
  check may go unanswered only where there is nothing to read: no worktree,
  or a removed one or deleted branch whose work a merged pull request vouches
  for. `waiting` and `stalled` describe live threads only, since every
  settled thread goes idle. It reports the steps as `settle.leftForYou`, from
  the same message's `Left for you:` label or the list below it; a mention it
  cannot read makes the thread `check`.
- The overview runs the command for settled threads too and sends only those
  marked `check` to readers. The page lists `done` threads as confirmed done
  and keeps `left-for-you` threads in view with their steps.
- Only threads that handed off since #631 have a `Settle:` line, so threads
  without one still get a reader. Steps left for the user are shown, not
  checked: the facts cannot tell whether a deploy happened.

## Amendment: where a thread's time goes (#676)

Long threads spend most of their wall time in a few steps, and the experience
reports in #657 estimate those by hand. `programs.ai` therefore also installs
`t3-thread-time` and `t3-thread-time-render`, used by a `t3-thread-time` skill
in nix-secrets.

- **Measured, not judged.** The command splits a thread's time by kind of
  work (discussion, tracking, exploring, coding, test, build, git, review, CI,
  deploy, verification, delegation, waiting) from the same state database.
  Inside a run, calls are grouped into batches (parallel calls start
  together), and a batch's time, including the model time spent writing it,
  belongs to the call it waited on longest. So the time spent writing an edit
  counts as coding, concurrent calls are never counted twice, and a call still
  running when the next batch starts counts as background work from then on.
  Waits for a question or approval are the user's time. Between runs, a run
  started by a notification charges the gap to the background work that woke
  it, and one started by the user charges it to the user, or to idle above a
  threshold. Items stored without a run (threads from before T3's run
  projection, native subagent threads) are grouped into runs at each message
  that starts a turn or notice; without T3's run status they count as
  finished, so a live one is understated. It also counts churn: failed items,
  steers, compactions and `pr-review` runs per pull request.
- **Heuristic categories.** Commands are classified by rules on their shell
  text, with heredoc bodies ignored and edits winning. The rules will misfile
  some commands; the `other` share and the fixture test show where, and the
  rules change with the evidence rather than with a model's guess.
- **A `light` reader explains, the numbers do not change.** The skill gives the
  JSON to a `light`-role worker, which reads only the hotspots in the thread
  and writes notes: why the top categories took that long and what to tune.
  The page shows the notes beside the measured numbers.
- **Text stays inside.** Command text is read to classify it and leaves the
  command only as a short first-line label; the renderer escapes it like the
  other pages.

The command reads each turn item's `startedAt` and `completedAt`, each run's
`startedAt`, and fails with exit 3 when items or runs lack those fields or a
finished item has no completion time. Notification summaries and sources are
optional: a notice without them counts as generic. Delegated child threads are not followed; their time shows as
delegation in the parent, and the skill can run the command on a child.

## Amendment: overview sections and acknowledged threads

The single overview page grew past 8000 pixels at about 30 threads, so the
user scrolled one long frame to find what needed them. Settled threads that a
reader kept calling "maybe not done" came back on every run, with no way to
say they were finished.

- **One frame per section.** `t3-thread-overview-render` now writes one page
  per non-empty section (waiting on you, stalled, ready to settle, recently
  settled, agent side) and a `pages.json` manifest; the skill publishes each
  as its own frame with a capped height, so long sections scroll on their own.
  Threads are one-line rows that expand for details, and "waiting on you" is
  split by the kind of action a reader names (`actionKind`: decide, deploy or
  verify, review or merge, sign in or unblock). The renderer, not the page,
  now groups threads, so each page carries only its own threads and the
  grouping rules live in one place.
- **Acknowledged threads.** `t3-thread-overview-ack ID@SETTLED_AT` records a
  settled thread the user accepts as done, in a small state file.
  `t3-thread-inventory` marks it `acknowledged` while its settle time still
  matches, the skill gives it no reader, and the page lists it as done. The
  page offers a checkbox per "maybe not done" thread that builds this command
  for the user to run: a rendered page is a sandboxed frame that cannot write
  anything or reach T3's tools, and the skill stays read-only towards T3.
- **Thread links go through the app route for now.** T3 forwards only
  `http(s)` link clicks out of a rendered page, so `t3-thread://` links, which
  work in chat Markdown, do nothing there. A page is served by the T3 server
  itself, so it links each thread to that server's `/<environmentId>/<threadId>`
  route, which T3 opens in a browser tab or its preview pane rather than
  switching threads. The report carries the environment ID; without it, or
  outside a served frame, the page keeps `t3-thread://` links. The skill's
  reply still carries working chat links. Once T3 opens thread links from
  pages, the pages can go back to `t3-thread://`.

Several frames cost more to publish than one, since each repeats the
template; the page is about 16 KB before its threads.
