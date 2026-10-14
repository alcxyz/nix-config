# ADR-0095: Evaluate Go through one bounded workspace-sync pilot

**Status:** Accepted; implementation deferred
**Date:** 2026-10-14
**Applies to:** `modules/home-manager/workspace/`, future reusable workspace tooling in `nix-packages`

## Context

[Issue #412](https://git.alc.xyz/alcxyz/nix-config/issues/412) evaluated a bounded
inventory of substantial shell helpers, including desktop watchers and separate
Wolf/Moonlight coordinator, worker, input and lifecycle responsibilities. The
[evaluation and pilot contract](https://git.alc.xyz/alcxyz/nix-config/issues/412#issuecomment-28132)
recommend exactly one pilot: `workspace-sync`. The user accepted this choice
and its behavior and ownership boundary on 2026-10-14, authorizing this decision
record while leaving implementation for a later authorized thread.

The current workspace helper interleaves JSON validation, parent-path checks,
Git/worktree classification, relative links, partial failures and summaries.
Concrete Go types and direct filesystem operations could make those states and
their tests clearer. Existing credential-free fixtures already cover meaningful
behavior. This is a synchronous operation family with Linux and Darwin consumers;
it avoids the timing, hardware and input qualification of a first desktop or
streaming pilot.

## Decision

Use one focused Go program for the future `workspace-sync` pilot, preserving its
current CLI, manifest, reconciliation behavior and exit policy. This accepts a
bounded design to test, not a blanket shell-to-Go migration or permission to
implement it. Simpler maintenance and clearer ownership determine success.

### Behavior and interface boundary

- Keep the public wrapper interface `workspace-sync [--status | --directories |
  --help | -h]`. The reusable executable takes `ROOT MANIFEST [MODE]`, matching
  the current script interface. The consumer wrapper supplies root, manifest
  and the Git dependency; the executable ships no personal defaults.
- Keep the JSON manifest's `directories`, `repositories` (`path`, `url`,
  optional/null `branch`) and `links` (`path`, `target`, `profiles`). Nix filters
  profiles before execution. Preserve compatibility with existing extra fields.
- Validate the complete manifest before creating anything. Preserve safe
  relative-path rules, plain-directory checks for the managed root and parents,
  and refusal to create links whose resolved targets escape the resolved root.
  This decision adds no stronger concurrent-writer or filesystem-race guarantee.
- Default sync creates missing declared directories, clones missing repositories
  in manifest order, then creates missing relative links to existing canonical
  targets. Preserve existing paths and local edits; Git worktrees count as
  existing repositories. Do not fetch, pull, reset, switch branches, move or
  remove existing checkouts as part of reconciliation.
- Status creates nothing, including a missing root, and never clones.
  Directory-only mode creates directories without cloning or linking. Help
  performs no filesystem mutations. Keep serial execution and continue after
  individual clone failures so later entries can succeed.
- Preserve per-entry reporting, summary counters, tool-authored output and
  stdout/stderr roles. Git owns its own transport and progress/error output.
  A new structured-output format is outside this pilot.
- Preserve exit 2 for invalid manifests or unknown modes, exit 1 for root
  rejection, clone failures and directory-only conflicts/failures, and current
  success for reportable skips or missing link targets. Normal sync/status do
  not make every directory conflict fatal. Do not introduce an exit-policy fix
  inside the port.
- Missing raw `ROOT` or `MANIFEST` arguments retain exit 1. Preserve fatal
  filesystem-command failures, such as link creation or canonical-path
  resolution: stop at the same point with the command's nonzero status,
  without processing later entries or printing the final summary. Do not turn
  these aborts into reportable skips.

Characterize parser and schema edge cases against the shell before cutover,
including trailing arguments and jq coercions. Any intentional incompatibility
requires a separate decision. Use concrete types, explicit control flow and
ordinary loops. Continue calling Git with argument arrays; do not replace its
credential/transport handling, add a daemon, parallel clone scheduler or retries,
or evaluate commands through a shell.

### Ownership and retained responsibilities

Follow [ADR-0007](0007-filtered-nix-packages-overlay.md) and
[ADR-0002](0002-nix-secrets-separate-repository.md):

- `nix-packages` owns the reusable public executable, synthetic contract tests,
  package derivation and supported platform exports.
- `nix-config` owns public options, profile selection, generated manifests, the
  thin wrapper, explicit package selection, activation integration and consumer
  checks. Home Manager activation retains directory-only behavior.
- `nix-secrets` owns private inventory/defaults and private integration evidence.
  Public fixtures use invented names and local repository URLs.

Keep short environment/profile wrappers, activation glue and declarative Nix
composition in their existing languages. The evaluation does not authorize
replacing existing Python reconcilers. Desktop watchers and streaming helpers
remain outside this pilot. Keep Wolf/Moonlight coordinator recovery, worker
behavior, capsule lifecycle, pointer mirroring, native button delivery and
daemon/bridge startup ordering separate. Any later Wolf input/lifecycle change
still requires `just input`, with pointer movement and primary clicking accepted
together, plus the applicable runtime qualification.

### Acceptance before a later replacement

1. Exercise the same credential-free fixtures against shell and Go. Compare
   filesystem effects, tool-authored output, counters and exit codes. Cover
   fresh/repeated sync, dirty checkouts, worktrees, ordinary directories inside
   repositories, file/symlink conflicts, missing/escaping link targets, relative
   link idempotence, invalid manifests before all writes, named/missing branches,
   partial failure followed by success, fresh status roots, nested roots and
   directory-mode continuation. Add focused schema/parser and argument-quoting
   cases, missing raw arguments and injected fatal filesystem failures. Check
   abort status, absence of the summary and unattempted later entries; prove
   status and directory-only mode never clone.
2. Run `gofmt`, affected-module `go test ./...`, native producer package and
   contract checks, and declared platform evaluation. The current consumer set
   requires `x86_64-linux` and `aarch64-darwin`; record native Darwin execution
   separately if unavailable rather than inferring it from Linux.
3. Under [ADR-0067](0067-explicit-consumer-and-platform-validation.md) and
   [ADR-0080](0080-promoted-package-ref.md), validate the actual package selected
   by the candidate consumer lock and affected Home Manager activation
   derivations (currently xyz, xps and mac). Check wrapper arguments, dependency
   paths, generated-manifest compatibility and directory-only activation with
   isolated fixtures. Record producer revision, consumer revision and lock
   digest. An isolated fixture is not activation of the user's profile.
4. Keep installed runtime acceptance user-owned and distinct from source,
   package and consumer validation. Check installed status without publishing
   private output, the generated activation invocation, and deliberate sync
   against an approved missing-checkout fixture. Confirm Git credential use,
   local-edit preservation and relative links. Deployments/activation remain
   separate user actions; no desktop manipulation or service restart is
   intrinsic to this synchronous CLI.

## Alternatives Considered

- **Retain shell:** current fixtures pass and Git/coreutils orchestration is
  familiar. Retaining it remains the fallback if Go plus packaging does not
  simplify maintenance. The pilot tests whether typed state and direct
  filesystem operations improve the interleaved parsing and result accounting.
- **One focused Go program:** selected for a single manifest and reconciliation
  responsibility with useful behavior tests and explicit repository boundaries.
  Keep a thin Nix-generated shell wrapper where it remains simpler.
- **Related subcommands:** `sync`, `status` and `directories` would form a
  coherent workspace-specific CLI, but add no demonstrated benefit over the
  existing flags for this pilot. Preserve those flags. A catch-all binary for
  workspace, desktop, streaming, audio or unrelated host operations would obscure
  ownership and is rejected.

## Consequences

The future implementation needs producer packaging and consumer integration as
well as Go tests. Linux source/fixture success does not establish Darwin,
credential-backed cloning or installed activation behavior. Existing quirks may
need separate decisions; they must not turn a preservation pilot into a policy
rewrite. Keeping shell is preferable to completing a port that adds complexity.

[Issue #412](https://git.alc.xyz/alcxyz/nix-config/issues/412) owns evaluation
evidence and the proposed implementation tracking. A later authorized thread
should track reusable implementation in `nix-packages` and link its consumer
integration/qualification in `nix-config`. Those tasks are proposed, not filed
by this decision record. This ADR changes no executable, package lock, service
or activation behavior and authorizes no deployment or promotion to `main`.
