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

`t3code.nix` owns the workstation's T3 service policy, the web launchers and
desktop entries for each instance, and the command aliases.

Keep these helpers with the workstation configuration they implement. Shared
behavior should move into a generic module only when its callers and interface
are established.
