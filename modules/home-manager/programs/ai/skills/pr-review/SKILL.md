---
name: pr-review
description: Review a pull request you created with `pr-review` before merging it, record the outcome, and handle fix rounds, skips and failed reviewers. Use when a PR you opened is ready for review or merge, when `pr-review` reports findings or a failed reviewer, or when the PR review guard blocks a merge.
---

# PR review

Before an agent merges a PR it created, independent read-only reviewers on
both clients review it, and the agent records the outcome in one PR comment.
`pr-review` runs the reviewers itself, so a model missing from your own client
is no reason to skip. A hook blocks agent merges until a comment names the
PR's current head and target branch (nix-config ADR-0078). This skill is the
full procedure; the global rules keep only the requirement.

## 1. Run

Once the PR is ready, start the review as an ordinary background command from
any clone of the PR's repository:

```sh
pr-review run <pr>
```

- `<pr>` is a PR number, resolved through `origin` (`--remote <name>` for
  another remote), or a GitHub or Forgejo PR URL.
- It takes several minutes. Do not use `agent-job` for it: you wait on it in
  this session.
- It picks the reviewers from the diff: a PR that only changes documentation
  files (`.md`, `.mdx`, `.rst`), at most 300 lines, gets the `light`
  reviewers; agent instructions, decision records and security-sensitive paths
  always get the `deep` ones. Pass `--role deep` when light-looking
  documentation defines policy or procedure. Nothing lowers the role.
- A head that was already reviewed is not reviewed again; `--force` repeats it
  and `--full` reviews the whole PR instead of only the fixes.

## 2. Findings

Read each reviewer's verdict and findings, then address or justify every
finding:

- Fix blocking findings.
- Fix low-severity findings and small cleanups in the PR before merging. Track
  one in an issue only when it needs a real decision or substantial work, and
  link that issue in the outcome.
- Fixes to your own work that follow from an agreed decision need no separate
  permission. The global consent rules and the rule against changing others'
  work still apply.

## 3. Fix rounds

Every new head needs its own review: pushed fixes, commits pushed directly to
the source branch, a rebase, a conflict resolution and a retargeted PR alike.
After pushing fixes, run:

```sh
pr-review run <pr> --response "<what was fixed or justified>"
```

When the new head builds on the last completed round with the same merge base,
the fixes are small (at most 40 lines or 40% of the PR's changed lines,
whichever is larger, and no binary files) and fewer than three follow-ups ran
in a row, the reviewers check only the fixes and your response, and raise new
findings in untouched code only if they are blocking. Otherwise `run` reviews
the whole PR and says why.

## 4. Record

Post the outcome for the current head:

```sh
pr-review comment <pr> "<outcome>"
```

- `comment` writes the prefix (head, target, mode and role) itself and refuses
  until every reviewer completed for the current head.
- Keep the outcome to one line, for example `no blocking findings.`, or
  `low-severity findings fixed; one justified (<why>).`
- `skipped (<reason>)` only for a trivial PR, or a promotion such as `dev` to
  `main` whose every commit was already reviewed on its own PR. A promotion
  that carries direct pushes or a conflict resolution needs a review.
- Name no models and add no signatures.

Then merge with `gh pr merge`, `fj pr merge owner/repo#N` or the Forgejo MCP
`merge_pull_request`, using literal repository and PR values. The guard
refuses `tea` merges.

## 5. Failures

- **A failed, timed-out or incomplete reviewer** is a missing review, never "no
  findings". It is not a reason to skip: fix the cause if it is yours, otherwise
  run `pr-review run <pr>` again once the reviewer recovers; it re-runs an
  incomplete head without `--force`.
- **Another run already reviewing the head**: wait for it rather than starting
  a second one.
- **The diff exceeds 400 kB**: split the PR, or ask the operator.
- **The guard blocks a merge it cannot verify** (forge or network outage, a
  lookup timeout): ask the operator instead of working around it. If it asks
  for literal values, repeat the merge with the repository and PR number
  spelled out.

## Delegated threads

When work is split across threads, each thread reviews its own PR this way and
reports the PR, the review outcome and its validation to the launching thread.

## Reference

`pr-review --help` lists every option; nix-config ADR-0078 records the design.
