# Workstation Home Manager composition

`../xyz.nix` selects imports, host policy, programs, and user services.
`desktop-helpers.nix` constructs the mail workspace, window close, primary
output, game geometry, and drop-down terminal helpers with explicit package
and geometry-policy inputs. Service registration remains in the host module.

Keep these helpers with the workstation configuration they implement. Shared
behavior should move into a generic module only when its callers and interface
are established.
