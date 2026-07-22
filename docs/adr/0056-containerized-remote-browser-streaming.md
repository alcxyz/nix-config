# ADR-0056: Containerized remote browser streaming

**Status:** Accepted, implemented

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

Launch browser streams with Moonlight's remote-desktop-optimized absolute
pointer mode. Do not let the browser stream capture system-key combinations;
the client compositor retains its workspace and couch-session shortcuts while
ordinary keyboard input continues to the remote browser.

Give each paired streaming host separate local and remote endpoints, while
making endpoint selection an explicit client policy. Fixed clients such as XPS
use `lan-only`: immediately before launch, all three Moonlight address fields
are pinned to the private LAN endpoint and readiness checks never probe VPN.
This prevents host discovery or a cached remote preference from silently moving
a local stream onto the managed VPN. Roaming clients may select `lan-first` or
an explicit `remote-only` launcher instead. Keep concrete endpoint assignments
in private configuration.

On macOS, publish separate `HOST (LAN)` and `HOST (VPN)` application bundles
for each explicitly selected application. Endpoint definitions remain generic
and private; the public Mac configuration opts only Wolf UI into launchers, so
other paired hosts do not acquire misleading entries. Each launcher pins all
three saved address fields to its selected endpoint immediately before starting
the configured Moonlight application, and supplies that exact endpoint to
Moonlight's `stream` command. There is no periodic reconciler and no automatic
route crossover. The launchers match hosts by saved name and leave pairing
certificates and application state untouched.

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
homes. The general profile contains Helium. A PIN-protected Wolf profile
contains isolated Helium, Brave, Chromium, Firefox, and Zen applications
for private use and comparative testing. Their homes remain separate and
persistent across on-demand container replacement.

Build every browser as a distinct local image on top of the same pinned GoW
`base-app` image. Helium and Brave use their pinned Debian release artifacts;
Chromium, Firefox, and Zen import the closure of their pinned Nix package.
Each image contains only its browser and the common Wolf compositor integration.
Docker shares the base layers on disk, while separate image and home boundaries
prevent browser settings, authentication, and upgrade lifecycle from leaking
between applications. The host does not install the browsers globally.
The browser containers relax Docker's default seccomp profile so Chromium can
create its unprivileged user namespace and retain its own renderer sandbox;
they do not use Chromium's `--no-sandbox` escape hatch.

Moonlight transports keyboard scan codes but does not tell Wolf which input
layout is active on the client. Expose Norwegian, US, and Russian in each
browser session and use `Alt+Shift` to cycle layouts inside the remote
compositor. At launch, let the XPS client read its main Hyprland keyboard's
active layout and invoke a LAN-only host helper that selects the corresponding
nested Sway layout after the application container appears. Permit declarative
device-name overrides for external keyboards whose physical layout differs
from the laptop keyboard that Hyprland keeps marked as main. Keep one Moonlight
application per browser so every layout uses the same persistent browser home.
Do not publish one application variant per layout: the pinned Wolf release
derives application state from the title and does not honor an app-level
state-folder override, which would silently split the browser profile.

Set the same XKB layout and LevelThree options on Wolf's outer virtual display
seat and the nested browser compositor. The pinned Wolf build also retains the
real left/right Alt key state instead of synthesizing Left Alt over a held Right
Alt from GameStream's generic modifier bit. This preserves `AltGr` combinations
from physical Moonlight keyboards while retaining the protocol fallback for
clients that send only the modifier mask.

The module reconciles only explicitly managed applications in Wolf's Moonlight
profile. It writes the generated TOML atomically and preserves every unowned
application, paired client, certificate, profile, PIN, and home. Helium is
published directly for general browsing. A pinned Wolf UI entry is also
published as the controller-friendly profile selector. Its API socket stays in
a root-owned local runtime directory and is mounted only into that application
container. The protected browser set remains absent from the direct Moonlight
list and is attached to a PIN-protected Wolf profile through a root-only
systemd credential supplied at runtime by the private configuration. The
credential contains only the protected profile identity, display name, and
PIN. It is never copied into the Nix store or this repository.

Do not advertise the protected browser's identity in Wolf UI. Replace Wolf's
stock unprotected profile with the protected profile, present it under the
neutral `User` label, and discard any identifying profile icon before writing
runtime configuration. The application list remains unavailable until the PIN
is accepted. This is UI discretion rather than an additional security boundary.

