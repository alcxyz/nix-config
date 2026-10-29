# ADR-0102: View and drive xyz's live desktop through a loopback wayvnc

**Status:** Accepted
**Date:** 2026-10-26
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
   (`DP-1`); `wayvncctl output-cycle` switches outputs while connected.
4. The Mac uses TigerVNC Viewer (Homebrew cask), which supports RSA-AES.

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
- Only one output is visible at a time, and viewing quality depends on the
  link; VNC sends only changed regions.
- The service runs, and restarts, whenever the session is up. Its exposure is
  the loopback socket, guarded by the operator's password; there is no
  lockout after failed attempts.
- A process running as the operator could stop the server and impersonate it
  with its key to capture what the operator types through the view, including
  that password. This is accepted under the same-user limit, as for the
  consent dialog, which such a process could imitate as well.
