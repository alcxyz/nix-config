# ADR-0091: Deploy a T3 thread overview skill that reads T3 state directly

**Status:** Accepted
**Date:** 2026-10-10
**Applies to:** `modules/home-manager/programs/ai/`, `flake/checks/default.nix`

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
updated. The skill is the first one this repository deploys; skills that do
not need packaging can follow the same `home.file` pattern.
