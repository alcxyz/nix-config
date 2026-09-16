# ADR-0003: Runtime secret deployment with sops-nix

**Status:** Accepted, redacted
**Date:** 2026-04-18
**Applies to:** common NixOS and Home Manager configuration, private identity policy

## Context

System and user services need structured encrypted configuration deployed at
activation time without placing plaintext values in the Nix store. Identity
availability must match the system and user activation lifecycles.

## Decision

Use `sops-nix` for runtime secret deployment with age identities derived from
system SSH host keys on NixOS. Encrypted source ownership,
decryption identity configuration and SSH identity projections live in the
private `sshIdentityPolicy` modules for NixOS and Home Manager. Public common
modules import these named interfaces.

System-managed identities remain available independently of Home Manager
activation. Linux and Darwin retain their existing platform-specific identity
lifecycles. Private operational documentation owns provisioning, recipient
management and recovery procedures.

## Alternatives Considered

- **Single-file secret deployment tools:** simpler, but structured YAML and
  templating better fit the existing multi-service configuration.
- **A separate online secret service:** adds operational dependencies beyond
  the current requirements.
- **One identity lifecycle for every platform:** would obscure differences
  between system and user activation.

## Consequences

Plaintext secret material remains outside source evaluation and the Nix store.
Source extraction must preserve encrypted source contents, projection metadata
and activation dependencies. Evaluation does not prove secret validity or
runtime activation; those remain separate checks.

The original operational record is preserved in the private SSH access-policy
runbook. Current-tree redaction does not erase earlier published versions;
historical review remains in the private audit.
