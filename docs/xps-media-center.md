# XPS media center

XPS provides a controller-first Hyprland session for couch browsing and
Moonlight streaming. The persisted `merged` profile adds an auto-hiding DMS
shell without making the remote stream host a boot dependency.

Open DMS's native on-screen control reference at any time with `Super+H` or by
holding `Minus+B` on the Switch Pro controller. DMS places the modal on the
currently focused display and uses couch-scaled typography; repeat the shortcut
to close it.

The DMS bar also includes a `Display control` pill. Its popout separates the
persisted layout policy from the outputs Hyprland is actually presenting, and
shows whether mirroring is active or merely armed until another TV becomes
available. Use its couch-sized rows to select any layout directly, toggle
mirroring, or cycle audio without stepping through intermediate states.

First-party administrative actions use the focused-screen DMS authorization
dialog. The prompt states the requested operation, why it is needed, and its
expected effect before asking for the password; raw Polkit and command data stay
under `Technical details`. Unmatched third-party requests retain Polkit's
generic message.

## Startup and shutdown

The boot and graphical-session transitions are deliberately separate. Plymouth
starts with one centered X, separates the two X positions, and reveals N/I/B/O.
It then presents a compact Nix snowflake below NIXBOX and fills a simple bounded
progress track beneath the mark. Once the existing display-pipeline allocator
has settled the dock-backed outputs, a boot-only theme reload starts that
sequence from frame zero. The boot mark is pre-rendered at a compact size so
Plymouth does not repeatedly scale multi-megapixel transparent artwork across
the simpledrm-to-i915 and multi-head handoff. The final NIXBOX, mark, and full
bar lockup is gated on an explicit completion signal because Plymouth also
invokes the theme's quit callback during reload.

The bar is a bounded visual transition rather than a percentage estimate of
system boot. Its intermediate cadence may vary with Plymouth's active renderer;
the explicit completion stage always presents the full final lockup. This is an
accepted cosmetic tradeoff and must not delay graphical login further.

Plymouth's framebuffer is retained and greetd does not explicitly deallocate
that VT, though a brief hardware mode-set blank may still occur while Hyprland
claims the output. Once Hyprland has a usable output, the distinct Quickshell
overlay presents only the approved `STARTING SESSION` transition and fades into
the couch desktop.

Systemd-boot keeps the newest six configurations on the EFI system partition.
This bounds copied boot artifacts without deleting NixOS profile generations,
so several rollback choices remain while new generations can still be written.

The graphical session overlay renders on every active display, never captures
input, and has a hard timeout so a display or animation failure cannot delay
the browser, DMS, or controller controls.

The display-pipeline allocator still runs before greetd and preserves the
three-external/internal-panel fallback behavior. Hyprland then owns the dynamic
display layout, workspaces, and mirroring exactly as before.

DMS power-off and reboot actions run the matching reverse animation while
Hyprland still owns the displays, then request the selected system action. This
keeps power transitions on the same proven renderer instead of handing the
external outputs back to Plymouth for a second animation.

Hyprland's startup diagnostics remain available in its runtime log. Normal boot
verbosity remains logged, and Plymouth's details view retains access to it for
diagnosis and recovery.

## Controller controls

Hold each combination until the action triggers.

| Controller | Action |
|---|---|
| `Home+A` | Start the remote Steam session and Moonlight |
| `Home+X` | Open the remote Helium browser on XEV |
| `L3+R3` | Open or return to remote Helium on workspace 2 |
| `Minus+Plus` | Toggle display mirroring |
| `Minus+X` | Cycle display layouts |
| `Minus+Y` | Cycle audio outputs |
| `Minus+B` | Toggle the on-screen control reference |

The controller listener observes these combinations without taking exclusive
ownership of the controller, so games continue to receive normal controller
input.

## Keyboard controls

