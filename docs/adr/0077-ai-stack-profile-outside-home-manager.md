# ADR-0077: Update the AI stack in its own profile, outside Home Manager

**Status:** Accepted; the updater follows the nix-packages `promoted` branch since [ADR-0080](0080-promoted-package-ref.md)
**Date:** 2026-09-30
**Amended:** 2026-10-08, the T3 Code fork channels were retired (nix-packages ADR-0005)
**Applies to:** `modules/home-manager/services/t3code/`, nix-packages `ai-stack-*` outputs

## Context

T3 Code and the AI provider CLIs (Claude Code, Codex CLI, Codex app-server)
release several times a day and are promoted hourly under nix-packages
ADR-0007. `t3code-auto-update` delivered them by rebuilding and activating the
whole Home Manager generation from the configuration snapshot baked into the
active generation, overriding only the `nix-packages` input.

That coupled a small, frequently changing package set to everything else in
Home Manager. On 2026-09-30 xyz's system moved to a newer nixpkgs while the
snapshot stayed on an older one. The hourly updater kept re-activating
Home Manager userspace built against glibc 2.42, which could not load the
system's Mesa built against glibc 2.43. hyprlock, Brave, and after a reboot
Hyprland itself failed. The manual deploy that would have refreshed the
snapshot was failing for an unrelated package, so the drift went unnoticed
(nix-config #499). A stop-gap guard (6c42f109) refuses activation across a
nixpkgs skew but leaves updates stalled until someone deploys Home Manager.

## Decision

Deliver the AI stack through a dedicated Nix profile,
`~/.local/state/nix/profiles/ai-stack`, that unattended updates can replace
without running Home Manager activation.

- nix-packages exports the `ai-stack-upstream` bundle. It contains the T3
  wrapper, which already pins its providers, plus `claude-code`, `codex-cli`
  and `codex-app-server` for interactive use.
- `t3code-auto-update` resolves the promoted nix-packages revision as before,
  builds the selected bundle into the profile, and restarts `t3code.service`
  only through the existing idle-session and downgrade guards. It never
  activates Home Manager.
- Home Manager keeps the stable parts: the service unit (which runs
  `<profile>/bin/t3`), provider settings, and the profile on `PATH`. Activation
  seeds the profile from Home Manager's own locked nix-packages only when the
  profile is missing or the selected channel changed; it never replaces a
  profile the updater has moved forward.
- Hosts without the updater keep installing these packages through Home
  Manager as before.

## Alternatives Considered

- **Keep the snapshot and pin its nixpkgs to the running system** — removes the
  glibc skew but still rebuilds and switches all of Home Manager hourly. An old
  configuration can also stop evaluating against a newer nixpkgs.
- **Track the promoted nix-config `dev` revision in full** — turns the hourly
  timer into an unattended Home Manager deploy of unreviewed configuration.
- **Deploy Home Manager as a NixOS module** — keeps system and Home Manager in
  step, but does nothing for fast provider delivery and restructures every host.
- **A separate repository for the AI stack** — nix-packages already provides
  isolated packaging, CI, and promotion. Another lock and promotion step adds
  cost without isolating anything further.

## Consequences

Hourly updates touch only the AI stack and can no longer change the desktop,
drivers, or other Home Manager programs. The bundle is self-contained, so its
nixpkgs does not need to match the system: none of its programs load system
graphics drivers. The profile keeps its own generations, so
`nix-env --profile ~/.local/state/nix/profiles/ai-stack --rollback` undoes a bad
update.

Other nix-packages tools (Ghostty, Zen, Helium, and so on) now update only when
Home Manager is deployed, instead of riding along with provider updates. The
running AI versions can differ from what a fresh Home Manager build would seed;
the updater and its downgrade guard own the profile after seeding. The skew
guard from 6c42f109 is removed with the snapshot activation it protected. The
macOS host keeps its existing update mechanism until it gets the same split.
