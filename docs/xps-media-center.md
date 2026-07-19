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
starts with one centered X, separates it into the two NIXBOX X positions,
reveals N/I/B/O and `MEDIA CENTER`, fills the progress track, and raises a faint
Nix watermark behind the completed lockup. Plymouth still starts on the early
firmware surface to cover diagnostic boot. Once the existing display-pipeline
allocator has settled the dock-backed outputs, a boot-only theme reload starts
the bounded eight-second sequence from frame zero on the visible displays.
Before that point, a static Nix/X mark prevents a completed wordmark from
flashing before its own intro. Explicit start and completion stage signals
guarantee the final subtitle, bar, watermark, and quit frame even when the
high-resolution Plymouth renderer advances below its requested refresh rate.

Once Hyprland has a usable output, a distinct NIXBOX Quickshell overlay presents
only the `STARTING SESSION` transition on every active display and fades into
the couch session. It has no loading bar. The overlay never captures input and
has a hard timeout so a display or animation failure cannot delay the browser,
DMS, or controller controls.

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
| `L3+R3` | Stop Moonlight and return to the browser |
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
| `Super+M` / `Super+B` | Start the stream / return to the browser |
| `Super+Shift+M` | Toggle display mirroring |
| `Super+Shift+D` | Cycle display layouts |
| `Super+Shift+A` | Cycle audio outputs |
| `Super+H` | Toggle the on-screen control reference |
| `Super+V` / `Super+Z` | Open a new browser window / protected Brave |
| `Alt+Enter` | Open a terminal |
| `Super+Space` | Open DMS search |
| `Super+Enter` / `Super+S` / `Super+W` | Fullscreen / float / close |
| `Super+1`…`Super+0` | Open workspace 1…10 |
| `Super+J` / `Super+K` | Previous / next workspace |
| `Super+Shift+1`…`Super+Shift+0` | Move the focused window to a workspace |
| `F8` / `F9` / `F10` | Mute / volume down / volume up |
| `Alt+Shift` | Toggle Norwegian and US keyboard layouts |

## Display layouts

The selected layout persists across reboots. `Minus+X` or `Super+Shift+D`
cycles through:

| Layout | Behaviour |
|---|---|
| `adaptive` | Preserve one active output, with the largest connected display as fallback |
| `all` | Enable every connected external display |
| `dual-tvs` | Enable the two TV-class outputs and park the auxiliary display |
| `primary-aux` | Enable the primary TV and auxiliary display |
| `secondary-aux` | Enable the secondary TV and auxiliary display |
| `solo-primary` | Use only the largest TV-class output |
| `solo-secondary` | Use only the second TV-class output |
| `solo-tertiary` | Use the auxiliary display, with a TV fallback |

The dual-TV layout assigns workspaces 1–3 to the primary TV and 4–6 to the
secondary TV. The auxiliary display uses workspaces 7–9 and is placed directly
beside the selected TV when the other TV is parked. Workspaces without an
active dedicated display fall back to the primary output. Parked displays are
moved outside the usable desktop before DPMS is disabled, preventing the
cursor from disappearing onto them.

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
dormant and the remaining display receives all workspace groups; it resumes
when a second eligible display returns.

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
with physical mouse movement over XWayland windows. The protected Brave
launcher opens an encrypted profile after a password prompt; normal browsing
remains available without unlocking it. Its encrypted-profile supervisor runs
as an independent user service, so DMS restarts do not terminate an active
private browser session. Browsers use Hyprland's normal tiled layout; they do
not request browser-level fullscreen, avoiding its broken couch pointer and
click behaviour. Their chrome and page contents use a couch-friendly 1.5x
device scale; use `Super+Enter` only when fullscreen is explicitly wanted.

XPS retains separate `couch`, `merged`, and normal `desktop` profiles. The
merged profile is the media-center default in use here; desktop mode remains a
recovery and workstation option rather than changing the couch configuration.

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
