# Workstation Home Manager composition

`../xyz.nix` selects imports, host policy, programs, and user services.
`desktop-helpers.nix` constructs the mail workspace, window close, primary
output, game geometry, and drop-down terminal helpers with explicit package
and geometry-policy inputs. Their service registration remains in the parent
host module.

`t3code.nix` owns the workstation's T3 service policy, web launcher, command
aliases, and desktop entry.

Keep these helpers with the workstation configuration they implement. Shared
behavior should move into a generic module only when its callers and interface
are established.
