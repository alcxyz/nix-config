# XPS media center

XPS provides a controller-first Hyprland session for couch browsing and
Moonlight streaming. The persisted `merged` profile adds an auto-hiding DMS
shell without making the remote stream host a boot dependency.

Open DMS's native on-screen control reference at any time with `Super+H` or by
holding `Minus+B` on the Switch Pro controller. DMS places the modal on the
currently focused display and uses couch-scaled typography; repeat the shortcut
to close it.

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
| `solo-primary` | Use only the largest TV-class output |
| `solo-secondary` | Use only the second TV-class output |
| `solo-tertiary` | Use the auxiliary display, with a TV fallback |

The dual-TV layout assigns workspaces 1–3 to the primary TV and 4–6 to the
secondary TV. Workspaces without an active dedicated display fall back to the
primary output. Parked displays are moved outside the usable desktop before
DPMS is disabled, preventing the cursor from disappearing onto them.

Cable presence is detectable, but panel power is not reliable through every
adapter. Use an explicit layout when a connected television remains visible to
Linux while powered off.

Mirroring is separate from layout selection. XPS uses a supervised fullscreen
`wl-mirror` client from the primary TV to the secondary TV, including when their
resolutions match; native Hyprland mirroring left the physical source blank on
this connector pair. The selected mirror state persists across reboots until
toggled again.

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
keyboard, clicks, scrolling, and pointer movement. The protected Brave launcher
opens an encrypted profile after a password prompt; normal browsing remains
available without unlocking it. Browsers use Hyprland's normal tiled layout;
they do not request browser-level fullscreen, avoiding its broken couch pointer
and click behaviour. Their chrome and page contents use a couch-friendly 1.5x
device scale; use `Super+Enter` only when fullscreen is explicitly wanted.

XPS retains separate `couch`, `merged`, and normal `desktop` profiles. The
merged profile is the media-center default in use here; desktop mode remains a
recovery and workstation option rather than changing the couch configuration.

## Command-line status

These commands report the current persisted choices without changing them:

```sh
xps-session-mode
couch-display-layout status
couch-audio-output status
```

The on-screen controls are the preferred couch interface; the commands are a
keyboard maintenance fallback.