| Keyboard | Action |
|---|---|
| `Super+M` / `Super+B` | Open Steam on workspace 1 / Helium on workspace 2 |
| `Super+R` | Open the remote Helium browser on XEV |
| `Super+Shift+R` | Open the PIN-protected remote `User` selector |
| `Super+Shift+M` | Toggle display mirroring |
| `Super+Shift+D` | Cycle display layouts |
| `Super+Shift+A` | Cycle audio outputs |
| `Super+H` | Toggle the on-screen control reference |
| `Super+V` | Open a new local browser window |
| `Alt+Enter` | Open a terminal |
| `Super+Space` | Open DMS search |
| `Super+Enter` / `Super+S` / `Super+W` | Fullscreen / float / close safely |
| `Super+1`…`Super+9` | Open an active workspace |
| `Super+J` / `Super+K` | Previous / next active workspace |
| `Super+Shift+1`…`Super+Shift+9` | Move the focused window to an active workspace |
| `F8` / `F9` / `F10` | Mute / volume down / volume up |
| `Alt+Shift` | Cycle Norwegian, US, and Russian keyboard layouts |

## Display layouts

The selected layout persists across reboots. `Minus+X` or `Super+Shift+D`
cycles through:

| Layout | Behaviour |
|---|---|
| `adaptive` | Preserve one active output, with the largest connected display as fallback |
| `all` | Enable every connected external display |
| `living-bedroom` | Enable the living-room and bedroom TVs and park the auxiliary display |
| `living-aux` | Enable the living-room TV and auxiliary display |
| `bedroom-aux` | Enable the bedroom TV and auxiliary display |
| `living` | Use only the living-room TV |
| `bedroom` | Use only the bedroom TV |
| `aux` | Use the auxiliary display, with a TV fallback |

The first active display receives workspaces 1–3 and the second receives 4–6.
This compact assignment also applies to `living-aux` and `bedroom-aux`, with
the auxiliary display placed directly beside the selected TV. The auxiliary
display uses workspaces 7–9 only in the three-display layout, where both TV
workspace blocks are already active. Solo and dual-TV mirror layouts expose
1–3; independent two-display layouts expose two sets; and the three-display
layout exposes all nine. If a display disappears, windows from its inactive set
are folded into the matching primary workspace 1–3. Parked displays are moved
outside the usable desktop before DPMS is disabled, preventing the cursor from
disappearing onto them.

Cable presence is detectable, but panel power is not reliable through every
adapter. Use an explicit layout when a connected television remains visible to
Linux while powered off.

Mirroring is separate from layout selection. XPS uses a supervised fullscreen
`wl-mirror` client from the primary TV to the secondary TV, including when their
resolutions match; native Hyprland mirroring left the physical source blank on
this connector pair. The client uses Hyprland's DMA-BUF capture protocol, so
frames remain GPU-backed instead of being copied through system memory. The
selected mirror state persists across reboots until toggled again. Enabling it
switches both TVs to 1080p60, which keeps browser playback smooth while the
compositor captures and presents the second copy; disabling it restores the
normal 1440p60 extended layout. If either TV is unplugged, mirroring becomes
dormant and the remaining display exposes workspaces 1–3; it resumes when a
second eligible display returns.

The secondary TV input must use its pixel-preserving custom picture-size mode
at 1080p. A conventional 16:9 television mode may apply overscan and crop the
outer browser edges even though Hyprland and `wl-mirror` are presenting the
complete frame.

### Browser playback matrix

Measurements use the logged-in Helium couch profile and the same 60 fps YouTube
wildlife video. A 500 ms in-page sampler discards intervals containing ads,
pauses, resolution changes, or frame-counter resets. Each table row therefore
reports one uninterrupted playback segment.

