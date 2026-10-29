# ADR-0101: Observe description formatting before deciding on enforcement

**Status:** Moved to a private repository on 2026-10-29
**Date:** 2026-10-22
**Applies to:** `programs.ai`, issue and pull request description hooks

## Context

Written description conventions and templates do not check the body an agent
submits. A small offline check can measure formatting drift, but an incomplete
Markdown scanner or tool classifier can also report valid writes incorrectly.
The owner approved implementation and a trial, explicitly choosing to log
violations while allowing writes. Keeping or enforcing the check is a later
owner decision informed by trial evidence.

## Decision

1. Provide one Python standard-library validator and a separate description
   hook. Do not change the PR review guard's decisions or exception handling.
   The hook never changes the supplied body, calls a forge, or executes body
   text. During this trial it always allows the tool call, including on an
   internal error. A standalone validation command can return invalid for use
   in tests and explicit preflight checks.
2. Default the feature off. Private consumer configuration supplies an explicit
   list of `host/owner/repository` targets, per-kind template exceptions, the
   trial end date and a local event directory. Build-time validation checks
   the complete generated configuration before activation. Unlisted targets are outside
   scope. Adding repositories or changing their contract is a configuration
   review, not an automatic consequence of an inventory class change.
3. Cover the named Forgejo MCP issue/PR create and body-update calls, and
   direct `gh issue|pr create|edit` calls with a literal body or a regular
   body file and an explicit `--repo`/`-R` target or full item URL. Do not infer
   gh targets from environment, defaults or Git remotes. Unattributed direct gh
   writes are recorded as unsupported without checking their bodies. Missing create bodies and explicit empty replacements are
   invalid. Metadata-only edits pass. Classify a write before inspecting its
   body; unknown tools and arbitrary shell constructs pass without a claim
   of coverage. Recognized writes with generated, dynamic, stdin or interactive
   bodies are recorded as unsupported, with a literal-body/file alternative.
   Do not grow a general shell interpreter or a credential-bearing write client.
4. Check the shared opening blocks in order, with no intervening extra label:
   issues use Status, Next, Owner, Why, Plan and Done when; PRs use What, Why,
   Risk, Verification and After merge. Permit leading HTML comments and blank
   lines. Require top-level bold labels, paragraph separation, numbered Plan
   steps beginning at 1, checklist completion criteria and a one-line PR
   Verification. Flag Markdown headings and misplaced labels outside literal
   code/comments, including inside details. Check the blank line after summary.
   This is a documented subset of Markdown, not a full renderer or semantic
   review. Legacy and user-authored replacement bodies receive the same check.
5. Store bounded local JSONL events with restricted permissions. Record only
   timestamp, schema/validator version, delivery source, route, scoped target,
   kind, outcome, rule IDs/line numbers and elapsed time before log append.
   This timing excludes interpreter startup, lock wait and log I/O; use separate
   wall-clock probes for total hook overhead. Never retain bodies, shell commands,
   arbitrary exception strings, credentials or body-derived hashes. Record
   unmatched delivery counts without tool arguments so missing coverage can be
   distinguished from an absence of invalid writes. Rotate under one lock.
6. Expose an offline aggregate report. Keep the trial's running summary and
   reviewed examples in the owning private issue. A collector may publish
   aggregates separately; hooks do no network work. Report attempts, not
   successful writes: a pre-tool hook cannot know whether the later API call
   succeeded. Human review is needed to label false positives and misses.
7. Target a 14-day observation window, with a configured fixed cutoff, an actual
   activation timestamp and sufficient samples from each claimed route. Record
   the actual duration when deployment is later than planned; do not claim a
   full window from an intended activation date. After the configured end,
   hooks allow calls without collecting further trial events. Never switch
   automatically to blocking. The owner chooses keep, revise, extend or remove.

## Coverage and qualification

Test payloads, hooks and installed client delivery separately. File presence
does not prove a client runs a hook. Record each host/client as unqualified
until a harmless in-session or mock-transport probe observes the installed
hook. Do not claim universal coverage based on another client's result.

Known initial gaps: unhooked sessions, web/manual writes, raw REST, `gh api`,
other CLIs, opaque scripts and subprocesses (including first-party filing and
status refresh tools), unsupported shell forms, an unconfigured GitHub MCP,
and a body file changing after validation. A missing command, timeout or
undelivered event cannot be assumed to produce evidence. Managed Codex and
user Claude hook delivery must be recorded separately. This trial adds no
managed Claude enforcement policy and no new credentials.

Events distinguish `codex-managed`, `codex-user`, `claude-user` and explicit
direct probes, without session identifiers. When the installed managed Codex
observer command is executable, the Codex user hook suppresses its own event
so trusting user hooks does not double-weight that client's traffic. This is
installation routing, not proof that a client delivered the managed event;
qualify actual managed delivery before relying on the suppression. Without that
managed command the user hook remains available, subject to client trust.
Standalone and T3-hosted sessions of the same client share a delivery source;
qualify them with separate recorded probe windows.

## Alternatives considered

- Guidance and template fixtures alone: inexpensive, but cannot measure actual
  outgoing writes.
- Immediate blocking: rejected for the trial so false positives can be measured
  without interrupting writes.
- Separate validators per client or forge: duplicates the syntax contract.
- A full Markdown/shell parser or a new write gateway: substantially broader
  than the observed formatting problem; defer unless trial evidence warrants it.

## Consequences

Formatting remains guidance during observation. Results describe delivered
hook attempts only. The explicit coverage matrix and trial issue must remain
clear about missing routes, reviewed false positives and unavailable clients.
Future enforcement requires a separate owner decision and an ADR amendment.
