# ADR-0102: View and drive xyz's live desktop through a loopback wayvnc

**Status:** Accepted
**Date:** 2026-10-26
**Amended:** 2026-10-31, start on another output when the preferred one is missing.
**Amended:** 2026-10-31, `remote-desk` moves the desktop to a virtual output sized for the Mac.
**Amended:** 2026-10-31, the virtual output follows the viewer's window size.
**Applies to:** `modules/home-manager/services/remote-view/`, `users/alc/linux/xyz.nix`, `hosts/xyz/configuration.nix`, `hosts/mac/configuration.nix`

## Context

All work runs on xyz, including when the operator is away from home and works
from the Mac. Several steps then still need xyz's own screen: the credential
consent dialog (ADR-0070), the Hyprlock lock screen, the keyring unlock prompt
after a reboot, and browser sign-ins that open on xyz. SSH reaches xyz from
anywhere over NetBird, but none of these can be answered over SSH, and the
existing ways in (Synergy, ADR-0054; KDE Connect) send input without showing
the screen and only work nearby.

Agents on xyz run as the operator's own Unix user. A remote view should
therefore not let a local process drive the desktop merely because it can
reach a local socket. That is an accident guard, not a boundary: under the
same-user limit that the agent decisions accept (recorded in a private
repository), a process running as the operator can already capture the
screen and inject input through the compositor's own protocols, read the
server's key, or stop the server and listen in its place.

## Decision

Run wayvnc in the Hyprland session through a small Home Manager module,
`services.remoteView`:

1. wayvnc listens on `127.0.0.1` only. The Mac reaches it through an SSH
   tunnel over NetBird (`ssh -N -L 5900:127.0.0.1:5900 xyz`), so no new port
   is exposed on any network and access rides on the existing SSH keys.
2. Every VNC session authenticates with the operator's own password through
   PAM (`security.pam.services.wayvnc`) and is encrypted with RSA-AES. The
   RSA key is generated on xyz at first start and never leaves it; the viewer
   pins it on first use.
3. It starts with the graphical session and captures the primary ultrawide
   (`DP-1`) when that output is present, and otherwise the output wayvnc
   picks. The ultrawide disconnects when it sleeps deeply enough, which
   removes its output, and wayvnc refuses to start on a missing output.
   `wayvncctl output-set` or `output-cycle` switches outputs while connected.
4. The Mac uses TigerVNC Viewer (Homebrew cask), which supports RSA-AES.
5. The 5120x1440 ultrawide is too wide to work on from the Mac's screen, so
   `remote-desk on` (run over SSH) creates a virtual output named
   `HEADLESS-REMOTE`, starting in `deskMode` (2056x1262 on xyz, TigerVNC's
   picture area when tiled on the Mac), points wayvnc at it and disables the
   physical outputs, including the known ones
   that are disconnected at the time (`physicalOutputs`), so a display that
   wakes stays dark. Hyprland then moves every workspace to it, and nothing
   shows at home. `remote-desk off` reloads the compositor config, which
   restores the physical outputs with their own rules and returns each
   workspace to its monitor (after restarting wayvnc, see Consequences), then removes the virtual output; if no display
   is connected yet, it keeps it until the next `off`. wayvnc resizes
   outputs named `HEADLESS-*` to the viewer's window when the viewer asks,
   which TigerVNC does by default, so the desk follows the window. On xyz,
   Super+Ctrl+Shift+Escape runs `remote-desk off`, also from the lock
   screen, for getting the displays back without seeing them.

The consent dialog keeps its rules. The request still comes from the active
local session, and approving it still takes the operator's password in the
dialog; the remote view only carries the operator's own keystrokes to it. As
with the dialog itself, this protects against an agent approving its own
request, not against a deliberately hostile process running as the operator.

## Alternatives Considered

- **RustDesk.** On Hyprland it needs the RemoteDesktop portal for input, which
  xdg-desktop-portal-hyprland does not provide, and portal sessions are
  approved on the local screen, which is exactly what is unavailable remotely.
  ADR-0012 already noted its weaker Wayland support.
- **wayvnc on the NetBird interface.** Simpler to connect, but it exposes a
  desktop-control service to every NetBird peer and adds a second network
  policy to maintain. The SSH tunnel reuses the access control that already
  exists.
- **No VNC authentication on loopback.** Any process running as the operator,
  agents included, could connect and drive the desktop by mistake. Rejected.
- **A separate password stored for wayvnc, or legacy DES for macOS Screen
  Sharing.** A stored password is readable by every process running as the
  operator, so it would not even stop an accidental connection; DES also
  provides no encryption and truncates the password. PAM reuses the
  operator's existing password, which agents are not given.
- **wayvnc under a dedicated user.** It would keep the key and the service out
  of the operator's reach, but needs cross-user access to the Wayland socket,
  and same-user processes would still have the compositor's own capture and
  input protocols. Not worth it while the same-user limit stands.
- **A fixed mode only.** The viewer's picture area changes with its window
  state (tiled, resized, full screen), and a fixed mode that is too large
  means scrolling. wayvnc's resize also moves the output to 0,0, but that
  only overlaps the physical outputs, which are off while the desk is on.
- **Keeping the physical outputs on and moving chosen workspaces.** Dialogs
  and new windows could open on an output the viewer cannot see, and the
  pointer could leave the view.
- **A second, headless session (ADR-0012 style).** It cannot show the dialogs
  and lock screen of the live session, which is the point.

## Consequences

- The operator can approve consent prompts, unlock Hyprlock and the keyring,
  and finish browser sign-ins on xyz from anywhere SSH works.
- Sign-ins that need a nearby phone, such as hybrid passkeys checked over
  Bluetooth, still cannot be completed through the view.
- After the lock screen turns the displays off, input through the view should
  wake them through the same idle path as local input; if it does not, they
  can be woken over SSH through Hyprland's DPMS dispatch. Verify this, and
  typing into Hyprlock through the view, before relying on it.
- Every resize wayvnc applies through output management also marks the
  outputs that are off at the time as disabled, and Hyprland keeps that mark
  over the config rules for as long as wayvnc stays connected, across
  reloads and reconnects. `remote-desk off` therefore restarts wayvnc before
  reloading, which drops the viewer. The same mark means a config reload
  while the desk is on (for example a Home Manager deploy) usually keeps the
  physical outputs off and the desk at the viewer's size; before the viewer
  has resized the desk, a reload brings the physical outputs back and
  resets the desk's mode. A Hyprland restart always brings them back and
  removes the desk. Either way, run `remote-desk on` again.
- Removing the last output makes wayvnc exit and drop the viewer, so
  `remote-desk` never removes the virtual output while the physical outputs
  are off.
- Unlocking the lock screen and approving the consent dialog through the
  desk were verified on 2026-10-31. Hyprlock's display-off helper remembers
  the outputs of the lock it started in, so switching `remote-desk` while
  locked can leave displays it no longer covers on, or retry ones that are
  disabled, until the next unlock.
- Only one output is visible at a time, and viewing quality depends on the
  link; VNC sends only changed regions. When the captured output disappears,
  wayvnc moves to another one and stays there after the first returns, so
  switch back with `wayvncctl output-set DP-1` over SSH. Whether the view
  still works with every display asleep and disconnected is not yet verified.
- The service runs, and restarts, whenever the session is up. Its exposure is
  the loopback socket, guarded by the operator's password; there is no
  lockout after failed attempts.
- A process running as the operator could stop the server and impersonate it
  with its key to capture what the operator types through the view, including
  that password. This is accepted under the same-user limit, as for the
  consent dialog, which such a process could imitate as well.
