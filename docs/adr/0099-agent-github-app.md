# ADR-0099: Agent sessions act on GitHub through a GitHub App

**Status:** Accepted
**Date:** 2026-10-19
**Applies to:** `modules/home-manager/programs/ai/agent-github.nix`, T3 Code's
session wrapper

## Context

`programs.ai.agentForge` (ADR-0081) gives agent sessions a separate Forgejo
account, so their forge actions are visible as the agent's while commits keep
the operator's Git identity. On GitHub, agents still use the operator's own
`gh` login, which reaches every repository the operator can, and their issues,
pull requests and comments are indistinguishable from the operator's.

A GitHub App gives the same split on GitHub: it is installed on chosen
repositories of one account, holds repository permissions only, and acts
through installation tokens that last an hour. Pushing with such a token does
not change commit authorship. The repositories an agent touches on GitHub are
not all the App's, though: other accounts' and organisations' repositories
must keep working with the operator's login, unchanged.

## Decision

`programs.ai.agentGithub` (off by default) gives agent sessions a GitHub App,
given by its numeric ID, a private key file and the account it is installed
on (`owner`). Like `agentForge`, it applies only to the processes T3 Code
starts: the session wrapper runs its commands after the session variables.

- **`gh`.** T3's package puts its own `gh` first on `PATH`, ahead of anything
  the session sets, so that `gh` is gh-app's pass-through (nix-packages
  `gh-app-gh`), and the session only exports the App's settings
  (`GH_APP_ID`, `GH_APP_KEY_FILE`, `GH_APP_OWNER`). Without them it runs the
  real `gh` unchanged. With them, for commands that act on a repository
  (`pr`, `issue`, `release`, `run`, `workflow`, `label`, `cache`, `api` and
  the repository-scoped `repo` subcommands), gh-app works out the target the
  way `gh` does, from a URL selector, `--repo`, a `gh api` endpoint,
  `GH_REPO` or the checkout's GitHub remotes. For a repository of `owner` that
  the installation includes, it runs `gh` with an installation token in
  `GH_TOKEN`; everything else, including commands that act on no repository
  such as `search`, `gist` or `repo list`, runs `gh` unchanged with the
  operator's login. It refuses rather than falls back when it cannot get a
  token for an `owner` repository. `GH_AS_OPERATOR=1` on a command runs it as
  the operator, for when the operator asks for that.
- **Git.** For `https://github.com`, `useHttpPath` passes the repository path
  to helpers, an empty helper resets the ones configured so far, then
  `gh-app credential` answers with the installation token, and its expiry,
  for installed repositories, stays silent for other repositories, and tells
  Git to stop (`quit`) when it cannot get a token for an `owner` repository;
  `gh auth git-credential` (the operator's login) answers next.
  `pushInsteadOf` sends pushes for `owner`'s SSH remotes over HTTPS, since an
  SSH push authenticates with the operator's key, and maps the HTTPS form to
  itself to win over a host-wide `insteadOf`; other owners keep their
  transport. Fetches keep their URLs.
- **`agent-job`** passes the App's settings on to its units, with `PATH` and
  the `GIT_CONFIG_*` entries, so a job an agent starts acts the same way.
- gh-app mints tokens from the key when needed and caches each with the
  installation's repository list in `$XDG_RUNTIME_DIR`, readable only by the
  user; it never prints a token except to Git through the credential protocol.

The private configuration sets the App and its key.

## Alternatives Considered

- **A fine-grained personal token.** Narrow, but long-lived and still the
  operator's, so agent actions stay unattributed.
- **A `gh` shim on the session's `PATH`.** The first version; T3's package
  prefixes its own `gh`, so the shim never ran inside T3.
- **Route by `GH_TOKEN` alone.** Setting the App's token for the whole session
  would break every repository outside the installation, other owners'
  included.
- **Route by directory.** Simpler, but wrong for `--repo` and URL arguments and
  for checkouts outside a known tree.
- **A machine user.** Attributable, but a second account with its own sign-in,
  two-factor setup and long-lived tokens.

## Consequences

Agent issues, pull requests, comments and pushes on the installed repositories
show the App's bot account; commits keep the operator's identity. Adding a
repository is a change to the App's installation, not to this configuration.
As with `agentForge`, this is attribution and a guard against accidents, not a
privilege boundary: agents run as the operator's Unix user and can reach the
operator's `gh` login, and `GH_AS_OPERATOR` is a convention. Commands `gh-app`
cannot attribute to a repository, such as `gh api graphql` or `gh search`, run
as the operator, and so does a `gh` other than T3's on `PATH`. `pushInsteadOf`
matches the owner's name case-sensitively, so a remote spelling it
differently pushes over SSH as the operator, and a `remote.<name>.pushurl` is
not rewritten, as ADR-0081 records for the forge. Terminal sessions of
`claude` or `codex` act as the operator throughout.

How agents merge on GitHub, and how the merge guard (ADR-0078) checks it, is
decided separately: pushing a reviewed head to the base branch is a merge
there, which the guard must check like one before the App merges anything.
