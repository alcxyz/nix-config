# ADR-0093: Triage open issues and pull requests from one computed inventory

**Status:** Accepted
**Date:** 2026-10-12
**Applies to:** `modules/home-manager/programs/ai/`, `flake/checks/default.nix`,
the user modules that enable `programs.ai`

## Context

Open work is spread over about seventy active Forgejo repositories, two dozen
GitHub-first repositories and the user's pull requests in repositories owned by
others: 440 open issues and 43 open pull requests when this was written.
Choosing what to look at next costs a context switch per repository, and three
kinds of item hide well: issues whose work already merged but that were never
closed, pull requests no live T3 thread is driving, and issues nobody has
touched in months.

Listing this through the Forgejo MCP server is expensive: one search result
carries the full author object and body of every issue, so a fleet-wide list
would fill an agent's context before any judgement. Few mechanical signals are
reliable. Only a handful of issues carry the dated `**Status (date):**` line
from the structured-work guide, about a quarter use checkboxes, and labels are
sparse, so deciding whether an issue still matters needs a reader.

## Decision

`programs.ai` installs `backlog-inventory` and `backlog-overview-render`, and
the private `backlog-overview` skill (nix-secrets `shared/skills/`) drives
them, on the pattern of ADR-0091.

- **One computed inventory.** `backlog-inventory` makes one read-only pass over
  the Forgejo API with the user's API token, read from its file inside the
  process and sent only to the Forgejo URL the Nix wrapper pins. It also calls `gh`, which keeps its own credentials, for the
  repositories Forgejo mirrors from the user's GitHub account and for the
  user's open pull requests elsewhere. It prints compact JSON: each issue and
  pull request with its age and idle days, status line, checkbox progress, the
  open and merged pull requests that reference it, CI, mergeability, the
  `pr-review` state of the head (ADR-0078) and the T3 thread holding it (from
  `t3-thread-inventory`), plus a lane and flags. Bodies are read and never
  printed. A GitHub failure marks `sources.github` and keeps the Forgejo rows.
- **Lanes are mechanical and documented.** An issue is `close` when every
  checkbox is ticked or a merged pull request closed it, `inflight` with an
  open pull request, `stale` after 45 idle days, otherwise `active`; the flag
  `untouched-since-merge` marks issues nobody touched for three days after a
  pull request naming them merged. A pull request is `renovate` (any bot),
  `inflight` (an unsettled thread holds it), `blocked` (failed CI, a conflict
  outside drafts, or changes requested), `ready` (green, mergeable and
  reviewed for its head and target branch as the merge guard requires, or
  approved upstream), `review` (someone else's, on the user's repository),
  `waiting`, `stale` or `open`.
- **Readers judge a shortlist.** The skill gives `light` readers only the
  items the lanes cannot decide, such as maybe-done and stale issues, or one
  repository's issues when the user picks a repository to work through. They
  return a verdict (`close`, `dispatch`, `refresh`, `keep`, `drop` or
  `unclear`) and a reason. The renderer fills a fixed HTML template with the
  escaped inventory, picks and verdicts, keeping only the rows the page shows.
- **Read-only.** The commands never write. The skill suggests closes, comments
  and dispatches, and acts only on the user's confirmation.

## Alternatives and consequences

- **Forgejo MCP and `gh` from the agent:** no new code, but every run pays for
  full issue bodies in context and repeats the same paging and joins by hand.
- **A forge-side dashboard or stale bot:** Forgejo has no cross-repository
  triage view, and a bot that labels or closes by age acts without judgement
  and cannot see T3 threads.
- **Fold this into the thread overview:** the thread overview answers whether
  a thread is done; this answers what to pick up next. They share
  `t3-thread-inventory` output instead.

The lanes are heuristics, so an issue can look done when it is not; the page
says "maybe done" and the skill checks before suggesting a close. Branches and
worktrees are left out (nix-secrets #221). The Forgejo token cannot list
organisations, so the inventory covers the repositories `/user/repos` returns.
