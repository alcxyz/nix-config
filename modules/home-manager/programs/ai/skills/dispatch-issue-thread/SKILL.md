---
name: dispatch-issue-thread
description: Hand a piece of work to a new top-level T3 Code thread, tracked by an issue in the owning repository's forge. Use when the user asks to file an issue and start a separate thread, worktree or agent for it, or to dispatch, hand off or spin off work so it runs on its own.
---

# Dispatch issue thread

Files the work as an issue in its owning repository, then launches an ordinary
top-level T3 thread in its own worktree with a brief that points at the issue.
The issue holds scope, status and the result; the thread does the work. Use
`delegate_task` instead for child work this thread should wait for.

## 1. Issue

- Find the owning repository by the ownership rules in the global
  instructions, and read its hosting policy before writing to it.
- Search its open issues first and reuse a matching one.
- Otherwise create one in the Structured work shape: a status line (decided,
  next, owner), the context the work needs, what to compare or change, and a
  **Done when** list. Link related issues, ADRs and guides by path or URL so
  the new thread can read them.
- Keep private detail out of public repositories.

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
- `message`: the brief below.
- Leave model and modes to inherit unless the user names them.

Brief template:

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

The launch returns `threadId` and starts in `preparing`. It has no retry key:
if the call fails or its response is lost, call `t3_thread_list` with the
`projectId`, `includeSubagents: false` and `titleContains` set to the title
before launching again; the list is newest first.

## 4. Report

Give the user the issue link and the thread as
`[title](t3-thread://v1/<threadId>)`, using the `threadId` exactly as
returned. Say what the thread will do and which decisions it will bring back.
Do not poll or monitor it; the user follows it in T3, and the issue records
the outcome.
