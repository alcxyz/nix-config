# ADR-0077: Update the AI stack in its own profile, outside Home Manager

**Status:** Accepted
**Date:** 2026-09-30
**Amended:** 2026-10-29
**History:** [replaced text](archive/0077-ai-stack-profile-outside-home-manager-history.md)
**Applies to:** `modules/home-manager/services/t3code/`, nix-packages `ai-stack-*` outputs

## Context

T3 Code and the AI provider CLIs (Claude Code, Codex CLI, Codex app-server)
release several times a day and were then promoted hourly under
nix-packages ADR-0007. `t3code-auto-update` used to deliver them by rebuilding and
activating the whole Home Manager generation from the configuration snapshot
baked into the active generation, overriding only the `nix-packages` input.

That coupled a small, frequently changing package set to everything else in
Home Manager. On 2026-09-30 xyz's system moved to a newer nixpkgs while the
snapshot stayed on an older one. The hourly updater kept re-activating
Home Manager userspace built against glibc 2.42, which could not load the
system's Mesa built against glibc 2.43. hyprlock, Brave, and after a reboot
Hyprland itself failed. The manual deploy that would have refreshed the
snapshot was failing for an unrelated package, so the drift went unnoticed
(nix-config #499).

## Decision

Deliver the AI stack through a dedicated Nix profile,
`~/.local/state/nix/profiles/ai-stack`, that unattended updates can replace
without running Home Manager activation.

- nix-packages exports the `ai-stack-upstream` bundle. It contains the T3
  wrapper, which pins its providers, plus `claude-code`, `codex-cli` and
  `codex-app-server` for interactive use. Only the upstream channel is
  managed: the T3 Code fork channels were retired on 2026-10-08 (nix-packages
  ADR-0005). With the profile the channel is read from the bundle's
  `ai-stack-<channel>` store name; hosts without the updater record it in the
  channel state file. Moving off a retired fork channel counts as a channel
  change, not a downgrade.
- `t3code-auto-update` follows the nix-packages branch moved by local package
  promotion, normally `promoted` ([ADR-0080](0080-promoted-package-ref.md)),
  pins its current revision for each run, builds the bundle into the profile,
  and restarts `t3code.service` only through the idle-session and downgrade
  guards. It never activates Home Manager.
- Home Manager keeps the stable parts: the service unit (which runs
  `<profile>/bin/t3`), provider settings, and the profile on `PATH`. Activation
  seeds the profile from Home Manager's own locked nix-packages only when the
  profile is missing or the selected channel changed; it never replaces a
  profile the updater has moved forward.
- Home Manager activation never restarts T3 for a package update. A change to
  the service's command line (for example the session environment wrapper
  from #689) does need a restart: activation then writes the restart marker
  without blocking, and the apply step restarts the running instances once
  the idle guard allows it, or at a later activation.
- Hosts without the updater keep installing these packages through Home
  Manager.

## Alternatives Considered

- **Keep the snapshot and pin its nixpkgs to the running system**: removes the
  glibc skew but still rebuilds and switches all of Home Manager on every
  update. An old
  configuration can also stop evaluating against a newer nixpkgs.
- **Track the promoted nix-config `dev` revision in full**: turns the update
  timer into an unattended Home Manager deploy of unreviewed configuration.
- **Deploy Home Manager as a NixOS module**: keeps system and Home Manager in
  step, but does nothing for fast provider delivery and restructures every host.
- **A separate repository for the AI stack**: nix-packages already provides
  isolated packaging, CI, and promotion. Another lock and promotion step adds
  cost without isolating anything further.

## Consequences

Unattended updates touch only the AI stack and cannot change the desktop,
drivers, or other Home Manager programs. The update timer runs daily at 04:00
with up to 30 minutes of randomized delay by default; xyz's private
configuration runs it hourly at minute 45 with up to 10 minutes of delay. The bundle is self-contained, so its nixpkgs
does not need to match the system: none of its programs load system graphics
drivers. The profile keeps its own generations, so
`nix-env --profile ~/.local/state/nix/profiles/ai-stack --rollback` undoes a bad
update.

The profile participates in the guarded generation retention from
[ADR-0013](0013-safe-nix-gc-no-generation-deletion.md). Its rollback history is
bounded by the same validation, count and free-space triggers as other managed
profiles; frequent unattended updates must not retain every historical bundle.

Other nix-packages tools (Ghostty, Zen and so on) update only when Home
Manager is deployed, instead of riding along with provider updates. The
running AI versions can differ from what a fresh Home Manager build would seed;
the updater and its downgrade guard own the profile after seeding. The
nixpkgs skew guard (6c42f109) that refused activation across a skew was
removed with the snapshot activation it protected. The macOS host does not use
the profile: it installs T3 Code as the `t3-code@nightly` Homebrew cask, which
nix-darwin activation upgrades.
