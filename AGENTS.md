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
