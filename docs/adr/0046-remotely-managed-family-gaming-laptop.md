# ADR-0046: Remotely managed family gaming laptop

**Status:** Accepted (prepared; host not onboarded)
**Date:** 2026-05-11
**Applies to:** `inventory.nix`, `hosts/`, `users/`, `modules/nixos/services/netbird`, `modules/nixos/common/desktop.nix`, `modules/home-manager/`

## Context

An older laptop will be managed remotely for family use. The primary user is
not the operator. The intended workload is ordinary desktop use plus old
Windows games through Heroic Launcher.

The machine should be reachable for support, but it should not become part of
the trusted infrastructure fleet. It should use Netbird in an isolated posture
so the operator can SSH into it when needed without giving the laptop broad
access to private infrastructure.

The user should have a separate account and should not inherit operator
secrets, infrastructure repositories, Kubernetes credentials, Forgejo operator
tokens, Cloudflare tokens, or normal admin source workspaces.

## Decision

Create a separate family-gaming host profile before onboarding the laptop.

The profile should include:

- NixOS desktop baseline
- Heroic Launcher and required gaming runtime packages
- GPU support appropriate to the hardware after inspection
- Steam/Proton-related compatibility packages only if needed
- Netbird client configured for an isolated support network
- OpenSSH enabled for operator support
- an operator account for maintenance
- a separate family user account for daily use
- minimal source workspace or no workspace bootstrap
- no k3s membership
- no Longhorn prerequisites
- no Forgejo Actions runner
- no operator SSH identities except the minimum needed for support
- no Kubernetes client credentials by default

Remote access policy:

- inbound SSH should be allowed only through Netbird or a tightly scoped
  management path
- the family user should not have passwordless administrative access by default
- the operator account may be in `wheel`
- support credentials should be stored in `nix-secrets` with a separate scope
  from infrastructure and operator automation secrets
- Netbird policy should isolate this host from normal infrastructure machines
  except for explicit operator-to-laptop support access

Package policy:

- install consumer/gaming packages through a family gaming package set, not the
  workstation or infra-admin package set
- avoid installing Kubernetes, cloud, CI, and infrastructure administration
  tooling
- keep browser, audio, input, gamepad, and graphics support boring and reliable

## Implementation Status

Prepared in this repository:

- inventory role vocabulary includes `family-gaming`
- package sets include a `family-gaming` Home Manager package set for a
  consumer desktop/gaming client without operator-heavy tooling
- `alc.host` can expose the eventual host role and inventory facts to NixOS and
  Home Manager modules

Not implemented yet:

- the family laptop is not present in `inventory.nix`
- no host skeleton exists under `hosts/`
- no separate family user profile exists
- Netbird isolation policy still needs to be enforced outside this repository
- support-scoped secrets still need to be created in `nix-secrets`

## Follow-up Issues

- [#77](https://git.alc.xyz/alcxyz/nix-config/issues/77) Onboard the remotely
  managed family gaming laptop.

## Alternatives Considered

**Use the normal workstation role** - rejected. The workstation role carries
operator assumptions, source workspaces, and tooling that are unnecessary and
too broad for a family client.

**Manage the laptop manually outside Nix** - rejected. The whole point of the
host is reliable remote maintenance, repeatable recovery, and controlled access.

**Put the family user on the same account model as `alc`** - rejected. User
identity, secrets, SSH keys, shell config, and workspace layout are different
concerns. The family user should have a simple desktop profile.

**Join the laptop to Kubernetes or Longhorn opportunistically** - rejected. It
is a lower-trust, intermittently used client machine. It should not participate
in cluster scheduling or storage.

## Consequences

This host needs multi-user support in the Nix config beyond the current
single-primary-user model.

Inventory needs a role or flags for lower-trust remote support clients.

Home Manager config needs to be able to build a simple family user profile
without operator packages, secrets, and workspace sync.

Netbird policy becomes part of the onboarding checklist. The Nix host config
can install and run Netbird, but isolation must be enforced in Netbird
management policy as well.

The machine remains supportable without becoming an infrastructure dependency.