| Active topology | Mirrored | Output modes | Video | Clean sample | Dropped frames |
|---|---:|---|---:|---:|---:|
| Primary TV only | No | 1440p60 | 1080p60 | 104.5 s | 489/6,270 (7.80%) |
| Primary TV only | No | 1440p60 | 1440p60 | 219.5 s | 3,340/13,169 (25.36%) |
| Secondary TV only | No | 1440p60 | 1080p60 | 80.0 s | 323/4,800 (6.73%) |
| Secondary TV only | No | 1440p60 | 1440p60 | 107.5 s | 1,636/6,447 (25.38%) |
| Primary TV plus Philips | No | 1440p60 + 1080p60 | 1080p60 | 76.0 s | 1,714/4,561 (37.58%) |
| Primary TV plus Philips | No | 1440p60 + 1080p60 | 1440p60 | 117.5 s | 3,098/7,225 (42.88%) |
| Secondary TV plus Philips | No | 1440p60 + 1080p60 | 1080p60 | 87.5 s | 1,905/5,249 (36.29%) |
| Secondary TV plus Philips | No | 1440p60 + 1080p60 | 1440p60 | 119.0 s | 3,104/7,421 (41.83%) |
| Two TVs; Philips parked | Yes | 2×1080p60 | 1080p60 | 122.5 s | 2/7,350 (0.027%) |
| Two TVs; Philips parked | No | 2×1440p60 | 1080p60 | 69.5 s | 1,887/4,170 (45.25%) |
| Two TVs; Philips parked | No | 2×1440p60 | 1440p60 | 130.5 s | 4,038/7,828 (51.58%) |
| Two TVs plus Philips | No | 2×1440p60 + 1080p60 | 1080p60 | 77.5 s | 2,176/4,650 (46.80%) |
| Two TVs plus Philips | No | 2×1440p60 + 1080p60 | 1440p60 | 75.5 s | 2,217/4,531 (48.93%) |
| Two TVs plus Philips | TVs only | 3×1080p60 | 1080p60 | 85.0 s | 31/5,100 (0.61%) |

The measurements establish that the large regression follows multiple 1440p
compositor outputs even when `wl-mirror` is stopped. A single 1440p output is
substantially better but still drops more frames when the video is also 1440p.
Adding Philips beside either 1440p TV raises drops to roughly 36–38% for 1080p
video and 42% for 1440p video; the TV or connector chosen does not materially
change the result. Matching all active TV and video modes at 1080p60 restores
smooth playback; an independent 1080p Philips output in that matched mirrored
topology adds a small but acceptable cost.

## Audio outputs

DMS and the audio-cycle shortcuts expose the laptop speakers, each display
audio path, connected Bluetooth speakers, and a virtual `Both TVs` output.
Selecting `Both TVs` sends the same stereo stream to both TV sinks with
PipeWire latency compensation. It is especially useful with the `dual-tvs`
layout and TV mirroring enabled, providing the same picture and sound at both
TVs.

Audio selection is manual and survives display-layout changes. A manually
connected Bluetooth speaker becomes another choice but does not take over as
the default output.

## Browser, phone, and desktop use

The couch browser and Moonlight use XWayland so KDE Connect can provide phone
keyboard, clicks, and scrolling. Phone pointer movement is not currently
supported; an X11-to-Hyprland pointer bridge was removed because it interfered
with physical mouse movement over XWayland windows. The protected local browser
is intentionally omitted from launch menus and the on-screen shortcut guide.
Its encrypted-profile supervisor runs as an independent user service, so DMS
restarts do not terminate an active session. Browsers use Hyprland's normal tiled layout; they do
not request browser-level fullscreen, avoiding its broken couch pointer and
click behaviour. Their chrome and page contents use a couch-friendly 1.5x
device scale; use `Super+Enter` only when fullscreen is explicitly wanted.

### Remote browser streaming

XEV also provides on-demand browser sessions through two independent Wolf
coordinators and Moonlight. The public coordinator exposes only Helium. The
protected coordinator exposes Wolf UI, whose protected profile offers isolated
Helium, Brave, Chromium, Firefox, and Zen homes for private use and comparative
testing. Each launch creates a disposable application container and virtual
display. A client disconnect leaves the container resumable for 30 minutes;
its owning coordinator removes it after that idle deadline while retaining the
browser's isolated home. The browsers are not installed globally on XEV; their
images share common GoW runtime layers rather than duplicating a desktop stack.

The protected profile is provisioned from a root-only runtime credential. Its
identity and PIN remain in the private configuration and out of the public Nix
store; the reconciler preserves Wolf's pairings and any applications it does
not own.

