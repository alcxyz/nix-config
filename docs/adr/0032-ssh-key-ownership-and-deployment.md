# ADR-0032: SSH Key Ownership and Deployment

**Status:** Accepted
**Date:** 2026-05-03
**Applies to:** `modules/nixos/common/default.nix`, `modules/nixos/common/server.nix`, `users/alc/common.nix`, `nix-secrets`

## Context

SSH keys in this setup serve several different purposes:

- inbound login authorization for `alc` and `root`
- per-host private identity for the `alc` user
- operator SSH identities for publishing and deploy workflows
- distributed-build authentication from server hosts to `xyz`

These were previously easy to conflate. Some root host keys were authorized
broadly while trying to make remote builds work, and unmanaged
`~/.ssh/authorized_keys` files contained duplicate entries already declared by
NixOS.

The system needs to support rebuilding machines from the flake, including
`nux`, `rpi0`, and future server hosts that should build on `xyz`, without
spreading root keys or operator private keys more broadly than needed.

## Decision

Inbound SSH authorization is NixOS-managed system policy. It belongs in:

```nix
users.users.<name>.openssh.authorizedKeys.keys
```

The user-level `~/.ssh/authorized_keys` file is not managed by Home Manager and
should not be used for normal declarative access. Existing unmanaged files may
temporarily remain only for extra local entries while they are migrated into
NixOS.

`alc` user private keys are Home Manager/sops-nix managed from per-host SOPS
files:

```text
nix-secrets/hosts/<host>/secrets.yaml
  ssh_id_ed25519
  ssh_id_ed25519.pub
```

Home Manager deploys those to:

```text
~/.ssh/id_ed25519
~/.ssh/id_ed25519.pub
```

Operator SSH identities are stored separately from host-local identities:

```text
nix-secrets/operators/ssh_keys.yaml
```

These are deployed only to hosts that need operator workflows, currently `xyz`.

Distributed-build keys are purpose-specific root-owned keys. Server hosts store
their build-client key in their own host SOPS file as:

```text
ssh_buildhost_xyz
ssh_buildhost_xyz.pub
```

`modules/nixos/common/server.nix` deploys these to:

```text
/root/.ssh/id_buildhost_xyz
/root/.ssh/id_buildhost_xyz.pub
```

`xyz` authorizes only the matching build public keys for `root@xyz`. Generic
`root@host` keys are not used as distributed-build credentials.

## Alternatives Considered

Manage `~/.ssh/authorized_keys` with Home Manager:

Rejected. Inbound SSH authorization is host/system access policy. It should be
present after a NixOS system rebuild even if Home Manager has not run yet.

Reuse normal root SSH keys for distributed builds:

Rejected. Build authentication is a distinct purpose and should have dedicated
keys with narrowly scoped authorization.

Put operator SSH keys in host-specific SOPS files:

Rejected for general operator identities. Host files are appropriate for
machine-local identity; operator keys have a separate lifecycle and should be
auditable as operator credentials. Deployment remains host-scoped from
`nix-config`.

## Consequences

Adding a new server host that should build on `xyz` requires:

1. Generate/import a dedicated build key into `nix-secrets/hosts/<host>/secrets.yaml`.
2. Add the public key to `xyzDistributedBuildClientKeys` in `modules/nixos/common/default.nix`.
3. Ensure the host imports `modules/nixos/common/server.nix`.
4. Rebuild the new host before tightening or relying on `xyz` authorization.

Rebuild ordering matters when rotating build keys:

1. Rebuild build-client hosts first so their new private keys are deployed.
2. Rebuild `xyz` so `root@xyz` authorizes the new public keys.

The model reduces blast radius:

- mobile app keys authorize only `alc`
- human admin keys authorize `alc` and `root`
- distributed-build keys authorize only `root@xyz`
- operator private keys are deployed only to operator hosts

Unmanaged `~/.ssh/authorized_keys` files should be empty or absent once their
remaining extra public keys have been migrated into NixOS.
