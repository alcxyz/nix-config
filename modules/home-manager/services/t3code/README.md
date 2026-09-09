# T3 Code package selection

Select the package for the existing headless service:

```nix
services.t3code.channel = "upstream"; # or "fork"
```

`upstream` selects `pkgs.t3code`; `fork` selects `pkgs.t3code-fork`.
Both come from the pinned `nix-packages` input and share its build recipe.
The fork package carries the reviewed patches and its own source pin.
An explicit `services.t3code.package` override still takes precedence.

The consumer lock must first be updated to a promoted `nix-packages` revision
that exports both packages. After that one-time adoption, changing channels
does not require changing the lock or the service wiring.

Apply the configuration through the usual Home Manager activation. Changing
channels preserves the service name, address, port, and state directory. The
existing idle-turn and service-cgroup guards still govern restarts. Changing
channels deliberately permits a different release version; accidental
version downgrades within the same channel remain blocked.

Unattended updates refresh packages inside the active configuration snapshot,
so they retain its selected channel. A new fork revision must be promoted in
`nix-packages` before that channel receives it. Returning to upstream is the
same configuration change in the opposite direction.

Qualify patches against the selected upstream version before sharing state:
start upstream, apply the fork, and reopen with upstream using disposable test
data. This is a package compatibility check, not a second production instance.
