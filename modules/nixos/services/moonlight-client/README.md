# Moonlight client module

The service keeps one public entry point, `default.nix`, with explicit helper
imports in the existing module layer (ADRs [0006](../../../../docs/adr/0006-four-tier-module-layering.md)
and [0043](../../../../docs/adr/0043-selective-external-nix-config-pattern-adoption.md)).

- `options.nix` declares the public option interface. Its caller supplies `lib`,
  `pkgs`, and the existing shared KDE Connect defaults.
- `audio.nix` constructs the audio output, health recovery, and display-layout
  audio helpers. Its caller supplies configuration, packages, state-file paths,
  and the output-stability helper; it does not register services itself.
- `browser-sessions.nix` constructs local, protected, and remote browser
  launchers plus Moonlight stream startup and window supervision. Its caller
  supplies the generated invocations, endpoint setup, and display helpers; it
  does not register services itself.
- `direct-drm.nix` constructs output and audio preparation, stream-host
  readiness, and the direct-DRM session wrappers. Its caller supplies the
  generated Moonlight invocations, endpoint setup helpers, and state paths; it
  does not register services itself.
- `endpoints.nix` constructs endpoint policy, readiness lists, profile setup,
  and selector pairing from explicit caller-supplied values.
- `input.nix` constructs couch controls, controller and direct-mode input
  daemons, and KDE Connect and pointer integration. Its caller supplies the
  composed session controls, mode flags, and packages; it does not register
  services itself. The Python daemon templates and KDE Connect C shim live in
  adjacent language source files and receive their generated values explicitly.
- `layout.nix` constructs software mirroring, adaptive output layout, workspace
  routing, and the display layout controls. Its caller supplies configuration,
  packages, state-file paths, derived mirror settings, and the audio output
  helper; it does not register services itself.
- `session-control.nix` constructs DMS launch and control helpers, output
  stability checks, splash and power actions, and session mode switching. Its
  caller supplies configuration, state paths, and the display and audio
  helpers; it does not register services itself.
- `session-artifacts.nix` constructs desktop entries, the Hyprland session
  configuration, and the session dispatcher and package. Its caller supplies
  the composed helper commands; it does not register services itself.
- `default.nix` composes those helpers and owns NixOS service registration.

These boundaries preserve generated commands, defaults, and service lifecycle.
Further decomposition is tracked in [issue #279](https://git.alc.xyz/alcxyz/nix-config/issues/279).
