# ADR-0098: Tag each promotion to `main` with a date version

**Status:** Accepted
**Date:** 2026-10-18
**Applies to:** `dev` to `main` promotions, repository tags and Forgejo releases

## Context

Work lands on `dev` and reaches `main` through a fast-forward promotion pull
request. A promotion leaves no record of its own: `main` simply moves to a
`dev` commit, so there is no name for "what `main` was on a given day" and no
summary of what each promotion carried. Promotions were also irregular: the
one on 2026-08-29 was followed by seven weeks of `dev` work.

Hosts deploy from a local checkout, not from `main`, and nothing reads a
version at build or run time. The released apps use semantic versions in a
`VERSION` file because their users depend on an interface; this repository has
no such interface whose breaking changes a major number could signal.

## Decision

Every promotion to `main` gets an annotated tag on the promoted commit, named
by the promotion date in Europe/Oslo: `vYYYY.MM.DD`, with `.2`, `.3` and so on
for later promotions the same day. The tag message is `nix-config vYYYY.MM.DD`.

Right after the fast-forward merge, whoever promotes:

1. fetches `main` and checks that it equals the promotion pull request's head
   commit, then tags that commit
   (`git tag -a <tag> -m "nix-config <tag>" <head sha>`) and pushes the tag to
   Forgejo; the GitHub mirror receives it with the other refs;
2. creates a Forgejo release from the tag. Its notes list the pull requests
   merged into `dev` whose merged head is reachable from the new tag but not
   from the previous one, taken from Forgejo rather than from commit subjects,
   with their titles, and the number of commits the promotion carried. A title
   that names something kept out of public text is listed by number only. The
   first tag covers everything since the last untagged promotion (`a079bd4d`,
   2026-08-29).

Tags are never moved or reused. A promotion that turns out wrong is fixed on
`dev` and promoted again under a new tag.

## Alternatives

- **Semantic versions in a `VERSION` file:** needs a release commit on `dev`
  before each promotion and a rule for what counts as major or minor in a
  configuration repository; nothing consumes the number.
- **No versions:** `main`'s history still shows each promotion, but without a
  name to refer to or a summary of what it carried.

## Consequences

- Each promotion has a name to cite in issues and a release page listing what
  it brought to `main`.
- The tag and release text are public, like the rest of the repository, so
  they follow the same naming rules as commits and pull requests; the git
  identity guard checks annotated tag names and messages on push.
- No workflow runs on tags, so tagging triggers no builds.
