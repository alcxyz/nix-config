# ADR-0078: Guard agent PR merges with automated cross-model reviews

**Status:** Moved to a private repository on 2026-10-29
**Date:** 2026-10-01
**Applies to:** `modules/home-manager/programs/ai/`, `modules/home-manager/services/t3code/`, `modules/nixos/security/agent-pr-review-guard/`, Claude Code and Codex CLI hooks, the agent Git pre-push hook in the user's Git configuration

## Context

Agents create and merge pull requests on Forgejo and GitHub. A read-only review
of a WAF exception by a second model found a scope problem that the authoring
agent had missed. Asking for such reviews only in agent instructions does not
ensure they happen: agents can forget, or judge a change too small to review.

Pull requests and comments must not carry AI co-author trailers or tool
signatures. Reviews still need a visible, honest record that colleagues will
not mistake for a human review.

## Decision

Before an agent merges a PR it created, it obtains independent read-only
reviews from a Codex and a Claude reviewer, by default the `deep` agent role
(ADR-0079) on each client, or the `light` role for small documentation-only
changes. Each runs sandboxed
without write or forge access and is given the diff and the PR description. The
agent addresses or justifies the findings, then posts one PR comment whose first
line is `Automated read-only review (<short head sha> on <target branch>):
<mode> (<role>): <outcome>`, where the mode is `full`, `follow-up to <short
sha>` or `carried from <short sha> (rebase|fold)` and the role is `light` or `deep`. A trivial PR, or a promotion such as
`dev` to `main` whose every commit was already reviewed on its own PR, may
record `skipped (<reason>)` as the outcome, without a mode. Commits pushed
directly to the source branch, and conflict resolutions, still need a review,
and a failed or unavailable reviewer is never a reason to skip. Low-severity
findings and small cleanups are fixed in the PR before merging; an issue tracks
one only when it needs a real decision or substantial work. Comments name no
models and carry no signatures.

`programs.ai` installs `pr-review`, so agents do not assemble the reviews by
hand or depend on which models their own client offers:

- `pr-review run <pr>` fetches the PR's head and target branch into the local
  clone with repository hooks disabled, builds the diff locally with the target
  branch's attributes (a forge's diff can lag behind a push, and the PR's own
  `.gitattributes` must not hide changes), writes the head's files to a temporary directory from
  raw objects (no hooks, filters or symbolic links), and runs the reviewers in
  parallel with the diff and PR description. One run per PR head at a time.
  Reviewers see the checkout, and none of the user's instructions or other
  files beyond the limits below. Codex runs read-only without network access, user configuration,
  saved command rules, MCP servers, app connectors or plugins. Claude Code
  runs in restricted and safe mode with only the Read, Grep and Glob tools,
  without MCP servers, and ignoring user and project settings. Reviewers do
  not inherit forge token variables. Results and a status per reviewer,
  including its configured model and effort, are kept per head SHA; the target branch is
  recorded and must still match. Earlier rounds are kept. A failed,
  timed-out or usage-limited reviewer, or one whose reply lacks one of the
  requested verdicts, is reported as a missing review, never as no findings.
