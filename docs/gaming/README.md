# Gaming configuration map

Source inventory reviewed on 2026-09-14. This document maps existing ownership
and gaps; it does not introduce a gaming profile or change runtime behavior.
"Declared" means present in configuration, not verified installed or running.
The review covers tracked configuration and tooling, not personal game libraries,
installer media, credentials, or mutable application data.

## Repository ownership

| Repository | Responsibility |
| --- | --- |
| `nix-config` | Public host/user configuration, application launchers, generic module interfaces, client integration, and acceptance checks. |
| `gitops` | Steam streaming Docker deployment and deployment policy; inspect its own ADRs before changing streaming services. |
| `nix-packages` | Reusable public packages and installation tooling. No dedicated gaming implementation was found in its current package catalog. |
| `nix-secrets` | Private defaults, secret wiring, endpoints, and operational documentation. Private values are intentionally outside this map. |

System and Home Manager settings are separate composition layers. Package lists
remain centralized in [pkgsets.nix](../../modules/shared/pkgsets.nix), following
[ADR-0006](../adr/0006-four-tier-module-layering.md) and
[ADR-0008](../adr/0008-pkgsets-centralised-package-management.md).

## Local games and launchers

| Component | Existing configuration | Status and next gap |
| --- | --- | --- |
| Gaming package selection | [Shared package catalog](../../modules/shared/pkgsets.nix): `hm.gaming`, workstation and family-gaming compositions | Includes Heroic, Gamescope, MangoHud, Crosspipe, and Moonlight. A package selection is not a complete gaming configuration. |
| Steam desktop | [xyz host](../../hosts/xyz/configuration.nix), [madsil host](../../hosts/madsil/configuration.nix) | Steam is enabled on both. GameMode is explicitly enabled on madsil; policies differ by host. |
| Direct Battle.net and Heroes Profile | [xyz user](../../users/alc/linux/xyz.nix), [UMU module](../../modules/home-manager/programs/umu-apps/default.nix), [runner implementation](../../modules/home-manager/programs/umu-apps/application.nix) | Declarative Proton selection, launch environment, shared prefix, and service lifecycle exist. User confirmed Heroes of the Storm gameplay/input during the current compatibility work; broader qualification remains open. |
| Heroic fallback | [xyz host](../../hosts/xyz/configuration.nix), [Heroic sideload module](../../modules/nixos/services/heroic-sideload/default.nix) | Existing Battle.net installation is registered with `manageGameConfig = false`; its per-game settings remain mutable. Both a package-catalog entry and Flatpak declarations exist. Their future disposition is unresolved. |
| Totem Quest | [xyz host](../../hosts/xyz/configuration.nix), [madsil host](../../hosts/madsil/configuration.nix) | Both declare a source ZIP and Heroic entry. Installation and gameplay were not revalidated by this mapping. This is an existing example for future installation work. |
| RetroDECK | [xyz host](../../hosts/xyz/configuration.nix) | Flatpak is declared. No dedicated emulator/controller/library/save configuration was found in the searched host, user, module, or documentation sources. Reconfiguration is requested; current mutable state was not inspected. |
| Additional games | No concrete titles or installer inputs supplied yet | Future backlog: identify each title, source media, installation method, runtime, writable data, and acceptance criteria before implementing it. |

The Heroic sideload module can copy a supplied directory or extract a ZIP, merge
managed entries into Heroic's library, optionally write per-game settings, and
create shortcuts. It is an existing import mechanism, not yet a general-purpose
installer executor. The UMU module starts an existing executable and prefix;
it does not install games or provision a new prefix.

Future installation work should distinguish provisioning writable game data
from declaring its launcher. Reusable implementation can belong in
`nix-packages`; host selections and generic configuration interfaces belong here.
This mapping does not select an installer framework or migrate any game data.

## Desktop and streaming integration

