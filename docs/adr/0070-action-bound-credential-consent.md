# ADR-0070: Action-bound credential consent

**Status:** Accepted
**Date:** 2026-09-09
**Applies to:** Polkit, DMS, administrative credential brokers

## Context

Some local automation needs a deliberate human decision tied to the exact
proposed use of a protected capability. The existing `dms-elevate` flow
provides a good contextual authentication dialog, but it grants root execution
through `pkexec`. Credential consent does not require root execution: the
requesting process should remain the same unprivileged process and receive only
an authorization result.

Polkit accepts caller-supplied action details only from root or an identity
listed in the action's `org.freedesktop.policykit.owner` annotation. A generic
action therefore needs an explicit list of local owner users; a broad default
would either fail at runtime or make the prompt details spoofable by unrelated
users.

## Decision

Provide the Polkit action `xyz.alc.credentials.use-admin` and a
`dms-credential-consent` helper through an optional NixOS module. Enabling the
module requires at least one explicit, declared local owner user. It does not
select a fleet user by default.

The action permits neither inactive nor non-local subjects. An active local
subject must authenticate as itself (`auth_self`). The action deliberately does
not use an authorization-retaining `_keep` result, so every credential
operation makes a fresh request.

The helper identifies its subject with the process ID, kernel process start
time, and user ID. It passes four bounded, single-line details to Polkit:

| Detail | Meaning |
|---|---|
| `credential.title` | Short prompt title |
| `credential.reason` | Why the credential is needed |
| `credential.impact` | Expected externally visible effect |
| `credential.operation` | Reviewable operation label, including a plan identity when available |

The helper only returns Polkit's decision. It does not elevate, execute a
caller-supplied command, locate a credential, or read credential material.

The existing DMS Polkit agent renders these fields only for this exact action.
It treats every supplied field as plain text and keeps ordinary Polkit and
`dms-elevate` prompts on their existing paths.

Private policy decides which credentials need consent and which broker
operations are allowed. Private wiring must prepare an immutable or otherwise
stable operation before asking, and may access credential material only after a
successful decision. Credential values must stay out of arguments, prompt
details, logs, and public configuration.

## Alternatives considered

- **Reuse `dms-elevate` and `pkexec`.** This would couple credential use to root
  execution even when the operation needs no local privilege.
- **Use a runtime context file.** The existing elevation context is associated
  with `pkexec`; action-bound Polkit details bind this prompt to the request and
  avoid another side channel.
- **Use `auth_self_keep`.** A cached authorization would make a later operation
  proceed without the deliberate prompt required by this policy.
- **Embed private policy in nix-config.** This repository is public and should
  expose only the generic interface and its non-sensitive behavior.

## Consequences

- Brokers get a consistent graphical consent experience without becoming root.
- Each invocation uses a fresh authorization request under the action defaults.
- Host configuration must explicitly enable the module and name its local owner
  users.
- A successful decision authorizes only the broker-defined operation in
  progress; it is not a general grant to use an administrative credential.
- Deploying the module and connecting a private broker remain separate changes.

## Tracking

- [Issue #338](https://git.alc.xyz/alcxyz/nix-config/issues/338) tracks the public
  action, helper, module, and DMS UI.
- Private broker policy and credential wiring are tracked in the private
  repository.
