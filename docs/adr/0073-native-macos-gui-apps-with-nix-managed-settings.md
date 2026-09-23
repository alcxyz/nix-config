# ADR-0073: Native macOS GUI apps with Nix-managed settings

**Status:** Accepted
**Date:** 2026-09-21
**Applies to:** `hosts/mac/configuration.nix`, `users/alc/darwin/mac.nix`, `modules/shared/pkgsets.nix`

## Context

macOS associates app permissions with application identity. Changing Nix store
paths and ad-hoc-signed builds can complicate that identity across upgrades.
We want native application bundles while retaining declarative installation and
configuration. This refines the macOS package boundary in ADR-0008.

## Decision

- Prefer upstream developer-signed GUI bundles installed through Homebrew casks
  into `/Applications`, declared in nix-darwin.
- Keep app settings and shell integration in Home Manager, and CLI tools in Nix
  unless an existing platform-specific decision requires otherwise.
- Enable Homebrew updates and upgrades during nix-darwin activation. Keep
  automatic cleanup disabled while installation ownership is being reconciled.
- Migrate apps individually: preserve profiles, remove the corresponding Mac
  Nix package, and update launchers to use the native bundle. Linux packaging
  remains unchanged.

WezTerm, Brave, Obsidian, Thunderbird, Raycast, Ghostty, and T3 Code use native
bundles. T3 Code follows the upstream nightly cask to retain its existing release
channel; its Linux package and services remain Nix-managed.

The pinned Home Manager WezTerm module requires a package; a small package of
links to the native bundle
preserves its configuration and shell-integration support without installing a
second app. Other GUI apps remain candidates for later review.

## Alternatives Considered

- **Continue installing all GUI apps through Nix:** retains Nix version pinning
  but does not address application identity issues in affected builds.
- **Copy Nix bundles to stable paths:** stabilizes paths but does not by itself
  provide an upstream developer signature.
- **Manage Homebrew manually:** supplies native bundles but leaves installation
  intent outside the repository.

## Consequences

Native app identity is easier to maintain while settings remain declarative.
This reduces a source of permission churn; it does not guarantee that macOS
permission problems disappear or remove existing duplicate entries.

Homebrew app versions are not pinned by `flake.lock`, and Nix rollback does not
roll them back. Apps with their own updaters may update independently. Homebrew
installation and Home Manager configuration must both be applied during setup.
