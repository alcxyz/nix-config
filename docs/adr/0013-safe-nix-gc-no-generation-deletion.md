# ADR-0013: Safe nix GC — never auto-delete profile generations

**Status:** Accepted (amended 2026-08-26)
**Date:** 2026-04-18
**Applies to:** all managed NixOS and nix-darwin hosts, Home Manager profiles, `nix.gc`

## Context

On 2026-04-18, a nix store corruption event left the Mac host unbootable from a nix perspective: `darwin-rebuild`, `claude`, `home-manager`, `npm`, `git`, `kanata`, and many foundational store paths (`coreutils`, `gnugrep`, `gnused`, `jq`) were missing or corrupted. Dozens of binaries in both `/run/current-system/sw/bin/` and `~/.nix-profile/bin/` became broken symlinks. Recovery required SSHing in and manually running `nix store repair` on individual store paths, then rebuilding both the system and home-manager profiles.

The GC was configured with `--delete-older-than 30d`, which first deletes profile generations older than 30 days, then garbage-collects the newly-unreferenced store paths. This two-step process is inherently fragile: if the GC daemon's view of GC roots diverges from reality (e.g. home-manager profiles under `~/.local/state/nix/profiles/` not being fully traversed, or stale auto-roots under `/nix/var/nix/gcroots/auto/`), active store paths can be collected.

Whether the root cause this time was the GC itself or a store consistency issue during rapid rebuilds (10 system + 8 home-manager activations in one day) is uncertain. What is certain is that `--delete-older-than` amplifies the blast radius of any such event by actively removing the profile generations that would otherwise serve as recovery anchors.

## Decision

Automatic GC must never delete profile generations. Use `--max-freed <size>` instead of `--delete-older-than <duration>`.

```nix
nix.gc = {
  automatic = true;
  interval = { Weekday = 0; Hour = 2; Minute = 0; };
  options = "--max-freed 10G";
};
```

Profile generation cleanup remains an explicit maintenance action. The shared
`nix-gc-maintenance` command retains the latest 10 generations in the invoking
user's Home Manager and user profiles, retains the latest 10 system generations,
then performs one GC pass capped at 10 GiB. Run it through `just gc` from the
repository or directly on any managed host. From the operator checkout on
`xyz`, `just gc <host>` streams the same command over the managed SSH connection;
the target does not need the new package installed first.

The command must be run once for each user with a standalone Home Manager
profile. Home Manager configurations integrated into a NixOS system generation
are retained with that system generation.

## Alternatives Considered

- **Keep `--delete-older-than` with a longer window (90d, 180d)** — reduces frequency but doesn't eliminate the risk. Still deletes generations automatically.
- **Disable automatic GC entirely** — safest, but requires manual disk management. Unnecessary given `--max-freed` exists.
- **Use `min-free` / `max-free` nix settings** — these trigger GC during builds when free space drops below a threshold. Good complement but doesn't replace scheduled GC.

## Consequences

- Disk usage will grow slightly faster since old profile generations accumulate. This is acceptable — profile generations are small (just symlinks), and their store path closures overlap heavily.
- Manual generation cleanup is needed occasionally. A reasonable cadence is after major flake updates or when free-space monitoring reports pressure.
- Ten generations are retained consistently across NixOS, nix-darwin, Home Manager, and user profiles.
- Recovery from future store corruption is easier: old generations remain as GC roots, so rolling back with `nix-env --rollback` or `darwin-rebuild switch --rollback` remains possible.
