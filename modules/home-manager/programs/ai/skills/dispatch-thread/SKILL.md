---
name: dispatch-thread
description: Hand a piece of work to a new top-level T3 Code thread in its own worktree, for an existing issue, a new issue or ad hoc without one. Use when the user asks to dispatch, hand off or spin off work, to start a separate thread, worktree or agent for it, or to dispatch an issue (for example "dispatch nix-config #596").
---

# Dispatch thread

Launches an ordinary top-level T3 thread in its own worktree with a brief that
says what to do. When the work is tracked by an issue, the issue holds scope,
status and the result, and the thread does the work; ad hoc work carries its
scope in the brief and reports in the thread. Use `delegate_task` instead for
child work this thread should wait for.

## 1. Issue

Find the repository that owns the work by the ownership rules in the global
instructions, even when no issue is involved: the thread launches in its
checkout, not necessarily the one you are in. Then pick the case:

- **The user names an issue**: use it. Read it to write the brief, and
  confirm it is open and in the owning repository. If it is closed or lives
  elsewhere, ask the user rather than launching or filing a duplicate.
- **Multi-step work, or work that must outlast the thread**: track it in an
  issue, as the global rules ask for unfinished work. Read the owning
  repository's hosting policy before writing to it. Search its open issues and
  reuse a match; otherwise create one in the Structured work shape: a status
  line (decided, next, owner), the context the work needs, what to compare or
  change, and a **Done when** list. Link related issues, ADRs and guides by
  path or URL so the new thread can read them. Keep private detail out of
  public repositories.
- **The user asks for no issue, or the task is small and self-contained**:
  file no issue and use the ad hoc brief in step 3. If the thread may well
  find follow-up work, say in the brief that it should propose an issue rather
  than leave the work untracked.

## 2. Project

List T3 projects with `t3_project_list` (`limit: 100`), following
`nextCursor` until it is null, and pick the one whose `workspaceRoot` is the
repository's checkout. Old entries can point at paths that no longer exist
(for example `~/gitops`), and one repository can have two entries; check that
the root exists and is the repository's top level before using it. If no
project matches, ask the user rather than launching into a look-alike.

## 3. Launch

Call `t3_thread_launch` with:

- `projectId` from step 2.
- `workspaceStrategy`:
  `{"type":"worktree","baseRef":"<integration branch>","branch":"<prefix>/<slug>","startFromOrigin":true}`.
  The base is usually `dev`; use the repository's documented integration
  branch. Prefixes follow the work: `feat/`, `fix/`, `docs/`, `eval/`. T3
  creates and manages the worktree under `~/.t3/worktrees/`; do not ask the
  thread to create its own.
- `title`: a short imperative, such as "Evaluate fj vs tea for agents".
- `message`: one of the briefs below.
- Leave model and modes to inherit unless the user names them.

Issue brief:

```text
Work on <issue URL>: <one sentence goal>. Read the issue first; it lists the
scope and when it is done.

Context:
- <the two to five facts the thread needs that the issue does not say>

How to work:
- <limits: credentials, read-only or throwaway test objects, what not to touch>
- Post the result on the issue in the usual short shape, evidence collapsed.
- Ask the user before <the decisions that stay theirs>; then change things
  only through reviewed PRs and keep the issue status current.
```

Ad hoc brief:

```text
<one sentence goal>. No issue tracks this; the scope is below.

Context:
- <the facts the thread needs: where to look, related files, ADRs or guides>

Scope:
- <what to change or find out, and what is out of scope>

Done when:
- <checkable outcomes>

How to work:
- <limits: credentials, read-only or throwaway test objects, what not to touch>
- Report the result in this thread in the usual short shape.
- Ask the user before <the decisions that stay theirs>; change things only
  through reviewed PRs. If the work grows beyond this scope, propose an issue
  instead of extending it.
```

The launch returns `threadId` and starts in `preparing`. It has no retry key:
if the call fails or its response is lost, call `t3_thread_list` with the
`projectId`, `includeSubagents: false` and `titleContains` set to the title
before launching again; the list is newest first.

## 4. Report

Give the user the thread as `[title](t3-thread://v1/<threadId>)`, using the
`threadId` exactly as returned, and the issue link when there is one. Say what
the thread will do and which decisions it will bring back. Do not poll or
monitor it; the user follows it in T3, and the issue, or for ad hoc work the
thread, records the outcome.
