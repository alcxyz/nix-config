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

PRs into `main` and manual workflow runs accept only the exact trusted `dev`
head and require its successful `ci/local-configurations` commit status. A
scheduled local operator job issues that receipt only after the all-system and
native configuration checks pass. An absent, failed, or older receipt fails the
hosted gate. The workflow does not use `pull_request_target` or send an
untrusted pull-request head to the credential-bearing local job.

Full evaluation requires authorized access to the locked inputs. The trusted
local environment uses its ordinary source access; private scheduling,
credential wiring, diagnostics, and handover procedures are owned by the
private repository. Public hosted CI reads only the exact status receipt.

For package input promotion, `scripts/ci/verify-ai-package-stack.sh flake.lock`
validates the standalone producer and the candidate consumer separately before
the local promoter can publish success. It also rechecks the package update
queue, producer head, and consumer base immediately before its compare-and-swap
push. A package version string or a source-text match is insufficient: the
consumer can override dependency inputs.

[ADR-0067](adr/0067-explicit-consumer-and-platform-validation.md) defines the
contract. [Issue #274](https://git.alc.xyz/alcxyz/nix-config/issues/274) records
the completed ordinary PR rollout; [issue #275](https://git.alc.xyz/alcxyz/nix-config/issues/275)
records the changed-lock consumer verification and publication rollout,
including [run 50](https://git.alc.xyz/alcxyz/nix-config/actions/runs/50/jobs/0).
All declared platforms are evaluated, while foreign-platform check builds,
runtime qualification, and private synthetic integration remain separate.
