# ADR-0078: Guard agent PR merges with automated cross-model reviews

**Status:** Accepted (amended 2026-10-01: `pr-review` command and head-pinned review comments; amended 2026-10-02: reviewers from the `deep` agent role, ADR-0079; amended 2026-10-03: follow-up reviews; amended 2026-10-03: `fj` merges, `tea` merges refused, and Forgejo MCP calls, ADR-0081; amended 2026-10-04: managed Codex hooks; amended 2026-10-04: guarded Forgejo MCP merges, ADR-0081; amended 2026-10-08: light reviewers for small documentation-only changes, and skipped reviews of already-reviewed promotions)
**Date:** 2026-10-01
**Applies to:** `modules/home-manager/programs/ai/`, `modules/nixos/security/agent-pr-review-guard/`, Claude Code and Codex CLI hooks

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
(ADR-0079) on each client, or the `light` role for small documentation-only
changes. Each runs sandboxed
without write or forge access and is given the diff and the PR description. The
agent addresses or justifies the findings, then posts one PR comment whose first
line is `Automated read-only review (<short head sha> on <target branch>):
<mode> (<role>): <outcome>`, where the mode is `full` or `follow-up to <short
sha>` and the role is `light` or `deep`. A trivial PR, or a promotion such as
`dev` to `main` whose every commit was already reviewed on its own PR, may
record `skipped (<reason>)` as the outcome, without a mode. Commits pushed
directly to the source branch, and conflict resolutions, still need a review.
Low-severity findings may be justified or tracked in an issue instead of fixed
with a new commit. Comments name no models and carry no signatures.

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
  recorded and must still match. Earlier rounds are kept. A failed or
  timed-out reviewer, or one whose reply lacks one of the requested verdicts, is
  reported as a missing review, never as no findings.
