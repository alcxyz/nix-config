# Configuration validation

Run `bash scripts/ci/check-configurations.sh` from the candidate checkout.
It evaluates checks for every declared platform, explicitly forces every
exported NixOS, Home Manager and Darwin deployment, then builds native checks.
It refuses lock updates. The two phases do not deploy hosts or prove runtime
behavior, and foreign-platform check builds remain separate.

The Forgejo configuration workflow checks the exact PR head for `dev` and
`main`, and also runs after pushes to those branches. A missing prerequisite
fails the job. A contribution from a fork must first be reviewed and staged on
a maintainer-owned branch for full configuration validation. The workflow does
not use `pull_request_target` to execute proposed code.

Full evaluation requires authorized access to the locked inputs. Source-access
provisioning and private diagnostic procedures are owned by the private
repository. The public workflow reports pass/fail and the tested source
revision; detailed output is not published because evaluation can contain
private configuration. Reproduce a failure at that exact revision in the
authorized development environment.

For package input promotion, `scripts/ci/verify-ai-package-stack.sh flake.lock`
validates the standalone producer and the candidate consumer separately before
the updater can publish success. A package version string or a source-text
match is insufficient: the consumer can override dependency inputs.

[ADR-0067](adr/0067-explicit-consumer-and-platform-validation.md) defines the
contract. [Issue #274](https://git.alc.xyz/alcxyz/nix-config/issues/274) tracks
ordinary PR rollout; [issue #275](https://git.alc.xyz/alcxyz/nix-config/issues/275)
tracks consumer validation. Until the full workflow has passed with its
provisioned prerequisites, ordinary PR automation remains incomplete.