Browser containers keep a small Waybar for workspace, layout, audio, and clock
status, but run it in Sway hide mode. It must not permanently consume vertical
space during browsing or video playback; holding the compositor modifier
temporarily reveals it.

Each disposable browser container takes an advisory lock on its persistent
home for its full lifetime. After acquiring the lock, startup removes stale
Chromium singleton links and Firefox-family profile-lock symlinks whose targets
lived in the previous container's private temporary directory. A crashed or
interrupted stream can therefore be launched again without discarding browser
state, while a concurrent container cannot open and corrupt the same profile.
Wolf remains responsible for
discarding the stopped application container; recovery happens on the next
explicit launch so intentionally closing a browser does not cause a restart
loop.

Roll out in two gates. First validate Wolf's upstream Firefox application at
the intended 1440p60 client mode, including NVENC, audio, keyboard, pointer,
phone input, and controller exit behavior. The accepted transport baseline is
HEVC at 1440p60 and 40 Mbit/s: a multi-minute run remained connected without
packet loss, encoder errors, container restarts, or OOM events. Wolf uses NVENC
and the Moonlight client uses hardware decode. Firefox renders through the GPU,
but its current container decodes web video in software; this remains an
application-image optimization rather than a transport blocker.

After that baseline passes, validate Helium and Brave through the same stream,
then expose the broader protected browser matrix for comparative testing.
Helium's XWayland/OpenGL path is the qualified Chromium-family baseline; Brave,
plain Chromium, Firefox, and Zen remain independently selectable so their
rendering, video decode, profile weight, and site compatibility can be measured
without sharing state. Keep local XPS browsers as a fallback until the remote
candidate in use passes its acceptance tests.

A comparative acceptance run used the same 1440p YouTube video, explicitly set
to 1440p, over the accepted 1440p60 HEVC transport. Each browser played for at
least two minutes while the browser container, Wolf, NVENC, Moonlight, and XPS
thermals were sampled. All five remained connected without a browser crash,
Wolf encoder error, Moonlight decoder error, or abnormal client-side resource
growth. Approximate observed ranges were:

| Browser | Browser CPU cores | Browser memory | Wolf CPU | NVENC | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| Helium | 1.7–3.1 | 0.94–1.00 GiB | 31–38% | 25–28% | Passed; preferred visual baseline |
| Brave | 1.6–3.3 | 0.88–0.98 GiB | 31–36% | 26–27% | Passed transport; visible site/UI glitches remain |
| Chromium | 2.0–3.6 | 1.04–1.10 GiB | 31–37% | 24–27% | Passed |
| Firefox | 1.0–1.5 | 1.03–1.07 GiB | 29–32% | 26–28% | Passed |
| Zen | 0.7–2.1 | 1.16–1.34 GiB | 26–31% | 25–27% | Passed; highest memory use |

Across the matrix, XPS Moonlight stayed near 18% of one CPU core and 272 MiB
RSS, with package temperature normally in the mid-to-high 50s Celsius. The
similar Wolf and client costs show that browser choice primarily changes the
remote application workload; it does not materially change stream encode or
client decode cost. Helium remains the default because it also produced the
best observed rendering behavior, not merely because it passed telemetry.

Run Steam, public Helium, and the protected selector as separate Moonlight user
services on stable XPS workspaces. The services do not stop one another, so
distinct remote applications can be kept open in parallel. Browser profile
locks still reject two containers attempting to open the same persistent home.
Background clients mute audio and release gamepad input. Connected clients are
not idle-timed; the bounded cleanup deadline begins only after disconnect.

Route the compositor close shortcut through the focused process's user-service
cgroup. Managed Moonlight windows stop their exact local service with a short
per-cgroup SIGKILL fallback, but do not send the protocol quit that destroys the
resumable remote application. Browser launchers therefore omit Moonlight's
`--quit-after` option. Wolf starts a bounded idle deadline on stream
pause and on an empty resumable lobby, cancels it on resume or join, and stops
the corresponding application only after the deadline expires. Ordinary
windows retain the compositor's normal close request. This prevents a stalled
decoder event loop from trapping its supervisor, preserves fast browser resume,
and eventually removes abandoned application containers.

