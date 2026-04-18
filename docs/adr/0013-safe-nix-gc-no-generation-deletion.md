# ADR-0013: Safe nix GC — never auto-delete profile generations

**Status:** Accepted
**Date:** 2026-04-18
**Applies to:** `hosts/mac/configuration.nix` (nix.gc)

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

Profile generation cleanup is done manually with `nix-env --delete-generations +5` (keep last 5) when disk space is needed.

## Alternatives Considered

- **Keep `--delete-older-than` with a longer window (90d, 180d)** — reduces frequency but doesn't eliminate the risk. Still deletes generations automatically.
- **Disable automatic GC entirely** — safest, but requires manual disk management. Unnecessary given `--max-freed` exists.
- **Use `min-free` / `max-free` nix settings** — these trigger GC during builds when free space drops below a threshold. Good complement but doesn't replace scheduled GC.

## Consequences

- Disk usage will grow slightly faster since old profile generations accumulate. This is acceptable — profile generations are small (just symlinks), and their store path closures overlap heavily.
- Manual generation cleanup is needed occasionally. A reasonable cadence is after major flake updates.
- Recovery from future store corruption is easier: old generations remain as GC roots, so rolling back with `nix-env --rollback` or `darwin-rebuild switch --rollback` remains possible.
