# ADR-0013: Safe Nix GC with guarded generation retention

**Status:** Accepted (amended 2026-08-26, 2026-09-30)
**Date:** 2026-04-18
**Applies to:** all managed NixOS and nix-darwin hosts, Home Manager profiles, `nix.gc`

## Context

On 2026-04-18, a nix store corruption event left the Mac host unbootable from a nix perspective: `darwin-rebuild`, `claude`, `home-manager`, `npm`, `git`, `kanata`, and many foundational store paths (`coreutils`, `gnugrep`, `gnused`, `jq`) were missing or corrupted. Dozens of binaries in both `/run/current-system/sw/bin/` and `~/.nix-profile/bin/` became broken symlinks. Recovery required SSHing in and manually running `nix store repair` on individual store paths, then rebuilding both the system and home-manager profiles.

The GC was configured with `--delete-older-than 30d`, which first deletes profile generations older than 30 days, then garbage-collects the newly-unreferenced store paths. This two-step process is inherently fragile: if the GC daemon's view of GC roots diverges from reality (e.g. home-manager profiles under `~/.local/state/nix/profiles/` not being fully traversed, or stale auto-roots under `/nix/var/nix/gcroots/auto/`), active store paths can be collected.

Whether the root cause this time was the GC itself or a store consistency issue during rapid rebuilds (10 system + 8 home-manager activations in one day) is uncertain. What is certain is that `--delete-older-than` amplifies the blast radius of any such event by actively removing the profile generations that would otherwise serve as recovery anchors.

## Decision

Ordinary automatic GC must never delete profile generations. Use
`--max-freed <size>` instead of `--delete-older-than <duration>`.

```nix
nix.gc = {
  automatic = true;
  interval = { Hour = 2; Minute = 0; };  # NixOS: dates = "daily"
  options = "--max-freed 10G";
};
```

Generation retention is a separate, guarded prerequisite of automatic GC. It
checks the system profile and the configured managed user's Home Manager and
user profiles. Retention triggers when any profile exceeds 20 generations or
when the Nix filesystem has less than 15% free. Hosts may lower the retained
count with `alc.nix.keepGenerations` (default 10); the trigger stays at twice
that count. Small, rarely changed SD-card hosts keep 3. When triggered, it validates
every current profile closure before pruning profiles back to the latest 10
generations. Any validation failure aborts retention and the dependent GC.

On NixOS, the retention service is a required predecessor of `nix-gc.service`.
On nix-darwin, a root launchd job runs retention shortly before the existing
calendar-based GC. Retention never collects store paths; ordinary GC remains a
separate operation capped at 10 GiB per run.

Scheduled GC runs daily so the per-run cap keeps pace with build churn. As a
backstop, every host sets `min-free = 10 GiB` and `max-free = 50 GiB`: when
free space falls below `min-free` during a build or substitution, Nix collects
dead paths until `max-free` is available. Neither path deletes generations.

Stale project roots are cleaned separately. A daily Home Manager job on
workstation profiles removes the user's own `result*` and nix-direnv root
links whose symlink is older than 30 days. It never touches profiles or tool
state roots under `~/.local/state` and `~/.cache`; nix-direnv recreates its
roots the next time a project loads.

The shared `nix-gc-maintenance` command remains the explicit override. It
retains the latest 10 generations in the invoking user's Home Manager and user
profiles, retains the latest 10 system generations, then performs one GC pass
capped at 10 GiB. Run it through `just gc` from the repository or directly on
any managed host. From the operator checkout on `xyz`, `just gc <host>` streams
the same command over the managed SSH connection; the target does not need the
new package installed first.

The command must be run once for each user with a standalone Home Manager
profile. Home Manager configurations integrated into a NixOS system generation
are retained with that system generation.

## Alternatives Considered

- **Keep `--delete-older-than` with a longer window (90d, 180d)** — reduces frequency but doesn't eliminate the risk. Still deletes generations automatically.
- **Prune to 10 before every GC** — bounds generations tightly but removes rollback anchors after bursts of otherwise harmless rebuilds. The 20-to-10 hysteresis avoids unnecessary churn.
- **Keep generation retention manual-only** — safest for rollback history, but allows forgotten maintenance to exhaust a store. Guarded retention preserves 10 validated generations instead.
- **Disable automatic GC entirely** — safest, but requires manual disk management. Unnecessary given `--max-freed` exists.
- **Use `min-free` / `max-free` nix settings alone** — these trigger GC during builds when free space drops below a threshold. Adopted as a complement in the 2026-09-30 amendment, but not a replacement for scheduled GC.
- **Keep the weekly schedule and raise or remove the cap** — would also clear the backlog, but changes the per-run bound this decision chose. A daily run keeps the bound while multiplying throughput.

## Consequences

- On 2026-09-30, a build host had about 94 GiB of dead paths because every weekly run stopped at the 10 GiB cap; daily runs and the `min-free` backstop prevent that backlog.
- Generation count can grow to 20 without churn, but low free space triggers retention earlier.
- Validation is fail-closed: a broken current profile prevents both automatic pruning and its dependent NixOS GC.
- Ten generations are retained consistently across NixOS, nix-darwin, Home Manager, and user profiles.
- Recovery from future store corruption is easier: old generations remain as GC roots, so rolling back with `nix-env --rollback` or `darwin-rebuild switch --rollback` remains possible.
