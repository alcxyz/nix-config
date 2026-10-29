# Workstation Home Manager composition

`../xyz.nix` selects imports, host policy, programs, and user services.
`desktop-helpers.nix` constructs the mail workspace, window close, primary
output, game geometry, and drop-down terminal helpers with explicit package
and geometry-policy inputs. Shell bodies live in adjacent `desktop-scripts/`
files; Nix binds the geometry policy before the guard body. The parent
`../xyz.nix` passes the helpers to their users; `gaming/desktop.nix` registers
the XWayland primary-output and game-geometry guard user services.

`gaming/` holds the direct game launchers (`default.nix`) and the gaming window
rules and services (`desktop.nix`). `hyprland-contract.nix` holds the Hyprland
assertions, and `nautilus.nix` keeps the Nautilus renderer workaround local.

`t3code.nix` owns the workstation's T3 service policy, the launchers and
desktop entries, and the command aliases. `t3code` opens the desktop app as a
client only: it keeps its state in `~/.t3-desktop`, its own server stays off,
and it reaches the headless servers over loopback (`127.0.0.1:3773`, and
`127.0.0.1:3774` for work), each added once under Settings > Connections with a
token from `t3 pair` (`t3 pair --base-dir ~/.t3-bn` for work). `t3code-web`
and the work web entry open the browser routes.

Keep these helpers with the workstation configuration they implement. Shared
behavior should move into a generic module only when its callers and interface
are established.
