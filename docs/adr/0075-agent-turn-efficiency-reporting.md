# ADR-0075: Measure agent turn efficiency with a skill and read-only reporter

**Status:** Proposed
**Date:** 2026-09-26
**Applies to:** agent skills, usage reporting, Home Manager integration

## Context

Our global agent instructions encourage delegation to cheaper capable models
without reducing quality. Seeing that a helper used a cheaper model does not
show whether delegation saved resources: parent coordination, copied context,
retries, and rework also contribute. We want useful feedback during a turn and
an auditable report afterward, without making reporting itself expensive.

The current T3 Code workflow does not provide the desired per-turn breakdown
across the parent and its helpers. A skill can guide reporting, but cannot
create missing telemetry or guarantee automatic invocation.

## Decision

Propose a Codex-only pilot: a `turn-efficiency` skill calls a deterministic,
read-only reporter against locally available usage metadata. Validate turn and
child-session attribution before treating totals as reliable. Keep the existing
global instructions as the model-selection policy; the skill explains when and
how to report, rather than duplicating that policy.

The report should distinguish measured usage, estimates, and unknowns:

- Attribute input, cached-input, and output tokens to the parent and helpers by
  model, with reasoning effort and a short task label when available.
- Identify the exact turn and relevant child-session intervals. Account for
  reused helpers, copied fork history, repeated events, and model switches;
  report incomplete or ambiguous attribution instead of inventing precision.
- Estimate API-equivalent cost only with identifiable, dated pricing and clear
  cache accounting. Unknown prices remain unknown. This is not a subscription
  bill or a measurement of actual money charged.
- Show parent overhead and evidenced retries or escalations alongside validation
  outcomes and known rework. Any comparison with an all-expensive-model run is
  hypothetical, not proof of savings or equal quality.

Report on request, at useful milestones, and concisely at completion. Avoid
continuous polling and extra model calls for accounting. In-progress reports
are provisional; usage for the final response requires a later read. Bound
scanning and output so the reporting overhead remains proportionate.

Process telemetry locally and emit only allowlisted accounting metadata. Do
not expose transcript text, tool payloads, credentials, or private paths in
reports or public fixtures. Real session data remains local and uncommitted.

Keep this public decision and non-secret skill configuration in `nix-config`.
Place reusable reporting tooling in `nix-packages`, following
[ADR-0028](0028-agent-instruction-sync-check.md), and deploy through Home Manager
following [ADR-0030](0030-declarative-shared-user-policy-configs.md). Any required
private defaults or wiring belong in `nix-secrets`; no private changes are
needed merely to document the proposal. Preserve the canonical instruction
ownership established by [ADR-0022](0022-universal-agent-instructions.md).

Implementation and qualification are tracked in [issue #454](https://git.alc.xyz/alcxyz/nix-config/issues/454). This
ADR does not install a skill, change delegation policy, or enable tracking.

## Alternatives Considered

- **Narrative reports from the agent alone:** easy to start, but cannot provide
  trustworthy token totals or costs and can omit coordination overhead.
- **Implement the T3 UI first:** could provide automatic live visibility, but
  adds fork maintenance before attribution and usefulness are established.
  Reconsider after the pilot proves the reporting contract.
- **Use aggregate usage dashboards:** useful for broader trends, but cannot
  explain the parent/helper contribution to a particular turn.
- **Support every provider initially:** broad coverage would delay validation
  of the core attribution model. Add adapters after the Codex pilot qualifies.

## Consequences

The pilot can provide evidence for delegation decisions without expanding the
T3 fork. Provider metadata may be incomplete or change format, so fixtures,
explicit coverage indicators, and conservative failure behavior are required.
A skill remains invocation-dependent; reliable always-on reporting would need
separate runtime integration. Cost estimates alone cannot establish preserved
quality, and observational reports cannot prove counterfactual savings.
