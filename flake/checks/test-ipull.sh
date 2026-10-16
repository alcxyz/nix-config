# Exercise the generated ipull wrapper with invented repositories.
# Usage: test-ipull.sh IPULL ROOT, where ROOT is relative to a scratch directory.
set -euo pipefail

ipull=$1
root=$2
scratch=$(mktemp -d)
cd "$scratch"
export HOME="$scratch/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir "$HOME"
commit() { git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$2"; }

git init -q --bare -b dev upstream.git
git clone -q upstream.git seed 2>/dev/null
commit seed one
git -C seed push -q origin dev
git -C seed push -q origin dev:gone
mkdir -p "$root/infra"
for repo in behind clean dirty diverged gone; do
  git clone -q upstream.git "$root/infra/$repo" 2>/dev/null
done
git -C "$root/infra/gone" checkout -q -b gone --track origin/gone
commit seed two
git -C seed push -q origin dev
git -C seed push -q origin --delete gone
git -C "$root/infra/clean" pull -q --ff-only
git -C "$root/infra/behind" config branch.dev.mergeOptions --squash
echo x >"$root/infra/dirty/file"
git -C "$root/infra/dirty" add file
commit "$root/infra/diverged" local
mkdir "$root/infra/not-a-repo"
ln -s clean "$root/infra/zz-link"
git clone -q upstream.git outside 2>/dev/null
ln -s "$scratch/outside" "$root/infra/zz-outside"
git -C "$root/infra/clean" worktree add -q ../linked-worktree
git clone -q --separate-git-dir="$scratch/separate.git" upstream.git "$root/infra/separate" 2>/dev/null

expect() {
  local code=$1 want=$2 got rc=0
  got=$("$ipull") || rc=$?
  if [ "$rc" -ne "$code" ] || [ "$got" != "$want" ]; then
    printf 'ipull: want exit %s:\n%s\ngot exit %s:\n%s\n' "$code" "$want" "$rc" "$got" >&2
    exit 1
  fi
}

expect 1 "behind           dev: pulled 1
clean            dev: up to date
dirty            dev: local changes, 1 behind, skipped
diverged         dev: diverged (1 ahead, 1 behind), skipped
gone             gone: upstream gone, skipped
linked-worktree  linked worktree, skipped
separate         dev: up to date
zz-outside       dev: up to date"
[ "$(git -C "$root/infra/behind" rev-parse HEAD)" = "$(git -C seed rev-parse HEAD)" ]

rm -rf "$root/infra/diverged" "$root/infra/gone"
git -C "$root/infra/clean" worktree remove ../linked-worktree
rm -rf "$root/infra/separate" "$root/infra/zz-link" "$root/infra/zz-outside"
git -C "$root/infra/dirty" stash -q
git -C "$root/infra/dirty" pull -q --ff-only
git -C "$root/infra/dirty" stash pop -q
expect 0 "behind  dev: up to date
clean   dev: up to date
dirty   dev: up to date, local changes"

# Upstream starts tracking a path that is ignored and edited locally.
printf 'local.nix\n' >seed/.gitignore
git -C seed add .gitignore
commit seed ignore
echo upstream >seed/local.nix
git -C seed add -f local.nix
commit seed track
git -C seed push -q origin dev
echo mine >"$root/infra/clean/local.nix"
printf 'local.nix\n' >"$root/infra/clean/.git/info/exclude"
want="error: The following untracked working tree files would be overwritten by merge:"
got=$({ "$ipull" || true; } | sed -n 's/^clean   dev: merge failed: //p')
[ "$got" = "$want" ] || {
  echo "ipull overwrote or misreported an ignored file: $got" >&2
  exit 1
}
[ "$(cat "$root/infra/clean/local.nix")" = mine ]
rm -rf "$root/infra/behind" "$root/infra/dirty"

# SSH protections apply to a plain configured program; a command with its own
# arguments is used unchanged.
mkdir bin
printf '#!/bin/sh\necho "fake-ssh $*" >&2\nexit 1\n' >bin/ssh
chmod +x bin/ssh
git -C "$root/infra/clean" remote set-url origin fake-host:repo.git
git -C "$root/infra/clean" config core.sshCommand "$scratch/bin/ssh"
got=$("$ipull" || true)
case $got in
"clean  dev: fetch failed: fake-ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 "*fake-host*) ;;
*)
  echo "ipull did not protect a plain SSH program: $got" >&2
  exit 1
  ;;
esac
git -C "$root/infra/clean" config core.sshCommand "$scratch/bin/ssh -o Custom=yes"
got=$("$ipull" || true)
case $got in
*BatchMode*) ;;
"clean  dev: fetch failed: fake-ssh -o Custom=yes "*fake-host*) got="" ;;
esac
case $got in
"") ;;
*)
  echo "ipull rewrote an SSH command with arguments: $got" >&2
  exit 1
  ;;
esac