Public Helium and the protected selector target the same Wolf host. Give the
selector its own persistent Moonlight XDG profile and client certificate so
Wolf treats it as an independent paired client instead of asking to terminate
the public session. Keep generated credentials and pairing state outside the
Nix store; NixOS declares the profile boundary and pairing helper only.

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

- Forgejo issue #182 records the completed implementation and accepted browser
  matrix; follow-up rendering or input refinements should be tracked as
  separate defects rather than reopening the delivery issue.

- Reusable `services.wolf-streaming` NixOS module and NVIDIA CDI bridge:
  implemented.
- Firefox HEVC transport baseline: accepted.
- Shared GoW browser runtime and distinct pinned Helium, Brave, Chromium,
  Firefox, and Zen images: implemented. All five passed the sustained 1440p
  transport run. Helium remains the preferred visual baseline; Brave retained
  visible site/UI glitches despite a healthy stream, and Zen used the most
  memory.
- Norwegian, US, and Russian layouts in the shared browser session:
  implemented. Moonlight does not carry the layout name, so XPS supplies it
  out-of-band from the active main keyboard and selects the matching nested
  layout at launch; `Alt+Shift` remains the explicit cycle control. Right Alt
  LevelThree input has been accepted with `AltGr+2` producing `@`.
- Generic, atomic protected-profile reconciliation without store-copying its
  credential: implemented. The visible profile identity is neutralized and the
  redundant stock profile is removed.
- Shared auto-hidden browser-session status bar: implemented.
- Pinned Wolf UI profile selector and local API socket: implemented and
  accepted over an XPS HEVC/NVENC stream. Public XPS shortcuts launch Helium
  directly; a neutral menu entry and separate keyboard shortcut open Wolf UI
  for the PIN-protected profile without putting that path in the on-screen
  guide.
- Direct application catalog reduced to Wolf UI and Helium; the upstream
  Firefox baseline and test-pattern entries are declaratively pruned after
  acceptance without deleting their dormant application homes.
- Browser homes are locked while in use and stale Chromium singleton files are
  removed before launch. Wolf coordinator restarts remove only orphaned
  containers created by the managed browser runners, while Moonlight sessions
  terminate themselves if their window never appears or disappears while the
  client process remains stuck.
- Explicit streaming endpoint policy: XPS pins both browser and Steam pairings
  to LAN-only fields and readiness checks. macOS exposes distinct LAN and VPN
  application bundles; each pins all saved fields to one endpoint and starts
  the configured Wolf application without automatic fallback.
- Private Brave profile provisioning and XPS launch integration: implemented
  and accepted. Wolf UI requires the private PIN before exposing Brave; the
  browser runs on XEV's NVIDIA GPU with a persistent isolated home, while XPS
  hardware-decodes the HEVC stream.
- XPS client decode is assigned to Intel VA-API instead of its NVIDIA GPU.
  Three concurrent streams continue decoding while hidden, so they retain a
  measurable CPU, thermal, and network cost until explicitly closed.
- Disposable browser crash recovery and per-profile concurrency guard:
  implemented and verified by relaunching Brave from a home containing stale
  Chromium singleton links.
- Parallel Steam, public-browser, and protected-selector Moonlight clients:
  implemented with three independent services on workspaces 1–3. Steam and
  Helium were revalidated after excluding Sunshine's virtual inputs from
  Kanata. The selector has a distinct persistent Moonlight client profile so
  Wolf can retain it alongside public Helium.
- Resumable browser lifecycle: implemented and accepted. Closing the focused
  Moonlight window stops only its local user service, reconnecting resumes the
  existing Wolf application, and an uninterrupted 30-minute disconnect was
  observed expiring and removing the abandoned browser container.
- Guarded encoder recovery: implemented. XEV watches for the narrow fatal
  CUDA-buffer and Wolf streaming-thread signatures that leave the coordinator
  reachable but unable to emit video. Recovery remains pending while the Wolf
  API reports any active session, then restarts the coordinator once no
  healthy concurrent stream can be disrupted. Persistent browser homes are
  retained. Sustained VRAM growth remains covered by its separate watchdog.
- Stream teardown is independent of DMS responsiveness. Every optional shell
  IPC call has a sub-second deadline, preventing a presentation-layer timeout
  from leaving an otherwise stopped Moonlight unit in a failed state.
