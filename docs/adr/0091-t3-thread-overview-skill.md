# ADR-0091: Deploy a T3 thread overview skill that reads T3 state directly

**Status:** Accepted
**Date:** 2026-10-10 (amended 2026-10-11 for #631, and 2026-10-11: skills move to nix-secrets)
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
