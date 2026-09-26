# ADR-0075: Start with short model-usage summaries in T3 Code

**Status:** Proposed
**Date:** 2026-09-26
**Applies to:** T3 Code usage visibility, agent reporting, optional skill deployment

## Context

Global agent instructions encourage cheaper capable helpers without reducing
quality. We want to see whether those rules influence actual work and help us
use our subscriptions well. A short account of which models handled which
tasks can already be useful; precise cost accounting is not a prerequisite.

T3 Code already represents subagent model, effort, task status, and optional
usage. Upstream [PR #9132](https://github.com/pingdotgg/t3code/pull/9132) merged
main-agent per-turn token accounting. Open
[PR #9016](https://github.com/pingdotgg/t3code/pull/9016) proposes thread and
subagent usage breakdowns. The composer-cost proposal
[PR #9136](https://github.com/pingdotgg/t3code/pull/9136) closed without merging.
These statuses were checked on 2026-09-26; none promises a delivery date or a
complete live parent/helper turn summary.

## Decision

Start with a lightweight reporting trial inside the existing T3 conversation.
On request or at the end of meaningful delegated work, provide a few lines:

- Scope: this turn, or a clearly identified session interval.
- Models and roles: parent model, helper models, and brief tasks handled.
- Usage: reported tokens or token shares only when available and comparable
  within that scope; otherwise say counts are unavailable or partial.
- Outcome: validation result and any observed retry, escalation, or rework.

Use existing agent execution information and T3 data available through supported
interfaces. Distinguish requested models from confirmed execution when needed.
Do not introduce transcript scanning, a database, polling, pricing maintenance,
or extra model calls for the first trial. Missing numbers must not prevent a
useful task-based summary, and historical helpers must not be counted as work
performed in the current turn. Do not invent percentages of work from task
counts, duration, or tokens: token share describes token usage, not task value.

Evaluate a few real turns before building anything. Include both delegated work
and a small task deliberately kept with the parent. Check whether the summaries
help identify appropriate delegation, unnecessary overhead, or repeated rework.
If they are useful but inconsistent, package the reporting convention as a thin
skill. Preserve the existing global delegation policy rather than copying it.

Native automatic visibility belongs in T3 Code. Assess upstream #9016 and the
existing turn accounting before proposing the smallest missing integration.
`nix-config` owns this adoption decision and any optional skill/config deployment,
not T3's accounting or UI. Reusable tooling belongs in `nix-packages` only if a
specific unmet need justifies it. Private wiring, if needed, belongs in
`nix-secrets`. This follows [ADR-0022](0022-universal-agent-instructions.md),
[ADR-0028](0028-agent-instruction-sync-check.md), and
[ADR-0030](0030-declarative-shared-user-policy-configs.md).

[Issue #454](https://git.alc.xyz/alcxyz/nix-config/issues/454) tracks the trial
and remaining evaluation. No installed skill or automatic tracking is implied.

## Alternatives Considered

- **Build a standalone usage reporter first:** deferred; duplicates upstream
  accounting and introduces attribution maintenance before proving usefulness.
- **Implement a native dashboard now:** deferred; first evaluate the existing
  data and overlapping upstream work against the short-summary need.
- **Wait for complete accounting:** rejected for the trial; task/model summaries
  offer immediate, limited insight with little overhead.

## Consequences

We can start learning without another maintained subsystem. A conversational
summary depends on available evidence and invocation; it is not an audited
ledger. Session reports may have less reliable coverage than the current turn.
Provider counters can include inherited history or different scopes, so unknown
or incomparable counts remain explicit rather than being summed blindly.

Model/task summaries show whether routing rules are followed. They do not prove
cost savings, equal quality, or improved subscription headroom. Subscription
limits need not be proportional to raw token counts; API-equivalent prices are
not subscription charges. Keep monetary estimates and hypothetical savings out
of the initial trial. Keep real session data local and out of public fixtures.
