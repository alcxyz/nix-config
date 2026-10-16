# Fast-forward every checkout directly under $dir, fetching in parallel.
# The wrapper defines dir. Never rebases, resets or switches branches.

shopt -s nullglob
repos=()
# A link to a listed checkout would fetch it twice in parallel; keep the first.
declare -A seen=()
for path in "$dir"/*/; do
  [ -e "$path.git" ] || continue
  real=$(realpath "$path")
  [ -z "${seen[$real]:-}" ] || continue
  seen[$real]=1
  repos+=("${path%/}")
done
if [ "${#repos[@]}" -eq 0 ]; then
  echo "ipull: no repositories under $dir" >&2
  exit 1
fi

pull() {
  local branch counts ahead behind dirty note err rc=0
  # Linked worktrees share their repository's refs; fetching them in parallel
  # with it races on the same ref locks.
  [ "$(git rev-parse --absolute-git-dir)" = "$(git rev-parse --path-format=absolute --git-common-dir)" ] || {
    echo "linked worktree, skipped"
    return 0
  }
  branch=$(git symbolic-ref --quiet --short HEAD) || {
    echo "detached HEAD, skipped"
    return 1
  }
  git config --get "branch.$branch.merge" >/dev/null || {
    echo "$branch: no upstream, skipped"
    return 1
  }
  # Errors go to a file, not a pipe: a transport child that outlives git would
  # keep a pipe open and block ipull past the deadline.
  # The outer redirection hides bash's notice when the deadline kills git.
  { timeout --kill-after=10 120 git fetch --quiet --prune 2>"$1"; } 2>/dev/null || rc=$?
  err=$(cat "$1")
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "$branch: fetch timed out, skipped"
    return 1
  elif [ "$rc" -ne 0 ]; then
    echo "$branch: fetch failed: ${err%%$'\n'*}"
    return 1
  fi
  git rev-parse --quiet --verify '@{upstream}' >/dev/null || {
    echo "$branch: upstream gone, skipped"
    return 1
  }
  counts=$(git rev-list --left-right --count 'HEAD...@{upstream}')
  read -r ahead behind <<<"$counts"
  dirty=$(git status --porcelain --untracked-files=no)
  if [ "$behind" -eq 0 ]; then
    note=""
    [ "$ahead" -gt 0 ] && note+=", $ahead to push"
    [ -n "$dirty" ] && note+=", local changes"
    echo "$branch: up to date$note"
    return 0
  fi
  if [ "$ahead" -gt 0 ]; then
    echo "$branch: diverged ($ahead ahead, $behind behind), skipped"
    return 1
  fi
  if [ -n "$dirty" ]; then
    echo "$branch: local changes, $behind behind, skipped"
    return 1
  fi
  if ! err=$(git merge --ff-only --no-squash --no-overwrite-ignore --quiet '@{upstream}' 2>&1); then
    echo "$branch: merge failed: ${err%%$'\n'*}"
    return 1
  fi
  echo "$branch: pulled $behind"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Parallel fetches must fail rather than interleave credential, passphrase or
# host-key prompts. SSH options are only added to a plain program name or path,
# which is the default; a configured command with arguments, quoting or GIT_SSH
# is used unchanged and relies on the fetch deadline.
export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="" SSH_ASKPASS_REQUIRE=never
ssh_options="-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2"
for i in "${!repos[@]}"; do
  (
    cd "${repos[$i]}" || exit 1
    ssh=${GIT_SSH_COMMAND:-$(git config --get core.sshCommand || true)}
    [ -n "$ssh" ] || [ -n "${GIT_SSH:-}" ] || ssh=ssh
    case $ssh in
    "" | *[[:space:]\"\'\\=\$]*) ;;
    *) export GIT_SSH_COMMAND="$ssh $ssh_options" ;;
    esac
    pull "$tmp/$i.err" >"$tmp/$i" 2>&1
  ) &
  pids[i]=$!
done

status=0
width=0
for repo in "${repos[@]}"; do
  name=${repo##*/}
  [ "${#name}" -gt "$width" ] && width=${#name}
done
for i in "${!repos[@]}"; do
  wait "${pids[$i]}" || status=1
  printf '%-*s  %s\n' "$width" "${repos[$i]##*/}" "$(cat "$tmp/$i")"
done
exit "$status"
