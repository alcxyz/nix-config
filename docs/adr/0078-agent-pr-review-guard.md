# ADR-0078: Guard agent PR merges with automated cross-model reviews

**Status:** Accepted
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
reviews from `gpt-6.1-sol` (high) and Claude Opus 5.5 (high). Each runs sandboxed
without write or forge access and is given the diff and the PR description. The
agent addresses or justifies the findings, then posts one PR comment whose first
line starts with `Automated read-only review:` and states the outcome. A trivial
PR may record `Automated read-only review: skipped (<reason>).` Comments name
no models and carry no signatures.

`programs.ai` installs `agent-pr-review-guard` as a `PreToolUse` hook for shell
commands in both clients. Claude receives it through the managed settings merge,
which now combines hook arrays instead of replacing them. Codex receives a
managed `~/.codex/hooks.json`, which Codex loads alongside other hook sources.
The guard recognises `gh pr merge`, GitHub `pulls/N/merge` API calls, and Forgejo
REST merges. It blocks them unless the PR has the review comment, and also
blocks when it cannot verify the comment.

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

## Consequences

The guard targets agent sessions on hosts with `programs.ai`. It is an accident
guard, not a security boundary: web merges, other merge tools (`tea`, `fj`),
indirect commands and non-literal API targets are not verified. Non-literal
targets are blocked with guidance to use literal values. Forgejo lookups use
`FORGEJO_API_TOKEN_FILE` when the session provides it. Forge or network outages
block agent merges until the operator merges or the outage ends. Each review
adds model cost and latency to every agent PR.
