# T3 Code package selection

Select the package for the existing headless service:

```nix
services.t3code = {
  channel = "fork"; # or "upstream"
  forkReleaseChannel = "nightly"; # or "stable"
};
```

`upstream` selects `pkgs.t3code`, the published upstream nightly.
`fork` with `nightly` selects `pkgs.t3code-fork`, the compatibility alias for
`pkgs.t3code-fork-nightly`. `fork` with `stable` selects
`pkgs.t3code-fork-stable`. Both fork channels apply the same maintained feature
changes to exact published upstream release commits. They do not follow raw
upstream `main`.

The packages come from the pinned `nix-packages` input. Select a revision that
exports the requested package before switching to stable. An explicit
`services.t3code.package` override still takes precedence.

Hourly discovery checks for newly published releases and tested fork promotions.
Unchanged candidates skip builds. Each fork channel advances only after its
validation passes; a conflict leaves that channel's last tested revision in place.
Package and consumer validation still gate deployment.

Apply the configuration through the usual Home Manager activation. Changing
channels preserves the service name, address, port, and state directory. The
existing idle-turn and service-cgroup guards still govern restarts. An explicit
stable/nightly switch permits a different release version, while accidental
downgrades within the selected channel remain blocked. Legacy `fork` channel
state is treated as nightly for the downgrade guard.

With `autoUpdate.enable`, T3 and its providers run from the
`~/.local/state/nix/profiles/ai-stack` profile instead (ADR-0077). Home Manager
seeds it on first deployment or a channel change; afterwards
`t3code-auto-update` builds the `ai-stack-<channel>` bundle from the
nix-packages `promoted` branch, which moves only after local configuration
validation (ADR-0080), and `t3code-ai-stack-switch` installs it, refusing same-channel downgrades and
restarting T3 only when it is idle. Neither runs Home Manager activation. Roll
back with `nix-env --profile ~/.local/state/nix/profiles/ai-stack --rollback`
followed by `systemctl --user restart t3code`. A new fork revision must be
promoted in `nix-packages` before that channel receives it. Returning to
upstream is the same configuration change in the opposite direction.

Qualify patches against the selected upstream version before sharing state:
start upstream, apply the fork, and reopen with upstream using disposable test
data. This is a package compatibility check, not a second production instance.