| Component | Existing source | Boundary and status |
| --- | --- | --- |
| Gaming desktop behavior | [xyz user](../../users/alc/linux/xyz.nix), [desktop helpers](../../users/alc/linux/xyz/desktop-helpers.nix), [Hyprland contract](../../users/alc/linux/xyz/hyprland-contract.nix) | Game-window matching, workspace rules, geometry recovery, close behavior, and notification suppression exist. These share desktop infrastructure; an extraction must preserve their integration. |
| Steam streaming server | `gitops:docker/xyz/steam/compose.yml` and adjacent helper sources; [xyz host](../../hosts/xyz/configuration.nix), [storage integration](../../hosts/xyz/storage.nix) | Docker deployment lives in gitops; host prerequisites and generic storage integration live here. Runtime health was not checked for this map. |
| Moonlight clients | [Moonlight service](../../modules/nixos/services/moonlight-client/default.nix), [Wolf client](../../modules/home-manager/programs/moonlight-wolf-client/default.nix), [macOS endpoints](../../modules/home-manager/programs/moonlight-endpoints/default.nix) | Client launching, session behavior, and endpoint interfaces are already reusable. Private endpoint values remain outside this guide. |
| Couch and compact clients | [XPS media-center guide](../xps-media-center.md), [compact Nixbox guide](../nixbox-client.md), [Nixbox profiles](../../modules/nixos/profiles/nixbox-client/default.nix) | Existing controller-oriented presentation, input, and audio integration should be reused when designing retro gaming access. This is shared desktop infrastructure, not all exclusively gaming. |
| Wolf streaming | [Wolf module](../../modules/nixos/services/wolf-streaming/default.nix), [worker integration](../../modules/nixos/services/wolf-streaming/worker-runtime.nix) | Existing host-native container orchestration and shared streaming infrastructure. Keep this distinct from the Steam Docker stack; current ownership must be followed rather than assuming all container definitions live in gitops. |

For cross-repository paths, `gitops:` and `nix-packages:` mean paths relative to
those repositories' roots. They identify source ownership, not deployment commands.

The Steam stack's adjacent scripts, supervisor configuration, and Xorg
configuration implement its input integration and belong with its Docker source.
It currently has no stack-local README. Its on-demand client behavior is described
in [ADR-0053](../adr/0053-controller-first-xps-couch-session.md). Wolf browser
streaming has a separate purpose and acceptance contract even where clients overlap.

## Existing acceptance boundaries

- [ADR-0065](../adr/0065-narrow-xyz-game-session-compatibility-repairs.md)
  separates game-specific compatibility repairs from general desktop behavior.
- [ADR-0066](../adr/0066-direct-umu-launchers-with-heroic-qa-fallback.md)
  defines direct-launch lifecycle and the Heroic fallback.
- [Flake checks](../../flake/checks/default.nix) include `umu-apps-contract`,
  Moonlight endpoint checks, and input-source checks. The xyz Hyprland assertions
  also cover gaming integration. No dedicated RetroDECK check was found.
- Wolf browser input/process-lifecycle changes require `just input`, including
  pointer movement and primary clicking, under the repository instructions.
- [Qualification issue #267](https://git.alc.xyz/alcxyz/nix-config/issues/267)
  remains the direct-launch acceptance tracker;
  [#268](https://git.alc.xyz/alcxyz/nix-config/issues/268) owns Heroic disposition.
  A passing game session does not complete every check in that broader matrix.

## Candidates for subsequent work

1. Extract existing host and user gaming settings through ordinary imports,
   preserving evaluated configuration and the current acceptance boundaries.
   The proposed host gaming module and user gaming directory do not exist yet.
2. Inventory RetroDECK's current mutable state, then decide ownership of emulator
   settings, controller mappings, library references, and save integration.
3. Select one additional game with supplied installation media to establish a
   repeatable installation and launch pattern alongside the Totem Quest example.
4. Review shared needs across workstation, family-gaming, and streaming clients
   before introducing a common gaming profile.

These are mapped opportunities, not authorization to refactor, install, or deploy.
