# Configuration validation

Run `bash scripts/ci/check-configurations.sh` from the candidate checkout.
It evaluates checks for every declared platform, explicitly forces every
exported NixOS, Home Manager and Darwin deployment, then builds native checks.
It refuses lock updates. The two phases do not deploy hosts or prove runtime
behavior, and foreign-platform check builds remain separate.

PRs into `dev` run formatting, shell lint, repository hygiene and focused
credential-free CI tests. They do not evaluate deployments or fetch private
flake inputs. This lightweight gate applies to all development changes,
including shared modules and input updates; local validation carries the
integration work during iteration.

Develop on `xyz` and validate the affected configurations and behavior before
merging. Record the commands and results in the PR. For shared composition or
input changes, run the full local configuration check above and the relevant
consumer/package checks. Runtime-sensitive changes retain their acceptance
contracts, including `just input` for Wolf browser input changes.

PRs into `main` and manual workflow runs perform full all-system evaluation and
native checks against the exact candidate revision. A missing prerequisite
fails full validation. Both gates require a reviewed maintainer-owned
branch; the workflow does not use `pull_request_target` to execute proposed
code. There is no duplicate workflow on pushes after a merge. Automated input
updaters retain their existing producer/consumer checks before publication.

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
contract. [Issue #274](https://git.alc.xyz/alcxyz/nix-config/issues/274) records
the completed ordinary PR rollout; [issue #275](https://git.alc.xyz/alcxyz/nix-config/issues/275)
records the changed-lock consumer verification and publication rollout,
including [run 50](https://git.alc.xyz/alcxyz/nix-config/actions/runs/50/jobs/0).
All declared platforms are evaluated, while foreign-platform check builds,
runtime qualification, and private synthetic integration remain separate.
