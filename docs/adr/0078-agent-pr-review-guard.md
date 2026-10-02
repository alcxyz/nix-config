# ADR-0078: Guard agent PR merges with automated cross-model reviews

**Status:** Accepted (amended 2026-10-01: `pr-review` command and head-pinned review comments; amended 2026-10-02: reviewers from the `deep` agent role, ADR-0079)
**Date:** 2026-10-01
**Applies to:** `modules/home-manager/programs/ai/`, Claude Code and Codex CLI user hooks

## Context

Agents create and merge pull requests on Forgejo and GitHub. A read-only review
of a WAF exception by a second model found a scope problem that the authoring
agent had missed. Asking for such reviews only in agent instructions does not
ensure they happen: agents can forget, or judge a change too small to review.

Pull requests and comments must not carry AI co-author trailers or tool
signatures. Reviews still need a visible, honest record that colleagues will
not mistake for a human review.

## Decision

Before an agent merges a PR it created, it obtains independent read-only
reviews from a Codex and a Claude reviewer, by default the `deep` agent role
(ADR-0079) on each client. Each runs sandboxed
without write or forge access and is given the diff and the PR description. The
agent addresses or justifies the findings, then posts one PR comment whose first
line is `Automated read-only review (<short head sha> on <target branch>):
<outcome>`. A trivial PR
may record `skipped (<reason>)` as the outcome. Comments name no models and
carry no signatures.

`programs.ai` installs `pr-review`, so agents do not assemble the reviews by
hand or depend on which models their own client offers:

- `pr-review run <pr>` fetches the PR's head and target branch into the local
  clone with repository hooks disabled, builds the diff locally with the target
  branch's attributes (a forge's diff can lag behind a push, and the PR's own
  `.gitattributes` must not hide changes), writes the head's files to a temporary directory from
  raw objects (no hooks, filters or symbolic links), and runs the reviewers in
  parallel with the diff and PR description. One run per PR head at a time.
  Codex runs in its read-only sandbox without network access, user
  configuration, saved command rules, MCP servers or app connectors. Claude Code runs in restricted
  mode with only the Read, Grep and Glob tools, without MCP servers, and
  ignoring user and project settings. Reviewers do not inherit forge token
  variables, but can read local files, including stored credentials, without
  network access. Results and a status per reviewer,
  including its model and effort, are kept per head SHA; the target branch is
  recorded and must still match. A failed or
  timed-out reviewer, or one whose reply lacks one of the requested verdicts, is
  reported as a missing review, never as no findings.
- `pr-review comment <pr> "<outcome>"` posts the comment for the current head,
  and refuses unless every reviewer completed for that head, except for skips.
- `pr-review check <pr>` reports whether a comment names the current head.

Reviewers are the `programs.ai.prReview.reviewers` option, which defaults to
the `deep` role's resolved models and efforts. `pr-review` never loads a role
profile, so its isolation is unchanged. A role can name a Claude alias, so each
result records the model the client reports (Claude's JSON result, Codex's
session header) alongside the configured one.

`programs.ai` installs `agent-pr-review-guard` as a `PreToolUse` hook for shell
commands in both clients. Claude receives it through the managed settings merge,
which now combines hook arrays instead of replacing them. Codex receives a
managed `~/.codex/hooks.json`, which Codex loads alongside other hook sources.
The guard recognises `gh pr merge`, GitHub `pulls/N/merge` API calls, and Forgejo
REST merges. It blocks them unless a review comment names the PR's current head
commit and target branch, so new commits or a retargeted PR need a new review. It also blocks when it
cannot verify the comment, including when its lookups exceed a 90-second
deadline inside the 120-second hook timeout. The guard and `pr-review` share one script.

Cost is tracked during an initial QA period before the requirement is
reconsidered ([#506](https://git.alc.xyz/alcxyz/nix-config/issues/506)).

## Alternatives Considered

- **Instruction only:** cheapest, but nothing catches a missed review.
- **Forge-side required check:** anyone can post the comment. It would also
  need organization agreement for GitHub repositories the operator does not own.
- **A `gh` wrapper for all users:** would also cover manual merges, which are
  out of scope, and could not cover Forgejo REST calls or web merges.
- **A single fixed reviewer:** a model would review its own work when it is
  also the author.
- **`pr-review` in nix-packages:** reusable tooling lives there, but the command
  is tied to this decision's comment format, guard and reviewer settings, so it
  stays next to the guard.

## Consequences

The guard targets agent sessions on hosts with `programs.ai`. It is an accident
guard, not a security boundary. An agent can still post a review comment by
hand, and web merges, other merge tools (`tea`, `fj`), indirect commands and
non-literal API targets are not verified, GitHub Enterprise merges are blocked
because only github.com is supported, and a push between the guard's
lookup and the merge itself is not caught. Reviewers read the repository's
agent instructions from the PR head, so a PR that edits them can steer its own
review; such edits appear in the reviewed diff. Non-literal
targets are blocked with guidance to use literal values. Forgejo lookups use
`FORGEJO_API_TOKEN_FILE` when the session provides it, send the token only to
the configured Forgejo URL, and do not follow redirects. Forge or network outages
block agent merges until the operator merges or the outage ends. Each review
adds model cost and latency to every agent PR. Comments in the earlier format
without a head SHA no longer satisfy the guard. Diffs over 400 kB are refused
rather than truncated. The command is tracked in
[#512](https://git.alc.xyz/alcxyz/nix-config/issues/512).
