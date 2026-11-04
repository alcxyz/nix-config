# ADR-0070: Action-bound credential consent

**Status:** Accepted
**Date:** 2026-09-09, amended 2026-11-04 (the prompt text travels in the Polkit
message, since Polkit does not pass caller details to an agent), updated
2026-11-04 (an optional remote answer, per nix-packages ADR-0018; the requester's
name and link, at the operator's request)
**History:** [replaced text](archive/0070-action-bound-credential-consent-history.md)
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

Polkit passes an authentication agent only the message and the caller and
subject PIDs, never the caller's details (`get_localized_data_for_challenge` in
Polkit 127; confirmed on 2026-11-04 with a process-bound test agent against the
running daemon). It does expand `$(key)` in the message from those details, and
does not rescan what it inserts.

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
time, and user ID. It passes up to six bounded, single-line details to Polkit:

| Detail | Meaning |
|---|---|
| `credential.title` | Short prompt title |
| `credential.reason` | Why the credential is needed |
| `credential.impact` | Expected externally visible effect |
| `credential.operation` | Reviewable operation label, including a plan identity when available |
| `credential.requester` | The asking T3 thread from `T3CODE_THREAD_ID`, by name when known, or that there is none |
| `credential.requester_link` | A link ending in that thread's ID, only when known |

The helper's optional `requesterCommand` turns the thread's ID into its name and
link. Without a usable answer the prompt shows the ID, and a shown link holds it.
DMS shows the link's address and opens it on a click.

It also passes `polkit.message`, a fixed template of those details, one per line
in that order. Polkit expands it, so text in a value can neither change the
template nor hide a later line, and an agent that shows the message in full shows
the whole request. A requester that is not a plain ID is shown as unreadable. Any
process can set the variable, and an agent can name its thread, so the requester identifies a thread
for the operator and proves nothing.

The helper only returns a decision. It does not elevate, execute a
caller-supplied command, locate a credential, or read credential material.

With `security.credentialConsent.remote` enabled, the helper also waits for a
pinned passkey through `credential-approval`
([nix-packages ADR-0018](https://git.alc.xyz/alcxyz/nix-packages/src/branch/dev/docs/adr/0018-passkey-credential-approvals.md)).
Both ways of answering start together and the first answer wins: Polkit cancels
the local prompt when its `pkcheck` ends, and the remote request is withdrawn
when the local prompt answers. A way that cannot run is not an answer, so a local
"no" for an inactive session, or a remote path that cannot start, leaves the other
open. The request ends after `remote.timeoutSeconds`. A broker that waits for the
helper must wait longer than that.

The existing DMS Polkit agent reads these fields from the message lines only for
this exact action, in a taller scrollable prompt. It treats every supplied field
as plain text and keeps ordinary Polkit and `dms-elevate` prompts on their
existing paths.

Private policy decides which credentials need consent and which broker
operations are allowed. Private wiring must prepare an immutable or otherwise
stable operation before asking, and may access credential material only after a
successful decision. Credential values must stay out of arguments, prompt
details, logs, and public configuration.

## Alternatives considered

- **Reuse `dms-elevate` and `pkexec`.** This would couple credential use to root
  execution even when the operation needs no local privilege.
- **Use a runtime context file.** The existing elevation context is associated
  with `pkexec`; the action-bound Polkit message binds this prompt to the request
  and avoids another side channel.
- **Read the details in the agent.** This was the first design, with a Quickshell
  patch that exposed them, and the prompt stayed generic because Polkit never
  sends them to the agent. Both that patch and the code reading the details are
  gone.
- **Build the message in the helper.** Polkit would still expand `$(key)` in it,
  so text containing an unclosed `$(` would hide everything after it.
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
- Remote answers are off by default. Enabling them needs a pinned passkey, and
  with them on, Polkit's action defaults govern only the local prompt.

## Tracking

- [Issue #338](https://git.alc.xyz/alcxyz/nix-config/issues/338) tracks the public
  action, helper, module, and DMS UI.
- Private broker policy and credential wiring are tracked in the private
  repository.