Launch public Helium directly with `Home+X`, `Super+R`, or the
`Helium (Remote)` menu entry. The neutral `User (Remote)` menu entry and
`Super+Shift+R` open Wolf UI, which exposes only the PIN-protected user profile
and its five browser choices. The private shortcut is deliberately omitted from the on-screen
guide. Wolf UI can also be restored from a running Wolf application with
`Start+Up+RB` on the controller or `Ctrl+Alt+Shift+W` on a keyboard.

The merged couch session starts public remote Helium by default. At login it
checks the direct LAN Wolf endpoint briefly; if it is not ready it opens local
Helium instead, so XPS still boots into a usable browser when XEV is unavailable.
`Super+B` normally returns to remote Helium; the boot fallback does not turn XEV
into a login dependency.

Steam is available through `Home+A`, `Super+M`, and the `Steam Stream` menu
entry. The launcher first checks the direct LAN endpoint, starts the remote
Steam container over its established SSH host configuration when needed, and
shows DMS status notifications while waiting for Sunshine. A cold start is
expected to take roughly 20–90 seconds; an explicit failure notification
replaces the previous silent timeout behavior.

Steam keyboard and pointer input pass through the container's Sunshine relay.
Host-side Kanata deliberately excludes those virtual passthrough devices and
restarts after transient device failures, so physical hotkeys remain managed
without consuming streamed input.

Remote browser homes persist across disposable application containers. Startup
serializes access to each home and repairs stale Chromium singleton and
Firefox-family profile-lock state. If a
Moonlight process stalls without a usable window, its user service terminates
the local process so the same launcher can reconnect on the next attempt.
Browser launchers intentionally omit Moonlight's `--quit-after`: closing the
local client pauses the remote application instead of destroying it.

Steam, public Helium, and the protected Wolf selector use independent Moonlight
processes on workspaces 1, 2, and 3 respectively. Public Helium and the
protected selector also use separate Wolf coordinators, state trees, runtime
sockets, ports, cleanup scopes, and watchdogs on XEV. They can remain open and
be switched with the ordinary workspace shortcuts; launching, restarting, or
recovering one browser coordinator does not stop the other. Background clients
mute their audio and do not retain controller input, but continue decoding and
using network bandwidth until explicitly closed.
Three concurrent 1440p60 clients therefore still impose client-side decode and
presentation work on XPS even though rendering happens remotely.
Each Moonlight client is supervised by its own process and exact Hyprland
window address so XWayland's fallback class for a second client cannot make the
services confuse one another.

`Super+W` maps a focused Moonlight process back to its owning user-service
cgroup and stops that service instead of relying on the application's window
close handler. This matters when a stalled decoder stops servicing GUI events.
Systemd kills only that client's unresponsive local processes within three
seconds; it deliberately does not quit the resumable remote application.
The optional DMS bar and dock updates are individually time-bounded, so a
stalled shell IPC request cannot wedge the Moonlight service during cleanup.
Wolf arms a 30-minute idle deadline when the stream disconnects or a protected
browser lobby becomes empty. Reconnecting cancels the deadline; expiry stops
and removes the abandoned remote application container. Other applications
retain Hyprland's ordinary focused-window close behavior.

XEV also guards against the rarer case where either Wolf coordinator remains
reachable after its CUDA/GStreamer video path has failed. Each watchdog
recognizes only the known fatal buffer-map or streaming-thread signatures,
waits until its own coordinator reports no active sessions, and reconstructs
only that coordinator and its disposable runner containers. If a coordinator
retains session records and accumulates a pathological number of abandoned HTTP
control connections, its watchdog treats those records as stale and recovers
instead of waiting forever. Browser homes remain persistent across recovery.

The protected selector uses a separate persistent Moonlight client profile and
targets the protected coordinator's distinct hostname and protocol port. Pair
that profile once with `couch-moonlight-pair-private FOUR_DIGIT_PIN`; its
certificate and host state remain in the user's private data directory rather
than the Nix store. The migration from the earlier shared coordinator preserves
that established pairing while moving subsequent protected sessions onto the
independent endpoint.

