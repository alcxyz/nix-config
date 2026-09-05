# ADR-0066: Use direct UMU launchers with a Heroic QA fallback

**Status:** Accepted, staged
**Date:** 2026-09-05
**Applies to:** `modules/home-manager`, `users/alc/linux/xyz.nix`, UMU, Proton, Battle.net, Heroic

## Context

Heroic successfully launches Battle.net and the Heroes Profile uploader, but it
adds a storefront UI, Flatpak boundary, and mutable launcher configuration to a
path that only needs to start known Windows executables. Adding Battle.net as a
non-Steam game would replace those layers with Steam's mutable shortcut and
compatibility-prefix management rather than removing them.

UMU exists to run Proton outside Steam while preserving the runtime behavior
Proton expects. A direct UMU launcher can therefore express the prefix, Proton
release, environment, executable, and lifecycle declaratively. The current
Heroic path is nevertheless a valuable working reference and rollback during
qualification.

## Decision

Add a reusable Home Manager module for declarative Windows applications run
through UMU. Pilot it on `xyz` with distinctly named direct-QA launchers for
Battle.net and the Heroes Profile uploader.

The pilot must:

- reuse the established compatibility prefix in place, without copying or
  migrating login, application, or game data;
- use the established Proton generation during QA so launcher migration and a
  Proton upgrade are not tested at the same time;
- reproduce the working graphics, frame-rate, timezone, and GameMode
  environment in declarative configuration;
- launch companion programs in the same prefix with Proton's same-prefix
  execution mode;
- use a user-service lifecycle so repeated primary-launch requests are
  idempotent and conflicting primary instances are refused rather than killed;
- keep Heroic and its existing entry unchanged throughout the QA period.

The direct entries must be visibly labelled as QA entries. Heroic remains the
fallback until the acceptance checks are complete and a separate decision
resolves its remaining applications. Prefix cleanup or relocation is outside
this decision.

## Alternatives Considered

- **Keep Heroic as the only launcher** — Viable, but retains a mutable
  storefront and Flatpak path for applications whose launch contract is known.
- **Add Battle.net to Steam** — Rejected because it adds Steam's client,
  shortcut state, and prefix conventions without improving the Windows runtime
  boundary.
- **Invoke Proton directly** — Rejected because upstream Proton expects its
  runtime integration; UMU is the supported non-Steam entry point.
- **Remove Heroic immediately** — Rejected because it would remove the known
  working rollback before cold launch, updates, companion behavior, and display
  recovery have been qualified.
- **Upgrade Proton during the migration** — Deferred so failures can be
  attributed to the launcher path rather than a simultaneous runtime change.

## Consequences

- Battle.net can be launched without opening Heroic or Steam.
- The existing prefix remains the single application-data location during QA.
- The direct and Heroic paths deliberately share that prefix, so only one
  primary path may run at a time.
- The pinned Proton release becomes a declarative dependency that must be
  updated explicitly after the launcher path is stable.
- Heroic continues to consume space and maintenance attention during the QA
  window.
- Cold launch, relaunch, application updates, local time, notifications,
  companion startup, focus, pointer confinement, workspace behavior, and
  display power transitions are required acceptance checks.

## Tracking

- Forgejo milestone: **Launcher-independent Windows applications on xyz**
- Issue #265 adds the reusable direct-UMU module.
- Issue #266 adds the Battle.net and Heroes Profile QA launchers.
- Issue #267 owns qualification against the established session behavior.
- Issue #268 decides whether Heroic remains, is disabled, or is removed after
  QA and after its other applications have replacements.
