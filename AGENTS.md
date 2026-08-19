# Repository Instructions

This repository is public. Keep sensitive infrastructure details out of this
tree, including operational security models, hardware fingerprints, recovery
procedures, secret names, token scopes, private host bootstrap details, and
incident/debug transcripts that reveal exploitable behavior.

Use `nix-config` only for public host and user configuration, generic module
interfaces, and redacted ADRs. Put private runbooks, private module defaults,
secret wiring details, and sensitive implementation notes in the private
`nix-secrets` flake instead.

Do not move sensitive material to `nix-packages`; that repository is public too.

## Wolf browser input changes

Any change to the Wolf browser image's KDE Connect input path or process
lifecycle must pass `just input` before deployment. Pointer movement and primary
clicking are one acceptance contract: do not accept or deploy a change when only
one works.

Keep pointer mirroring, native button delivery, and daemon/bridge startup order
as separate responsibilities. Do not combine input-path changes with unrelated
video, image-hardening, or streaming changes in the same deployment. When
established input behavior regresses, restore the last working path before
attempting another design.
