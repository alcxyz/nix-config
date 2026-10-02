# ADR-0080: Promote validated package revisions as a ref, lock them on demand

**Status:** Accepted
**Date:** 2026-10-02
**Applies to:** `scripts/ci/run-local-package-promotion.sh`, `modules/home-manager/services/nix-package-promotion/`, `modules/home-manager/services/t3code/`, `scripts/update-inputs/lock-promoted-packages.sh`, `packages/nix-deploy/`; amends ADR-0067 and ADR-0077

## Context

The local package promoter (ADR-0067) validated each new nix-packages `dev`
revision against the configuration and then committed the lock to
nix-config `dev`. That commit served two purposes: it was the authority the
T3 Code updater followed (ADR-0077), and it kept the configuration's lock
current for the next deployment.

nix-packages advances several times a day, mostly through the six-hourly T3
and provider scans. Each advance produced a
`chore(nix-packages): update lock to …` commit, often several in a row with no
other change in between: four to six a day at the end of September 2026. The
commits carry no review value and bury the configuration history. Hosts other
than the AI stack only pick up a new lock when they are deployed, so the
commits did not deliver anything sooner.

## Decision

The promoter publishes a validated revision by moving a branch in nix-packages,
`promoted`, which the T3 Code updater follows. It never commits to
nix-config.

- Each run compares the producer head with `promoted`. When they differ, it
  first ensures the current configuration head has its own receipt, then
  validates the producer against that head exactly as before (queue check,
  standalone and consumer verification, full configuration gate) and then moves `promoted` with a lease on its previous value. The
  queue and producer head are rechecked directly before the push. A
  configuration head that advanced during validation no longer defers the
  promotion: the ref publishes a package revision, not a configuration tree,
  and the new head is validated by its own run.
- When the committed lock already selects the producer, the configuration
  head's receipt covers the configuration gate; the promoter runs the
  standalone and consumer package verification and then moves `promoted`.
- Configuration heads still receive their `ci/local-configurations` receipt,
  which `main` promotion requires. A failing head records a failed receipt
  but does not stop validation of a producer that may fix it; the run still
  fails afterwards so the broken head stays visible.
- `t3code-auto-update` follows `promoted` directly through
  `autoUpdate.packageFlakeUri`, pinning its current revision for each run. The
  `promotionFlakeUri` option, which read the committed configuration lock, is
  removed.
- `just lock-packages` moves the nix-packages lock to `promoted`, never to an
  older revision, and leaves `flake.lock` to be reviewed and committed like any
  other change. The configured `deploy` wrapper only warns when the lock of the
  checkout it runs in differs from `promoted`; it never fails or changes the
  checkout.

## Alternatives Considered

- **Squash consecutive promotion commits by force-pushing `dev`** — keeps one
  commit between human commits, but rewrites a shared branch and conflicts
  every pull request and worktree based on the replaced commit.
- **Promote once a day** — reduces commits but also delays AI-stack updates,
  which are the reason for frequent promotion.
- **Commit to `dev` daily, or after nix-packages stays quiet** — still commits
  when nothing is deployed, and lets the lock lag a deployment anyway.
- **Filter the commits in `git log`** — hides the noise for one user and one
  command only.
- **Commit and push the lock automatically from `deploy`** — implemented and
  reviewed first. Publishing from a deployment needed rollback for failed,
  interrupted and unconfirmed pushes and for concurrent edits of the checkout,
  and each review round found another case. An explicit command keeps lock
  commits deliberate with none of that machinery.
- **Restrict pushes to `promoted` with branch protection** — the promoter and
  interactive agent work push as the operator account, and the package update
  automation's credential is not known to be separate, so a rule could not
  reliably separate them and could get in the way of agent work. The
  previous authority, nix-config `dev`, has the same exposure.

## Consequences

- nix-config history gains a package lock commit only when someone runs
  `just lock-packages` and commits the result, typically before deploying.
  AI-stack updates still arrive after each scan.
- nix-config `dev`'s lock lags `promoted` between those commits; `deploy`
  says so. A lock combined with a newer configuration head was validated
  against an older head; the next promoter run validates the new head, as for
  any `dev` commit.
- Unattended AI-stack updates trust whatever `promoted` points to. Any
  credential that can push to nix-packages can move it, as such credentials
  could already change nix-config `dev`. Separate push identities would allow
  branch protection later.
- A `dev` head that fails because of a package problem no longer recovers on
  its own when nix-packages fixes it: the fix only moves `promoted`, and the
  head keeps failing (and is revalidated each run) until someone commits
  `just lock-packages`. The failed run and receipt make this visible.
- `deploy` looks up `promoted` before each run, bounded to five seconds when
  the forge is slow or unreachable.
- When the producer and the configuration head both changed, a run validates
  the head and the candidate separately, so it can take up to two full
  configuration gates.
- The promoter needs push access to the nix-packages `promoted` branch through
  the operator's native Git credentials. Moving a ref adds no commits, and
  nix-packages workflows do not run on pushes to it.
