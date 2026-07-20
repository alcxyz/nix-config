# ADR-0056: Containerized remote browser streaming

**Status:** Accepted, implementation in progress

**Applies to:** `hosts/xev`, `hosts/xps`, Wolf, Moonlight, browser sessions

## Context

The XPS couch session needs both a general browser and a private browser profile
for video-heavy use. Local browser playback is sensitive to the active display
topology and software-mirroring load. The existing SteamHeadless stream is
optimized for games and should not become the lifecycle, profile, or package
boundary for browser sessions.

A browser-streaming host must provide hardware video encoding, client-selected
virtual display modes, audio, keyboard, pointer, phone, and controller input,
and persistent but isolated browser homes. Private profile credentials, pairing
certificates, and access PINs must remain outside this public repository.

## Decision

Run [Wolf](https://games-on-whales.github.io/wolf/stable/) as a pinned
container on a GPU-capable NixOS host, with `xev` as the initial deployment.
Wolf provides Moonlight-compatible named applications and creates an isolated
virtual desktop for each application without requiring a physical monitor or a
dummy display plug.

The NixOS module:

- enables NVIDIA container CDI and starts Wolf only after its CDI inventory is
  available;
- mounts the Docker socket, DRM and virtual-input devices required by Wolf;
- stores certificates, pairings, profiles, and application homes in a
  configurable persistent state directory;
- exposes only Wolf's documented Moonlight protocol ports; and
- pins the Wolf image by platform digest instead of following a mutable tag.

Treat the state directory as private runtime data. Do not commit its generated
configuration, certificates, paired-client records, profile PINs, or browser
homes. A PIN-protected Wolf profile will contain the private Brave application;
the general profile will contain Helium. Their homes remain separate and
persistent across on-demand container replacement.

Build Helium and Brave as distinct local images on top of the same pinned GoW
`base-app` image. Each image contains only its browser and the common Wolf
compositor integration. Docker shares the base layers on disk, while separate
image and home boundaries prevent browser settings, authentication, and upgrade
lifecycle from leaking between the two applications. Browser release artifacts
are fixed-output Nix inputs; the host does not install either browser globally.
The browser containers relax Docker's default seccomp profile so Chromium can
create its unprivileged user namespace and retain its own renderer sandbox;
they do not use Chromium's `--no-sandbox` escape hatch.

Moonlight transports keyboard scan codes but does not tell Wolf which input
layout is active on the client. Expose Norwegian, US, and Russian in each
browser session, in that order, and use `Alt+Shift` to cycle layouts inside the
remote compositor. Keep one Moonlight application per browser so every layout
uses the same persistent browser home. Do not publish one application variant
per layout: the pinned Wolf release derives application state from the title
and does not honor an app-level state-folder override, which would silently
split the browser profile.

The module reconciles only explicitly managed applications in Wolf's Moonlight
profile. It writes the generated TOML atomically and preserves every unowned
application, paired client, certificate, profile, PIN, and home. Helium is
published directly for general browsing. A pinned Wolf UI entry is also
published as the controller-friendly profile selector. Its API socket stays in
a root-owned local runtime directory and is mounted only into that application
container. Brave is built but must remain absent from the direct Moonlight list;
it is attached to a PIN-protected Wolf profile through a root-only systemd
credential supplied at runtime by the private configuration. The credential
contains only the protected profile identity, display name, and PIN. It is
never copied into the Nix store or this repository.

Roll out in two gates. First validate Wolf's upstream Firefox application at
the intended 1440p60 client mode, including NVENC, audio, keyboard, pointer,
phone input, and controller exit behavior. The accepted transport baseline is
HEVC at 1440p60 and 60 Mbit/s: a multi-minute run remained connected without
packet loss, encoder errors, container restarts, or OOM events. Wolf uses NVENC
and the Moonlight client uses hardware decode. Firefox renders through the GPU,
but its current container decodes web video in software; this remains an
application-image optimization rather than a transport blocker.

After that baseline passes, build the pinned Helium and Brave images, validate
Helium through the same stream, then create the private Brave profile and add
the controller and keyboard launch actions on XPS. Keep local XPS browsers as a
fallback until both remote applications pass their acceptance tests.

The SteamHeadless deployment and its existing XPS launch action remain
unchanged. A browser-streaming failure must not start, stop, or modify the game
streaming host.

## Consequences

Browser rendering and video decode move off XPS while Moonlight retains the
controller-first couch experience. Wolf can serve multiple isolated
application profiles and adapt its virtual desktop to the Moonlight client's
requested resolution.

Wolf requires broad local access to Docker and input devices. Do not expose its
Unix control socket through a network proxy, and restrict host access to the
normal trusted-network policy. Pairing is explicit and its generated authority
material remains runtime state.

Changing the streaming host from the open-source display driver to the
proprietary NVIDIA stack requires a boot into the prepared generation. Perform
that host reboot through the existing maintenance workflow; do not live-switch
the GPU driver on a running cluster node.

## Alternatives considered

### Add browsers to the SteamHeadless container

Rejected because it couples browsing availability and profile persistence to
the game library, Sunshine, and container lifecycle on the Steam host.

### Run a second hand-built Sunshine/Xorg desktop

Rejected because it recreates virtual-display, input-relay, audio, and
application-isolation machinery that Wolf already provides.

### Keep all browser rendering local to XPS

Retained only as a fallback. It does not address the measured playback
sensitivity across mirror and multi-display layouts.

### Use VNC or RDP

Rejected for the primary couch path because they do not provide the same
low-latency video, audio, and controller integration already used by Moonlight.

## Tracking

- Reusable `services.wolf-streaming` NixOS module and NVIDIA CDI bridge:
  implemented.
- Firefox HEVC transport baseline: accepted.
- Shared GoW browser runtime and distinct pinned Helium/Brave images:
  implemented; Helium passed deployed application testing.
- Norwegian, US, and Russian layouts in the shared browser session:
  implemented; automatic client-layout inheritance is unavailable in the
  Moonlight protocol, so layout selection is explicit with `Alt+Shift`.
- Generic, atomic protected-profile reconciliation without store-copying its
  credential: implemented.
- Pinned Wolf UI profile selector and local API socket: implemented and
  accepted over an XPS HEVC/NVENC stream.
- Private Brave profile provisioning and XPS launch integration: pending.
