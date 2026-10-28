# ADR-0046: Remotely managed family gaming laptop

**Status:** Accepted; onboarded, `family-gaming` package set and Netbird-only SSH not yet in place
**Date:** 2026-05-11
**Amended:** 2026-10-28
**History:** [replaced text](archive/0046-remotely-managed-family-gaming-laptop-history.md)
**Applies to:** `inventory.nix`, `hosts/madsil`, `users/madsil`, `modules/nixos/services/netbird`, `modules/home-manager/`

## Context

An older laptop is managed remotely for family use. The primary user is not
the operator. The intended workload is ordinary desktop use plus old Windows
games through Heroic Launcher.

The machine should be reachable for support, but it should not become part of
the trusted infrastructure fleet. It should use Netbird in an isolated posture
so the operator can SSH into it when needed without giving the laptop broad
access to private infrastructure.

The user should have a separate account and should not inherit operator
secrets, infrastructure repositories, Kubernetes credentials, Forgejo operator
tokens, Cloudflare tokens, or normal admin source workspaces.

## Decision

The laptop is the `madsil` host, with the `family-gaming` inventory role and
its own host profile (`hosts/madsil`). It was onboarded in May 2026
([#77](https://git.alc.xyz/alcxyz/nix-config/issues/77)).

The profile includes:

- a desktop session set up in `hosts/madsil` (it does not import the shared
  `modules/nixos/common/desktop.nix` role)
- Heroic Launcher (as a Flatpak) and the gaming runtime it needs; Steam is
  enabled and sideloaded Windows games run on Proton
- GPU and hardware support from the host's hardware configuration and its
  private hardware module
- Netbird client configured for an isolated support network
- OpenSSH enabled for operator support
- an operator account for maintenance, with a minimal Home Manager profile
- a separate family user account for daily use, with its own Home Manager
  profile in `users/madsil/`
- no source workspace bootstrap (the role has no workspace profiles)
- no k3s membership
- no Longhorn prerequisites
- no Forgejo Actions runner
- no operator SSH identities except the minimum needed for support; not yet
  fully in place, since `inventory.nix` sets `forwardAgent = true` for madsil,
  so the operator's SSH agent is forwarded to it
- no Kubernetes client credentials by default

Remote access policy:

- inbound SSH should be allowed only through Netbird or a tightly scoped
  management path; deploys reach the host over Netbird. Public configuration
  does not yet narrow it: the common module opens SSH on every interface and
  `hosts/madsil` does not restrict it
- the family user has no passwordless administrative access by default and is
  not in `wheel`
- the operator account may be in `wheel`
- support credentials should be stored in `nix-secrets` with a separate scope
  from infrastructure and operator automation secrets
- Netbird policy should isolate this host from normal infrastructure machines
  except for explicit operator-to-laptop support access

Package policy:

- install consumer/gaming packages through the `family-gaming` Home Manager
  package set, not the workstation or infra-admin package set. This is not yet
  in place: the family user's Home Manager profile does not use the
  `family-gaming` set, and the host installs the `workstation` system package
  set that its inventory role names
- avoid installing Kubernetes, cloud, CI, and infrastructure administration
  tooling
- keep browser, audio, input, gamepad, and graphics support boring and reliable

`alc.host` exposes the host's role and inventory facts to its NixOS modules;
neither madsil Home Manager profile imports it. The host sets `deployAll = false` in `inventory.nix`, so
`deploy --all` leaves it out and it needs `deploy madsil`.

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

The host composes two users: the family user and the operator, beyond the
single-primary-user model of the other hosts.

Inventory marks lower-trust remote support clients through the `family-gaming`
role; a separate support-posture fact is still open under ADR-0044.

Home Manager builds a simple family user profile without operator packages,
secrets, and workspace sync.

Netbird policy is part of onboarding and maintenance. The Nix host config
installs and runs Netbird, but isolation must be enforced in Netbird
management policy as well.

The machine remains supportable without becoming an infrastructure dependency.