- A new head is reviewed as a **follow-up** of the last round that the
  configured reviewers, and only they, completed on the same target, when it
  descends from that round with the same merge base, at most 40 lines or 40%
  of the PR's changed lines changed since, no binary files changed, and fewer
  than three follow-ups ran in a row. Reviewers then get the findings of every
  round since the last full review, the author's `--response` as a claim to
  check, the interdiff to review, and the whole PR diff and checkout as
  context; they raise new findings in untouched code only if they are
  blocking. Otherwise, or with `--full`, `run` reviews the whole PR and says
  why; a missing earlier round also forces a full review, and the response is
  still passed on. `--force` repeats the head's previous mode. A result from a
  different reviewer set counts for no reviewer, and a round with another role
  forces a full review. Fix rounds then cost roughly what the fixes need, and fresh
  low-severity findings in unchanged code stop restarting the loop
  ([#524](https://git.alc.xyz/alcxyz/nix-config/issues/524)).
- `pr-review comment <pr> "<outcome>"` posts the comment for the current head,
  and refuses unless every reviewer completed for that head, except for skips.
- `pr-review check <pr>` reports whether a comment names the current head.

Reviewers are the `programs.ai.prReview.reviewers` option, which defaults to
the `deep` role's resolved models and efforts. `run` uses
`programs.ai.prReview.lightReviewers` instead, by default the `light` role on
both clients, when the PR's whole diff changes only documentation files
(`.md`, `.mdx`, `.rst`) and at most 300 lines. Agent rules and
instructions (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `SKILL.md`,
`copilot-instructions.md`), files in dot-directories such as `.github` or
`.claude`, `SECURITY.md`, decision records, paths naming secrets, security,
credentials, tokens, authentication, SOPS, keys, policy or prompts, binary
files and diffs whose paths cannot be read always get the deep reviewers, and
so does every PR when no light reviewers are configured. `--role deep` raises
the choice; nothing lowers it, so review depth cannot drop unnoticed. The
comment records the role used. The QA data
([#569](https://git.alc.xyz/alcxyz/nix-config/issues/569)) found that
reviews of small documentation changes found only low-severity wording
problems, and that re-reviewing promotions repeated their feature PRs'
reviews. `pr-review` never loads a role
profile, so its isolation is unchanged. A role can name a Claude alias, so each
result records the model the client reports (Claude's JSON result, Codex's
session header) alongside the configured one.

`programs.ai` installs `agent-pr-review-guard` as a `PreToolUse` hook for shell
commands in both clients. Claude receives it through the managed settings merge,
which now combines hook arrays instead of replacing them. Codex runs hooks
from `~/.codex/hooks.json` only after they are trusted in its `/hooks` view,
and skips them silently until then. On NixOS hosts,
`security.agentPrReviewGuard` therefore declares the hook in
`/etc/codex/requirements.toml`, where Codex trusts it by policy, pins hooks on,
and installs a script under its `managed_dir` that runs the calling user's
guard. For the module's `users`, a missing guard blocks every hooked call.
Other hosts keep the user `~/.codex/hooks.json`, which must be trusted once
per change to take effect. The guard recognises `gh pr merge`, GitHub `pulls/N/merge` API calls, Forgejo
REST merges and `fj pr merge`, and refuses `tea` merges. It blocks them unless a review comment names the PR's current head
commit and target branch, so new commits or a retargeted PR need a new review.
The comment's mode follows the pinned prefix, so older guards still accept it;
the guard does not check the chain of rounds, which `run` enforces from local
state when it selects a follow-up. It also blocks when it
cannot verify the comment, including when its lookups exceed a 90-second
deadline inside the 120-second hook timeout. The hook also matches Forgejo MCP
tools and checks `merge_pull_request` like other merges, from its structured
arguments (ADR-0081); other MCP tools pass. The guard and `pr-review` share one script.

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
- **Resuming the reviewers' earlier sessions for follow-ups:** conflicts with
  their ephemeral, isolated runs, and the earlier checkout is gone.
- **A follow-up time limit:** time alone does not make a follow-up wrong;
  changed reviewers do, and they force a full review.
- **Chaining follow-ups through posted comments, checked by the guard:** agents
  fix and push before commenting, so it would need a comment for every round.
- **A light triage pass choosing the role:** adds a model call to every
  review, and a misjudged triage would lower review depth unnoticed; path and
  size rules are cheap, predictable and fail towards `deep`.
- **One light reviewer for documentation:** cheaper still, but drops the
  cross-model check this decision exists for.
- **`pr-review` in nix-packages:** reusable tooling lives there, but the command
  is tied to this decision's comment format, guard and reviewer settings, so it
  stays next to the guard.

## Consequences

The guard targets agent sessions on hosts with `programs.ai`. It is an accident
guard, not a security boundary. An agent can still post a review comment by
hand, and web merges, other merge tools, indirect commands and
non-literal targets are not verified, GitHub Enterprise merges are blocked
because only github.com is supported, and a push between the guard's
lookup and the merge itself is not caught. Reviewers read the repository's
agent instructions from the PR head, so a PR that edits them can steer its own
review; such edits appear in the reviewed diff. Non-literal
targets, including `fj` merges without an explicit repository, are blocked
with guidance to use literal values. Forgejo lookups use
`FORGEJO_API_TOKEN_FILE` when the session provides it, send the token only to
the configured Forgejo URL, and do not follow redirects. Forge or network outages
block agent merges until the operator merges or the outage ends. Each review
adds model cost and latency to every agent PR, less for documentation-only
PRs. The light classification goes by path, so documentation that defines
policy without matching the deep patterns gets light reviewers unless the
agent passes `--role deep`. Comments in the earlier format
without a head SHA no longer satisfy the guard. Diffs over 400 kB are refused
rather than truncated. Where both the managed
and a trusted user hook exist, the guard runs twice per call, which is harmless.
A host that enables `security.agentPrReviewGuard` for a user without
`programs.ai` blocks that user's Codex shell and Forgejo MCP calls. The managed
hook entry cannot be disabled by the user, but the guard it runs comes from the
user's profile, which the user can replace. The managed hook also checks merges
through a hand-made Codex server named `forgejo`, and applies to
`pr-review`'s own Codex reviewers, which cannot complete merge lookups without
network access. The command is tracked in
[#512](https://git.alc.xyz/alcxyz/nix-config/issues/512).