- A new head is reviewed as a **follow-up** of the last round that the
  configured reviewers, and only they, completed on the same target, when it
  descends from that round with the same merge base, at most 40 lines or 40%
  of the previous reviewed diff's changed lines changed since (recorded in
  `status.json`), no binary files changed, and fewer
  than three follow-ups ran in a row. Reviewers then get the findings of every
  round since the last full review, the author's `--response` as a claim to
  check, the interdiff to review, and the whole PR diff and checkout as
  context; they raise new findings in untouched code only if they are
  blocking. Otherwise, or with `--full`, `run` reviews the whole PR and says
  why; a missing earlier round also forces a full review, and the response is
  still passed on. A round without a valid recorded changed-line count also
  forces a full review. `--force` repeats the head's previous mode. A result from a
  different reviewer set counts for no reviewer, and a round with another role
  forces a full review. Fix rounds then cost roughly what the fixes need, and fresh
  low-severity findings in unchanged code stop restarting the loop
  ([#524](https://git.alc.xyz/alcxyz/nix-config/issues/524)).
- **Carried reviews** ([#715](https://git.alc.xyz/alcxyz/nix-config/issues/715)).
  Agents may curate a PR's commits locally (fix rounds as `fixup!` commits,
  folded with `git rebase --autosquash`) for a fast-forward merge, so every
  rebase onto the current target and every fold is a new head. Before a
  follow-up, and unless `--full` or `--force` is given, `run` carries the
  latest completed round on the same target, with the same reviewers and
  role, to a head that only rebases or folds its commits, without running
  reviewers. Both histories must be linear, and no new commit may have an
  author or committer email in `programs.ai.prReview.agentIdentities`. A
  **rebase** needs the new merge base to contain the reviewed one and as many
  commits, each with the same message, author and committer identity, whose
  reviewed counterpart replayed onto the new parent with `git merge-tree
  --merge-base` merges cleanly to exactly the new commit's tree. Comparing
  patches is not enough: a conflict resolution can look like the reviewed
  patch applied to an identical block elsewhere. A **fold** needs the same
  merge base and head tree, and the new commits must equal git's
  non-interactive autosquash of the reviewed ones (trees, messages, authors,
  committer identities, order), replayed the same way; only `fixup!`
  commits fold, since `squash!` and `amend!` change a message and need a
  review. Only plumbing runs (`rev-list`, `cat-file`, `merge-tree`, and
  `commit-tree` for unreferenced intermediate commits). Merges run in a
  throwaway bare repository that borrows the clone's objects (in the clone's
  object format), without system, user or repository config or system
  attributes and with attributes from the empty tree, since a
  merge driver named there is an external program that could report a
  conflict as clean; so no checkout, hooks, filters, custom merge drivers or
  editors run. This needs git 2.40 or later. The carried round copies its source's
  results, mode, follow-up count and changed-line count, so later follow-ups
  build on it, and `comment` records `carried from <short sha> (rebase|fold)`.
  A carry that fails prints the failing condition and falls back to a
  follow-up or full review. A fold and a rebase in one push do not carry;
  push and run after each.
- The outer `run` needs forge/provider network access and a writable
  `$XDG_STATE_HOME/pr-review` (by default `~/.local/state/pr-review`), so run
  it outside a network-restricted Codex sandbox. This is a requirement for
  the orchestrating process, not permission to relax the reviewers' isolation.
  An inherited SIGHUP ignore disposition, such as under `nohup`, is kept;
  ordinary SIGHUP and SIGTERM still cancel the run and clean up its children.
- **Reviewer isolation** ([#709](https://git.alc.xyz/alcxyz/nix-config/issues/709)).
  A review must not depend on whose machine runs it, and a review of a public
  repository must not pull private user-level context into its findings.
  Checked against Codex 0.163 and Claude Code 2.1.301 with planted files:
  - Codex loads the user's `AGENTS.md` from `CODEX_HOME` even with
    `--ignore-user-config`, and its built-in read-only sandbox lets commands
    read the whole disk; reviewers followed such instructions to files
    outside the checkout. Codex reviewers therefore run with `HOME` and
    `CODEX_HOME` set to a fresh directory beside the checkout (both under
    `pr-review`'s state directory, since the profile denies `/tmp` and Codex
    will not set up its home there; the next run on the same host removes
    those of killed runs), which holds
    only a link to the user's `auth.json` (Codex rewrites it in place, so a
    token refresh reaches the user's file; credentials are never read or
    copied) and a link to the user's Nix profile, where the managed hook finds
    the guard. Their commands run under a permission profile that denies reads
    everywhere except the checkout, the Nix store and the minimal system paths
    Codex selects, so not other reviews' checkouts or `/tmp`, and without
    login-shell startup files. `PATH` entries are resolved first, since
    profile links under the user's home are unreadable there.
  - Claude Code in restricted mode does not load the user's `CLAUDE.md` and
    keeps its file tools inside the checkout; safe mode also turns off
    plugins, skills and custom agents. It keeps the user's config directory:
    Claude replaces its credential file on a token refresh, so a linked file
    in a throwaway directory would leave the user's copy with a spent refresh
    token, and macOS keys its keychain entry by the config directory.
  - `test-pr-review.py` plants user-level instruction files and fails if a
    reviewer would load them where each client looks for them.
- `pr-review comment <pr> "<outcome>"` posts the comment for the current head,
  and refuses unless every reviewer completed for that head, except for skips.
- `pr-review check <pr>` reports whether a comment names the current head.

Reviewers are the `programs.ai.prReview.reviewers` option, which defaults to
the `deep` role's resolved models and efforts. `run` uses
`programs.ai.prReview.lightReviewers` instead, by default the `light` role on
both clients, when the PR's whole diff changes only documentation files
(`.md`, `.mdx`, `.rst`) and at most 300 lines. Agent rules and
instructions (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `SKILL.md`,
`copilot-instructions.md`), files in dot-directories such as `.github` or
`.claude`, `SECURITY.md`, decision records, paths naming secrets, security,
credentials, tokens, authentication, SOPS, keys, policy or prompts, binary
files and diffs whose paths cannot be read always get the deep reviewers, and
so does every PR when no light reviewers are configured. `--role deep` raises
the choice; nothing lowers it, so review depth cannot drop unnoticed. The
comment records the role used. The QA data
([#569](https://git.alc.xyz/alcxyz/nix-config/issues/569)) found that
reviews of small documentation changes found only low-severity wording
problems, and that re-reviewing promotions repeated their feature PRs'
reviews. `pr-review` never loads a role
profile, so its isolation is unchanged. A role can name a Claude alias, so each
result records the model the client reports alongside the configured one.
Claude's JSON result names its models; Codex's JSON event mode currently
omits its session header, so its reported model can be `null`. The configured
reviewer identity is always retained.

`programs.ai` installs `agent-pr-review-guard` as a `PreToolUse` hook for shell
commands in both clients. Claude receives it through the managed settings merge,
which now combines hook arrays instead of replacing them. Codex runs hooks
from `~/.codex/hooks.json` only after they are trusted in its `/hooks` view,
and skips them silently until then. On NixOS hosts,
`security.agentPrReviewGuard` therefore declares the hook in
`/etc/codex/requirements.toml`, where Codex trusts it by policy, pins hooks on,
and installs a script under its `managed_dir` that runs the calling user's
guard. For the module's `users`, a missing guard blocks every hooked call.
Other hosts keep the user `~/.codex/hooks.json`, which must be trusted once
per change to take effect. The guard recognises `gh pr merge`, GitHub `pulls/N/merge` API calls, Forgejo
REST merges (including `tea api`), and refuses `tea` and `fj` merge commands. It blocks them unless a review comment names the PR's current head
commit and target branch, so new commits or a retargeted PR need a new review.
The comment's mode follows the pinned prefix, so older guards still accept it;
the guard does not check the chain of rounds, which `run` enforces from local
state when it selects a follow-up. It also blocks when it
cannot verify the comment, including when its lookups exceed a 90-second
deadline inside the 120-second hook timeout. The hook also matches Forgejo MCP
tools and checks `merge_pull_request` like other merges, from its structured
arguments (ADR-0081); other MCP tools pass.

For Forgejo repositories listed in `programs.ai.prReview.fastForwardRepositories`
(`host/owner/repo`), the guard also refuses an agent merge, by REST (including
`tea api`) or MCP, whose style (`Do`, or the MCP `style`) is not
`fast-forward-only`, so the forge writes no commit and history keeps the
operator's identity. It lists the PR's commits from the Forgejo API with the
same token handling and deadline as its other lookups, and refuses leftover
`fixup!`, `squash!` or `amend!` commits, and commits whose author or committer
email is in `agentIdentities`, which a forge-side rebase or "Update branch"
by an agent forge account would leave. The Forgejo MCP server (3.2.0) lists
only the other styles in its tool description but passes `fast-forward-only`
through to the API unchanged; where it does not, merge with `tea api -X POST
/repos/owner/repo/pulls/N/merge -d '{"Do":"fast-forward-only"}'`. Other
repositories, and merges in unlisted GitHub repositories, are checked as before.

The list may also name GitHub repositories as `github.com/owner/repo`
(amended 2026-10-19), and this decision sets how agents merge there. GitHub
has no forge fast-forward merge, so for a listed GitHub repository the merge
is a push of the reviewed PR head to its base branch (`git push <remote>
<head sha>:<base>`), which GitHub records as merging the PR and which keeps
the commits byte-identical. Agents never use GitHub's squash, rebase or
merge-commit methods there, and do not merge or move branches through the
API; agents act on GitHub through a GitHub App (ADR-0099), which does not
change this method.

Since that push is the merge, a Git pre-push hook checks it: `pr-review
pre-push`, which the user's Home Manager Git configuration registers
(`hook.agent-pr-review.command` and `hook.agent-pr-review.event`) when a
fast-forward repository is listed (a GitHub one before the 2026-10-27
amendment). Git runs it beside the repository's own
`pre-push` hook, in every repository and session, with the remote's name, the
push URL after `insteadOf` and `pushInsteadOf` rewriting, and one line per
ref it is about to update, so it checks what Git actually pushes, whether
from a literal command, a script, an alias or a runner. It checks only agent
processes and returns at once, before reading configuration or calling
GitHub, unless an agent marker is set: `CLAUDECODE=1`, which Claude Code sets
for its tool processes; `PR_REVIEW_AGENT_SESSION=1`, which T3 Code's agent
session wrapper exports, so Codex in T3 is covered, and which `agent-job`
passes to jobs started from any agent process; or, best effort, any of
`CODEX_THREAD_ID`, `CODEX_TOOL_CALL_ID` or `CODEX_SANDBOX_NETWORK_DISABLED`
for Codex outside T3, which are not verified. The operator's pushes outside
agent clients are not checked, but pushes from T3's interface and commands
the operator types inside a Claude Code session carry a marker and are. For a URL that is a listed repository in scp, `ssh://` or
`https://` form (hosts compared without case or default port), each update
of a protected branch, the repository's default branch, `main` or the base
of an open PR, must not delete it, must fast-forward it (`git merge-base
--is-ancestor`; a remote commit the clone lacks refuses the push with a
request to fetch), and must push the head of an open PR into that branch
with a review comment for that head and the same commit checks as above,
read from the GitHub API with the guard's deadline. GitHub itself would also
refuse a non-fast-forward unless forced. Tags, other refs and feature
branches pass this merge check, the last after the lookups that show they are
not protected (the 2026-10-27 amendment adds a fixup check for reviewed PR
branches);
a branch that is the base of an open PR, as in stacked PRs, is protected by
design. When several open PRs into the branch have the pushed head, one that
passes is enough. URLs of unlisted repositories return at once without network. A refusal or a failed
lookup exits 1 with the reason and refuses the whole push.

The PreToolUse guard keeps what the hook cannot see. For a listed GitHub
repository it refuses `gh pr merge` with any flags, REST and `gh api` merges
(`pulls/N/merge` and the `merges` API), and ref updates through the
`git/refs` API, pointing to the push instead; each curl transfer is read
on its own (curl transfers split only at a real `--next`, options read by
their curl meaning so a value is never a flag; a read only when proven:
every option known, none a data option or indirection such as `-K` or
`--expand-*`, and no `-X` other than `GET` or `HEAD` anywhere in it,
whatever `-G` says; a curl command with an option the guard does not know
anywhere is refused outright when it names a listed endpoint, since that
option may take the next word), the
`gh api` host
follows `--hostname` and `GH_HOST` (empty counts as unset), including
assignments earlier in the same command, hosts compare without case or
default port, URLs count with or without a scheme (`https://`, `//` or a
bare host, with any port or user info), and reads pass, including a `gh api` GET of `pulls/N/merge`
(its default without fields), which only reads the merge status. It also
refuses changes to the hook, read from
parsed shell words so that text in messages and heredoc bodies stays data. In
any command: `hook.*` settings given with `git -c` or `--config-env`
(including `hook.<name>.enabled`, which disables a configuration hook),
any `git config` that is not proven a read and has an argument naming a
`hook` or
include (`include.path`, `includeIf.*`) key or section, also as an
`--option=value`, whatever options Git takes it with, so an unusual value
that only looks like one is refused too; a read is only `get [options]
KEY`, `list [options]`, or `--get`, `--get-all` or `--get-regexp KEY
[pattern]` and `--list`, with every other word a flag that takes no value or
`-f`, `--file`, `--blob`, `--type` or `--default` with its value, in exactly
those forms, and `GIT_CONFIG_KEY_n` or
`GIT_CONFIG_PARAMETERS` values that set `hook.*`. In a command that pushes:
`git push --no-verify`, include settings given with `git -c` or
`--config-env`, and assigning, exporting, unsetting or `env -u` (bundled
options such as `-iu NAME` included) of
`GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_n`, `GIT_CONFIG_VALUE_n`,
`GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`,
`GIT_CONFIG_NOSYSTEM`, `HOME` or `XDG_CONFIG_HOME`, which can hide the user's
configuration, and of the agent markers, which turn the hook on, `env -i`,
`env -S`, whose split string the guard does not read, a lone `-` in env's
options or right after `--`, which GNU env reads as `-i`, any `env` option it
does not know, and an assignment through `env` of a variable that carries the
hook or turns it on, wherever an `env` word stands among the command's
words. Arguments of
`eval`, also behind `builtin` or `command`, and a shell's expanding stdin (an unquoted
heredoc or a here-string), are read as the scripts they become. Shell text
the guard cannot parse is refused only when it carries such syntax. Pushes
themselves pass the PreToolUse guard.

The pre-push hook is the enforcement. The PreToolUse refusals of hook
tampering are an accident guard for literal, unwrapped forms: `git -c
hook.*`, `git config` writes of hook and include keys, `--no-verify`, changes
to the agent markers and `GIT_CONFIG_*`, `env -i`, `-u` and `-S`, and
GitHub-side merge and ref calls. Deliberate evasion is out of scope under the
same-user limit (nix-secrets ADR-0020): wrappers around `git` or `env` the
guard does not model, Git aliases, `GIT_DIR` or `--git-dir` redirection,
generated or indirect commands, and scheme or host tricks beyond the handled
forms. An agent running as the operator can always disable a client-side
hook, so these checks prevent mistakes, not a determined bypass.

The hook covers agent processes that carry a marker: Claude Code, T3 agent
sessions and their `agent-job` units, and Codex outside T3 only if one of
the unverified Codex variables is set. The T3 server and everything it
starts carry `PR_REVIEW_AGENT_SESSION=1`, so pushes T3 makes from its own
interface are checked too; its flow pushes feature branches, which pass the merge check, and
a push from it to a protected branch needing a reviewed head is accepted. A
running T3 gets the marker only after its next restart, like other changes
to its session wrapper, which it runs through a stable link (see
`modules/home-manager/services/t3code/README.md`). Hook tampering is caught
only in the literal forms above; other edits of a repository's `.git/config` or the user's
configuration, for example by a script, an editor or `sed`, and processes
that drop the marker are not seen. The `env` scan looks at every `env` word
in a pushing command, so a data word `env` followed by dashed words, as in
`rg env --glob '*.nix' && git push`, is refused too; that false refusal is
accepted. GraphQL mutations are not covered, and
API writes other than the refused forms are not checked. A push that lands
between the hook's lookups and GitHub's update is not caught.

The guard and `pr-review` share one script. Shell checks separate ordinary
literal commands from quoted arguments, comments and heredoc bodies, so text
in a commit message does not become a merge command. They also check each
command in a chain, ordinary execution wrappers such as `env` and `timeout`,
and leading redirections. Unknown wrapper options are refused. Heredocs and
`-c` arguments passed to shell interpreters are checked as executable shell
text, with a separate working-directory context for that shell. Process
substitutions and command expansions in unquoted heredocs are also executable;
substitutions inside double-quoted arguments and assignments are checked too.
Quoted heredocs and literal message/search arguments remain data, including
heredoc prose inside a `$(cat ...)` message. Subshell directory changes stay
local. Conditional directory changes are tracked conservatively; if a merge
could run in more than one directory, name its repository explicitly.
Directory-affecting assignments propagate into nested shells. Logical `.` and
`..` navigation is normalized before lookup; physical and opaque directory
modes require an explicit repository. `eval` leaves the subsequent directory
unknown, while `source` and `.` files remain opaque executable source.
User-switching wrappers also make home and directory navigation uncertain.
An initial symlink directory is also uncertain, because a new shell can start
with physical `PWD` rather than the supplied logical path.
Unsupported wrappers and inline programs containing literal merge syntax are
refused conservatively, rather than assumed harmless. Recognized prose
contexts, including git commit messages, searches and cat heredocs, are exempt.
Piping that prose into an executable context is refused when its interpretation
cannot be verified. Shell options are consumed before selecting `-c` source.
Literal merge arguments forwarded through `-c` are opaque unless the program
is a simple text producer. Git's explicit pager and transport program options
are executable contexts too; ordinary commit, push and PR-body flows remain data.
The same applies to explicit helper programs on text/search commands. Shell
source from files or inherited stdin is opaque in a merge context; use literal
source or a direct merge. Command substitutions retain that context, and
`printf -v` assignments retain executable value provenance.
That context covers the whole tool-call command, including merge syntax in
recognized prose. Consequently, `git commit -m "explain gh pr merge" && bash
tests.sh` is conservatively refused because the shell file is opaque.
Replacing `&&` with `;` or a newline in the same tool call does not change
that boundary. Run the commit and the script in separate tool calls instead.
The prose command alone remains exempt. This rule covers explicit shell
interpreter invocations; it does not track files across commands or verify
files invoked through other executables. Broader file-flow tracking is outside
this decision.
The trigger itself is a conservative word heuristic: a CLI name (`gh`, `tea`
or `fj`), a PR noun (`pr`, `pull` or `pulls`), and `merge` or a standalone `m`
can appear anywhere in the tool call, including in different commands.
For example, `git merge origin/dev && gh pr view 670 && bash tests.sh` also
requires separate tool calls. The heuristic does not establish that a PR
merge actually occurs. `exec` options that reset the environment or change
the invocation identity are opaque and refused; use plain `exec` instead.
For GitHub merges or nested shells, sudo's handling of inherited `GH_REPO`
and `GH_HOST` is opaque, including with `-E`, because preservation depends on
the operator's sudo policy. Use a direct merge without sudo when either is
present in the hook environment.
Dynamic assignment destinations and executable Git helper transports are
opaque too. Redirected stdin remains data when a shell executes a script file;
`-s` explicitly selects stdin source instead.
Redirections retain their descriptor information. Auxiliary descriptors do not
become shell source, and opaque stdin from a file or descriptor is refused even
alongside literal here-input. Trailing stdin redirections are retained because
they can replace earlier source. Push options use Git's value and bundle forms;
unknown options are opaque rather than guessed.
Descriptor-zero duplication is tracked for either operator direction, and
expanded here-string source stays opaque. Literal or opaque auxiliary input
requires empty source or a simple text consumer, rather than a client that can
invoke configured helpers. Null-device and closed input are known empty data.
Process-substitution output used as source is also opaque; output substitutions
that consume literal merge text require a recognized prose command too.
A `-c` program can
forward stdin into another interpreter, so literal merge input is refused
unless the program is a single recognized prose command.
Persistent `exec` and named-descriptor inputs and consumers are refused when
the script contains literal merge syntax. Git global configuration containing
that syntax, including environment-backed settings, is executable configuration,
not exempt message text. Value references retain executable provenance through
arguments, pipes and assignment copies. Only exported or inline environment
assignments are visible to child programs; unused local message values do not
block subsequent build commands. Nested shells receive the exported values,
including through ambiguous shell-option paths.
Dynamic declarations and shell name references are opaque assignment targets.
Internal shell scopes retain local variables, while external children receive
exported values. Expanded `-c` source and expanding stdin-source heredocs are
opaque when their executable value cannot be verified. Redirections after a
parenthesized scope retain their inputs and require a simple text consumer.
All-export, keyword-export and dynamic shell-option modes are refused; use
explicit exports. Zsh option mutations, shell startup environment settings and
interactive/login startup are opaque. Words after a closed shell group are
refused rather than silently discarded.
Explicit Zsh execution requires `-f` to suppress user startup files and rejects
named option changes. Negated assignment-export option names are still opaque.
Prefix assignments to special declaration builtins or bare `exec` may persist
in POSIX mode, so their export visibility is tracked conservatively.
Declaration attributes are limited to string, export, global, readonly and
print behavior; arithmetic, aliasing and unknown attributes are opaque.
ANSI-C shell quoting and case grammar inside substitutions are also refused
in merge contexts because their token boundaries are not verified. Use
ordinary quotes and direct literal commands. `printf` assignment destinations
participate in repository and directory tracking; repeated destinations,
expanded formats and variable-writing `%n` formats are opaque.
Append assignments, input-assignment builtins, `eval`, `let`, `getopts` and
dynamic variable removal are opaque too;
declarations and removals of target or directory variables retain their effect
on later merge checks. Substitution output keeps opaque provenance when passed
to executable configuration.
Literal shell source retains its quoting provenance so message-only variable
references remain data. Parameter assignments to target/directory variables,
Zsh local declarations and environment-wrapper removals retain their effect;
shell arithmetic and wildcard variable removals are opaque. Explicit Git
pagers receiving generated merge text are executable contexts.
Inline pager settings count too. Merge flags and selectors must be literal;
expanded message values remain data only when quoted so they cannot introduce
additional flags. GitHub API output filters and caching options are supported;
pagination remains opaque because it can issue additional requests.
REST targets must also be literal, and expanded REST values must be quoted
so word splitting cannot introduce another request or option.
Git and forge clients' executable environment settings are checked before
granting their prose exemption; unrelated message and identity values remain
data. A direct merge's result may still be piped to ordinary formatters after
its review is checked, while curl's explicit output text remains tracked.
Use a direct literal merge command when an unfamiliar invocation is refused.
Delayed `gh pr merge --auto` and Forgejo
`merge_when_checks_succeed` merges are refused because they can outlive the
reviewed head. REST merge payloads or request configuration from a file or stdin are refused because
the scheduling option cannot be verified without reading that input; use
inline JSON or fields once checks pass. Multiple REST transfers in one command
are also refused, so one transfer's method or review cannot cover another.
Unsupported REST options and URL lists from files are opaque inputs and are
refused rather than guessed, including options that expand or retarget requests.
Expanded inline payloads are opaque, and scheduling keys are checked without
regard to case. Repository cloning and forking are executable contexts because
they may forward Git options, so they receive no prose exemption.
Curl URL globbing is refused rather than treating its expansion as one target.

A `pr-review` skill for both clients, held in nix-secrets `shared/skills/`
since 2026-10-11 (ADR-0091's last amendment), is the one full copy of the
agent procedure: running, reviewer depth, findings, fix rounds with
`--response`, outcomes, skips and failures. The global agent rules keep only
the requirement and point to the skill, and the guard's message is a
self-sufficient summary that also points to it. The procedure had drifted
across the rules, a workflow guide and the guard's message, for example on
low-severity findings, while the rules alone cost every session in both
clients its full text.

Each new reviewer result in `status.json` has a `usage` object with
`input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`,
`output_tokens` and `reasoning_output_tokens`. Counts come from Codex's
`turn.completed` JSON event or Claude's JSON `usage` result. Claude's
`cache_read_input_tokens` and `cache_creation_input_tokens` map to the
cache read and write fields. Missing, invalid and unavailable counters are
`null`, never inferred zeros; failed runs retain any available reported
usage without becoming successful reviews. Existing cached state is not
backfilled. These are native provider counts: Claude input excludes cache
reads and writes, while Codex input includes cached reads, so consumers must
keep the client identity rather than comparing these as identical totals.
No dollar cost is inferred.

A failed reviewer's output names the reason the client reported (for
example an expired sign-in, a usage limit or an unknown option), taken from
Claude's JSON result, Codex's JSON error events or the client's stderr, since
that reason otherwise sits in files nobody opens. `pr-review selftest` runs
every deep and light reviewer with the real clients, sandbox, models and
efforts on a built-in one-line change in the same work directory as real
runs, and passes only when each replies with a verdict
([#718](https://git.alc.xyz/alcxyz/nix-config/issues/718)). The tests' fake
clients cannot catch a client release that renames an option `pr-review`
passes or changes its JSON result, a sandbox change that stops a client from
starting, or an expired sign-in; each would fail every review, loudly but
only when an agent is ready to merge. With
`programs.ai.prReview.selftest.enable`, an hourly user timer runs it with
`--if-stale`, which skips while the last result is younger than
`staleHours` (24) and used the same reviewers, client binaries on `PATH` and
`pr-review` build, and a desktop notification reports a failure. A failure
is notified once per change or day rather than hourly; a manual
`pr-review selftest` retests at once. One run costs a few tens of thousands
of mostly cached input tokens across the reviewers.

Amended 2026-10-24 ([#802](https://git.alc.xyz/alcxyz/nix-config/issues/802)):
`run` waits on its reviewers together, so each result's `seconds` is that
reviewer's own run time; before, a reviewer checked second also counted the
time it waited on the first, which hid which client was slower. A reviewer
whose client reports a usage limit (Claude's JSON `api_error`
`usage_limit_reached`, or a "hit your ... limit" message in Claude's result or
Codex's JSON error events, never the log, which echoes the PR) is recorded as
`limited` with the message and the reset the client names. It is still a
missing review: the status only separates limits from broken clients in the
data and lets the output name the reset. Rerunning an incomplete head keeps
each result a reviewer completed for that head and target with identical
settings and an identical prompt, and runs only the missing reviewers;
`--force` runs them all. Before, a usage limit on one client meant paying the
other client's review twice. pr-review stores no limit marker and does not
wait for the claimed reset: a limited Claude reviewer failed within a second
in the recorded runs, so the next real run is about as cheap as any check, and
the claimed time can be wrong when a limit is lifted early. No Codex limit has
occurred in a recorded run yet, so its message format comes from the client's
strings and its timing is unmeasured.

Amended 2026-10-27 ([#858](https://git.alc.xyz/alcxyz/nix-config/issues/858)):
the pre-push hook covers every listed fast-forward repository, on Forgejo as
well as GitHub, and is registered whenever the list is non-empty. In every
listed repository, it also checks agent pushes to the head branch of an open
PR that has a completed review (a review comment other than a skip, or a
completed local round on its base): the push may add only `fixup!` or
`squash!` commits on top of a reviewed head, or rewrite the branch so that its
other commits keep the reviewed subjects in order, as a rebase or fold does.
That keeps fix rounds foldable into the curated commits that fast-forward
repositories merge. `pr-review curate <pr> --reason "..." [<commit>]` records
one commit the hook then accepts, for deliberate curation, and that commit
needs a new review; it is pinned to the commit and leaves a record, unlike an
environment variable. The comparison uses subjects, so an amended commit that
keeps its subject passes the hook and is reviewed again by the next `run`,
which cannot carry it. This check warns and lets the push through when a
lookup fails, because it shapes fix rounds rather than guarding a merge, and
it leaves Forgejo's protected branches (`main`, the default branch, any open
PR's base) to the forge. `pr-review merge-class` reads the same list and, as a
SessionStart hook for Claude Code and Codex, tells each session whether its
repository merges fast-forward only or squash-merges feature PRs.

Cost is tracked during an initial QA period before the requirement is
reconsidered ([#506](https://git.alc.xyz/alcxyz/nix-config/issues/506)).

## Alternatives Considered

- **Instruction only:** cheapest, but nothing catches a missed review.
- **Forge-side required check:** anyone can post the comment. It would also
  need organization agreement for GitHub repositories the operator does not own.
- **A `gh` wrapper for all users:** would also cover manual merges, which are
  out of scope, and could not cover Forgejo REST calls or web merges.
- **Recognize only supported executable contexts:** avoids false positives in
  unfamiliar programs, but silently loses the earlier guard's coverage of
  literal merges inside wrappers and inline code. Conservatively refusing
  ambiguous contexts preserves that coverage without claiming to interpret
  arbitrary programs; ordinary prose contexts are explicitly exempted.
- **A single fixed reviewer:** a model would review its own work when it is
  also the author.
- **Resuming the reviewers' earlier sessions for follow-ups:** conflicts with
  their ephemeral, isolated runs, and the earlier checkout is gone.
- **A follow-up time limit:** time alone does not make a follow-up wrong;
  changed reviewers do, and they force a full review.
- **Carrying reviews by patch ID or range-diff:** cheaper, but a patch that
  matches can sit in another identical block, as after a conflict resolution;
  replaying each reviewed commit and comparing trees cannot.
- **Reviewing every rebase or fold as a follow-up:** a follow-up needs a
  descendant head with the same merge base, so each would be a full review.
- **Chaining follow-ups through posted comments, checked by the guard:** agents
  fix and push before commenting, so it would need a comment for every round.
- **A light triage pass choosing the role:** adds a model call to every
  review, and a misjudged triage would lower review depth unnoticed; path and
  size rules are cheap, predictable and fail towards `deep`.
- **One light reviewer for documentation:** cheaper still, but drops the
  cross-model check this decision exists for.
- **The procedure in the global rules only:** always loaded, but kept in step
  with the guard's message and guides by hand, which drifted.
- **The guard's message only:** arrives only when a merge is blocked, too late
  to start the review early, and not at all where an untrusted Codex hook is
  skipped. The always-on requirement stays in the rules; a skill that fails to
  load costs one blocked merge, not a missed review.
- **A throwaway config directory for Claude too:** symmetric, but a token
  refresh during a review would sign the user out (see the isolation bullet),
  and restricted mode already keeps the user's instructions and files out.
- **A container or bubblewrap around each reviewer:** isolates both clients
  the same way, but adds a platform-specific layer around clients that already
  sandbox themselves, and a bind-mounted credential file changes how they
  write it.
- **`pr-review` in nix-packages:** reusable tooling lives there, but the command
  is tied to this decision's comment format, guard and reviewer settings, so it
  stays next to the guard.

## Consequences

The guard targets agent sessions on hosts with `programs.ai`. It is an accident
guard, not a security boundary: it catches an agent that forgets the review
and merges with an ordinary command. Commands built to get past it, such as
merge targets assembled at run time, quoting tricks or aliases, are out of
scope; stopping them would need a forge-side control (see Alternatives). An
agent can still post a review comment by
hand, and web merges, other merge tools and indirect commands without literal
merge syntax are not verified. Ambiguous executable contexts with literal
merge syntax are refused, which can require rewriting an unusual command.
Non-literal targets are not verified, GitHub Enterprise merges are blocked
because only github.com is supported, and a push between the guard's
lookup and the merge itself is not caught. Reviewers read the repository's
agent instructions from the PR head, so a PR that edits them can steer its own
review; such edits appear in the reviewed diff. Non-literal
targets are blocked with guidance to use literal values. Forgejo lookups use
`FORGEJO_API_TOKEN_FILE` when the session provides it, send the token only to
the configured Forgejo URL, and do not follow redirects. Forge or network outages
block agent merges until the operator merges or the outage ends. Each review
adds model cost and latency to every agent PR, less for documentation-only
PRs. A carried rebase is not reviewed against the target's new changes: a
clean textual replay can still conflict in meaning with them, which CI and
the target's own reviews must catch. The fast-forward checks see only commit
metadata the forge reports, and only for listed repositories. The light classification goes by path, so documentation that defines
policy without matching the deep patterns gets light reviewers unless the
agent passes `--role deep`. Comments in the earlier format
without a head SHA no longer satisfy the guard. Review prompts over 1 MB,
the PR diff included, are refused rather than truncated, and a follow-up
that would exceed that runs as a full review (a 400 kB diff bound until
2026-10-27). The bound follows the smallest reviewer context window at about
three bytes per token; hash-heavy diffs use more tokens per byte, so a
reviewer can still run out of context, which fails the round. Where both the managed
and a trusted user hook exist, the guard runs twice per call, which is harmless.
A host that enables `security.agentPrReviewGuard` for a user without
`programs.ai` blocks that user's Codex shell and Forgejo MCP calls. The managed
hook entry cannot be disabled by the user, but the guard it runs comes from the
user's profile, which the user can replace. The managed hook also checks merges
through a hand-made Codex server named `forgejo`, and applies to
`pr-review`'s own Codex reviewers, which cannot complete merge lookups without
network access. Reviewer isolation has limits: the Nix store stays readable to
Codex reviewers, so store paths built from private configuration can be read
by a reviewer that goes looking for them; environment variables other than
forge and token variables are still inherited; Claude still reads its own settings
and account files for sign-in, though not into the review; and the isolation
was verified on Linux, not yet on macOS. The command is tracked in
[#512](https://git.alc.xyz/alcxyz/nix-config/issues/512).