Moonlight opens as a normal tiled window. It requests a 2560×1440 stream
independently of the local output: a 1440p TV presents it at native size, while
the 1080p Philips output scales the window to that display. Moonlight and
Hyprland do not request fullscreen; the single tiled window already fills the
workspace.

The accepted transport profile is 2560×1440 at 60 Hz using HEVC and a 40 Mbit/s
client bitrate. Helium, Brave, Chromium, Firefox, and Zen each completed the
same sustained 1440p playback test without a browser crash, Wolf encoder error,
Moonlight decoder error, or abnormal XPS resource growth. Helium remains the
default because it also gave the cleanest observed rendering. Brave's stream
telemetry was healthy but visible site/UI glitches remained; the other private
choices are useful compatibility fallbacks. Local XPS browsers remain
available as an independent fallback.

Both browser and Steam streams on XPS are LAN-only. Immediately before launch,
the endpoint reconciler pins Moonlight's local, manual, and remote address
fields to the configured LAN endpoint, and readiness checks probe only LAN.
XPS therefore fails locally instead of silently streaming over VPN. The Mac
instead exposes separate `Wolf (LAN)` and `Wolf (VPN)` application bundles for
the protected selector. Each launcher pins both the selected address and the
coordinator's HTTP base port, so neither route falls back to the other or to
the public coordinator. Synergy input sharing is likewise LAN-only and
disconnects rather than crossing the VPN.

The remote browser session provides Norwegian, US, and Russian layouts. On
launch, XPS reads the active layout of Hyprland's main keyboard and selects the
matching layout inside the new Wolf compositor over the direct LAN SSH path.
A connected US Glove80 has an explicit device-name override because Hyprland
can keep the laptop keyboard marked as main; otherwise Norwegian keyboards
start Norwegian and the currently selected US layout starts US.
Press `Alt+Shift` inside the session to cycle the exposed layouts. The launch
hook supplies the state that Moonlight's scan-code protocol does not transport;
one Helium entry is retained so every layout uses the same persistent profile.
Right Alt remains the LevelThree modifier, so Norwegian combinations such as
`AltGr+2` reach the browser as `@`.

XPS retains separate `couch`, `merged`, and normal `desktop` profiles. The
merged profile is the media-center default in use here; desktop mode remains a
recovery and workstation option rather than changing the couch configuration.

## Direct-display sessions

XPS also exposes one-at-a-time direct-display sessions for public Helium, the
protected browser selector, and Steam. These reuse the shared Nixbox
session/recovery lifecycle, but XPS snapshots the currently focused powered
output before leaving Hyprland. The generated Qt KMS configuration selects the
Intel DRM device, keeps that output at its current pixel dimensions, and turns
off the other connected outputs until Moonlight exits. The remote source can
remain at 1440p regardless of whether the selected TV is currently using
1440p60 or 1080p60.

Direct mode is an alternative presentation path, not another concurrent local
window. Entering it restarts the graphical session and therefore closes the
local composited Moonlight clients. Remote browser capsules and persistent
profiles remain server-side. A normal direct exit returns to the prior profile;
merged mode then relaunches public Helium automatically, while the protected
client is reopened explicitly.

Host-local DMS, KDE Connect, and Waynergy are compositor-bound and intentionally
stop during direct display. KDE Connect running inside the remote Helium
capsule remains available through the stream. Physical keyboard, pointer, and
controller input also continue to reach Moonlight directly. The normal
`merged` path remains the choice for host-local phone or Synergy input.

```sh
# Start a one-shot session on the currently selected TV.
xps-session-mode direct-browser
xps-session-mode direct-private
xps-session-mode direct-stream

# Force recovery to the normal XPS media-center profile.
xps-session-mode merged
```

The session switch is boot-scoped. A stale one-shot direct request cannot
reopen after a reboot; XPS returns to its configured `merged` default.

## Command-line status

These commands report the current persisted choices without changing them:

```sh
xps-session-mode
couch-display-layout status
couch-display-mirror status
couch-audio-output status
```

The on-screen controls are the preferred couch interface; the commands are a
keyboard maintenance fallback.
