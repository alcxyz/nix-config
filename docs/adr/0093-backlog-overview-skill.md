# ADR-0093: Triage open issues and pull requests from one computed inventory

**Status:** Accepted, amended 2026-10-16 (scopes, related items, branch lane, thorough mode; local worktrees, #701)
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

### Amendment 2026-10-16: scopes, related items and thorough mode

The first version saw only the Forgejo fleet, the GitHub repositories Forgejo
mirrors from the user's account and the user's own pull requests elsewhere;
`--repo` narrowed only Forgejo. Issues in GitHub organisation repositories the
user works in stayed invisible, and a manual triage showed evidence the
`light` readers miss: a scheduled workflow's run history, a pull request named
only in another repository's issue, leftover branches and outdated status text.

- **Scopes.** `--scope` (repeatable; `--repo` stays as an alias) takes
  `OWNER/REPO` for Forgejo, `gh:OWNER/REPO` for GitHub, a group name or
  `all`. Without it the run covers all: the Forgejo fleet, the GitHub mirrors,
  the user's own pull requests elsewhere and every configured group, never a
  whole GitHub organisation. A narrower scope reads only its repositories and
  skips the upstream pull request search.
- **Groups come from a scope file.** `programs.ai.backlog.scopeFile` (default
  none) names a JSON file
  `{"groups": {"NAME": {"description": "...", "repos": ["gh:example-org/service", "OWNER/REPO"]}}}`;
  `--scope-file` overrides it for one run. Groups list repositories
  explicitly, without wildcards. This flake ships no groups: private modules
  supply them, so organisation and repository names stay out of this
  repository. An unknown group or a malformed file exits 64.
- **Related items.** An open issue or pull request in scope that references an
  issue or pull request in a repository outside the scope (a URL on either
  forge, or `OWNER/REPO#N` on the source's forge) pulls in that one item: one hop, at most five per
  source and `--related N` (30) per run, `0` to turn it off. Pulled-in items
  carry their state (open, closed, merged or unavailable) and the rows that
  pulled them in; they get no lane and do not count in the totals, and a
  source whose related item is closed or merged gets the flag
  `related-closed`. Related repositories are not triaged as a whole; that is
  what a group is for. A failed lookup marks the item `unavailable` rather
  than failing the run; GitHub items are skipped when GitHub is off or failed.
  A scoped repository that does not exist (HTTP 404) or is archived is listed
  as missing; other GitHub errors still mark GitHub failed.
- **Branch lane.** `--branches` adds remote branch rows for the repositories
  in scope: `merged` or `closed` when the latest pull request from the branch
  merged or closed, `no-pr` when no pull request ever used it and its last
  commit is `--branch-days` (30) old. Default and protected branches,
  `main`, `master`, `dev`, `dev-*`, `develop`, `gh-pages` and `renovate/*`
  are skipped, as are branches with any open pull request (they have a pull
  request row). At most 100 branches per repository are read, and the page
  names repositories with more (on GitHub also those with more than 100
  protected branches, which then add no rows); on Forgejo every pull request of a repository
  with candidate branches is read, since an old branch's pull request may be
  among the oldest.
- **Thorough mode** is the skill's opt-in on any scope; on all it first
  estimates how many items it would check and asks. It adds the branch lane, a
  checking pass and status refresh. The checking pass gives `refresh`,
  `unclear` and `keep` verdicts with concrete completion criteria to a
  `standard` worker that may run read-only `gh` and Forgejo queries across
  repositories (workflow runs, other repositories' issues and pull requests)
  and marks the verdicts it confirmed or changed as `checked`. Status refresh
  proposes exact replacement lines for confirmed `refresh` items and, once the
  user confirms, applies targeted edits instead of rewriting the body.
  Deleting a branch (verdict `delete`) stays a confirmed action, after
  checking that its commits landed elsewhere.
- **Unchanged.** The commands stay read-only, actions go to the item's own
  forge after confirmation, and live cluster or runtime checks stay out: a
  verdict says "needs live check" instead.

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
says "maybe done" and the skill checks before suggesting a close. Local
worktrees are left out of this inventory; the worktree audit below covers
them. Remote branches appear only in thorough mode. The Forgejo token cannot list organisations, so Forgejo scopes
cover the repositories `/user/repos` returns, and a Forgejo repository outside
that list is reported as missing from the scope.

- **Org-wide GitHub listing for groups:** less to maintain than a repository
  list, but one large organisation would swamp the inventory and the readers,
  and a group's members would change without review.
- **Pulling in every cross-reference:** fleet repositories link each other
  constantly, so the cap would fill with items already covered; only
  repositories outside the scope are invisible otherwise.

## Amendment 2026-10-16: local worktrees (#701)

Leftover Git worktrees across `~/src` were audited by hand in several passes.
Each pass rebuilt the same facts and hit the same traps:

- `git status` rewrites the index, so its mtime made every checkout look fresh.
- Squash merges defeat `git cherry`.
- A deleted branch turns a Forgejo pull request's head ref into
  `refs/pull/N/head`.
- Checkouts under `/tmp` lose tracked files to tmpfiles ageing.

`programs.ai` therefore also installs `worktree-audit`, used by a
`worktree-audit` skill in nix-secrets.

- **One row per linked worktree.** The command finds the main checkouts under
  a root (`~/src`, four levels) and lists their registered worktrees. Each row
  gets:
  - a kind: manual (`~/src/.worktrees`), tmp, T3 (any `~/.t3*/worktrees`),
    Claude (`.claude/worktrees`) or other;
  - uncommitted, untracked, deleted and ignored counts, where ignored entries
    a build recreates (such as `node_modules` or `result`) do not count as work;
  - unpushed commits and the upstream state;
  - idle days, from the newest of the HEAD commit and the files Git sees, never
    the index;
  - processes whose working directory is inside it, by command name only
    (from `/proc`; reported as unavailable where there is none, as on macOS);
  - its pull request and whether its work is in the base branch.
- **Containment by content.** HEAD is in the base when it is an ancestor, or
  when `git merge-tree` of the base and HEAD gives the base's own tree, which
  is how a squash merge looks. Otherwise the row reports how much would still
  land. When that merge conflicts, it reports HEAD's own changes since it
  forked instead.
- **Pull requests by head and branch.**
  - A pull request whose head is the worktree's HEAD wins. Otherwise the
    newest one from its branch wins; on Forgejo, the head label keeps the
    branch name after deletion.
  - Pull requests from long-lived branches (promotions from `dev`) never match.
  - Forgejo pull requests are listed by latest update. Listing goes on until
    every row has a head match, or a page is 30 days older than the oldest
    HEAD commit or branch creation among the rows still without one. Branch
    creation is when the branch's oldest reflog entry was written, if that
    entry records the creation (`branch: Created from`, `clone: from`). A
    branch whose creation entry has expired bounds nothing, so its repository
    is read up to the page cap; long-lived branches never match by name and
    bound by their commit. GitHub and Forgejo mirrors of GitHub use `gh`.
  - The Forgejo token is read as for `backlog-inventory`, and only remotes on
    the configured Forgejo hosts are looked up there.
- **One lane.** The lane is the first that applies, in this order:
  - `missing` (the directory is gone), `unreadable` (Git fails, or the
    `.git` file is gone while files remain, which is checked before Git
    could read a checkout around it instead), `in-use`, `damaged`
    (tmp with deleted files), `uncommitted`;
  - `merged-diverged` (its pull request merged with another head, often an
    earlier draft), `unpushed`, `open-pr`, `closed-pr`, `no-pr`;
  - `check-ignored` (done, but holding ignored files or moved submodules);
  - `removable`.

  The rows say whether T3 or Claude manages a worktree. The skill hands those
  to the owning application's lifecycle instead of removing them.
- **Changes since the last pass.** `--save` keeps a small snapshot (path,
  head, lane and pull request per worktree) in the XDG state directory. Every
  run reports the worktrees added, removed and changed against it.
- **Read-only.** It never removes, prunes or moves a worktree or changes a
  branch. `--fetch` runs `git fetch` with pruning, auto maintenance and auto
  gc explicitly off, since user configuration may turn them on and gc prunes
  worktrees. It lists live branches so that a deleted remote branch shows as
  gone. Each fetch times out after a minute without failing the run. Removal
  stays with the skill: only `git worktree remove`, only on the user's
  confirmation. It deletes ignored files without asking, so the skill
  rechecks them first.

The lanes are heuristics. `removable` means that nothing local is at risk:
the worktree is clean, holds nothing ignored that a build does not recreate,
and its work is in the base or in a merged pull request with the same head.
It does not mean the user is finished with it. A fresh worktree on the base
branch is also `removable`, so the skill weighs idle days. A worktree whose
branch was renamed, and whose head changed after the pull request, finds no
match and shows as `unpushed` or `no-pr`; the skill checks those by hand.
