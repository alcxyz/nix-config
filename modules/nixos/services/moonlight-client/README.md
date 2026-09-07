# Moonlight client module

The service keeps one public entry point, `default.nix`, with explicit helper
imports in the existing module layer (ADRs [0006](../../../../docs/adr/0006-four-tier-module-layering.md)
and [0043](../../../../docs/adr/0043-selective-external-nix-config-pattern-adoption.md)).

- `options.nix` declares the public option interface. Its caller supplies `lib`,
  `pkgs`, and the existing shared KDE Connect defaults.
- `audio.nix` constructs the audio output, health recovery, and display-layout
  audio helpers. Its caller supplies configuration, packages, state-file paths,
  and the output-stability helper; it does not register services itself.
- `default.nix` composes those helpers with the remaining session, display,
  browser, and input implementation, and owns NixOS service registration.

These boundaries preserve generated commands, defaults, and service lifecycle.
Further decomposition is tracked in [issue #279](https://git.alc.xyz/alcxyz/nix-config/issues/279).
