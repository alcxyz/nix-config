# ADR-0027: Retired PipeWire virtual sink for per-app audio isolation (wcap)

**Status:** Retired (2026-06-04)
**Date:** 2026-05-01
**Applies to:** `modules/nixos/common/`

## Context

This decision is retired. The `wcap` window capture workflow is no longer used,
so the repository no longer exposes the `wcap` package, installs
`gpu-screen-recorder` for that workflow, or carries NixOS-side PipeWire
configuration for a dedicated capture sink.

The historical decision is kept below for context only.

The `wcap` window capture tool needs to record audio from a specific application without that audio playing through the user's headphones. An optional monitoring mode (hear what's being recorded) should also be supported via a toggle. The audio isolation must only be active during recording — normal audio behaviour should be unaffected at all other times.

## Decision

Declare a passive PipeWire null sink (`wcap-sink`) in NixOS configuration. The sink exists at all times but does nothing on its own — no streams are routed to it by default. At recording time, `wcap start` dynamically moves the target app's PipeWire stream to `wcap-sink` using `pw-cli` or `wpctl`, and `wcap stop` restores the stream to its original sink. No WirePlumber Lua rules are involved.

This keeps audio routing fully under `wcap`'s control and avoids silencing apps when not recording. The approach is also app-agnostic — any PipeWire stream can be captured, not just Helium.

## Alternatives Considered

- **Persistent WirePlumber Lua rule matching on `application.name`** — auto-routes all matching streams at all times, silencing the app even when not recording. Also cannot distinguish between browser profiles sharing the same process name. Too aggressive.
- **OBS virtual audio cable** — requires OBS running at all times; not suitable for a lightweight CLI workflow.
- **Manual routing via pavucontrol/helvum** — works but requires manual intervention per session; not reproducible.

## Consequences

- The null sink appears in audio device lists (e.g. pavucontrol) but is inert until wcap routes a stream to it — no user-visible side effects when not recording.
- `wcap` needs sufficient PipeWire permissions to move streams between sinks at runtime; standard user permissions on a desktop NixOS system are sufficient.
- `xdg-desktop-portal-hyprland` must be present for `gpu-screen-recorder -w portal` window selection to work.
