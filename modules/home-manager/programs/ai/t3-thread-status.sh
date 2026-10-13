# shellcheck shell=bash
# Report whether T3 threads are ready to settle, as facts in JSON (ADR-0091).
#
# Reads T3's state database read-only, and each thread's worktree with
# read-only git. It never fetches, so remote branches are as of the last fetch.

# The Nix wrapper sets these, and t3-state-db.sh's functions, before this text.
: "${common_sql:?}" "${status_sql:?}" "${default_dbs:?}"
prog=t3-thread-status
stale_hours=24
self=0
threads=()
dbs=()

usage() {
  cat >&2 <<'USAGE'
Usage: t3-thread-status [--self] [--stale-hours N] [--db PATH]... THREAD_ID...
  --self           THREAD_ID is the calling thread, whose run is still going:
                   skip the run, Settle: line and verdict, which the caller
                   decides, and list its own background tasks and PR watches
  --stale-hours N  idle time that counts as a long silence (default 24)
  --db PATH        state database to try (repeatable; default: every T3 instance)
Prints {database, generatedAt, threads: [...]}, one entry per thread ID.
Exit codes: 2 no database or thread found, 3 schema check or query failed,
64 usage.
USAGE
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --stale-hours | --db)
      if [ "$#" -lt 2 ]; then
        usage
        exit 64
      fi
      case $1 in
        --stale-hours) stale_hours=$2 ;;
        --db) dbs+=("$2") ;;
      esac
      shift 2
      ;;
    --self)
      self=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage
      exit 64
      ;;
    *)
      threads+=("$1")
      shift
      ;;
  esac
done

if [ "${#threads[@]}" -eq 0 ]; then
  usage
  exit 64
fi
if [ "$self" = 1 ] && [ "${#threads[@]}" -ne 1 ]; then
  echo "$prog: --self takes exactly one thread ID" >&2
  exit 64
fi
if ! [[ $stale_hours =~ ^[0-9]{1,4}$ ]]; then
  echo "$prog: --stale-hours must be a whole number of hours" >&2
  exit 64
fi
for thread in "${threads[@]}"; do
  if ! t3_valid_id "$thread"; then
    echo "$prog: unexpected characters in thread ID $thread" >&2
    exit 64
  fi
done
if [ "${#dbs[@]}" -eq 0 ]; then
  IFS=: read -r -a dbs <<<"${T3_STATE_DBS:-$default_dbs}"
fi

# Never let git refresh a worktree's index while reading it.
export GIT_OPTIONAL_LOCKS=0

# shellcheck disable=SC2034 # read by t3_sql
sql_extra=(-cmd ".parameter set :self $self")

selected=$(t3_select_db "${threads[0]}")
t3_check_schema "$selected"
# The worktree fields are nullable but always present.
t3_count_drift "$selected" "threads lack worktree or branch fields" \
  "SELECT count(*) FROM orchestration_v2_projection_threads WHERE json_type(payload_json, '\$.worktreePath') IS NULL OR json_type(payload_json, '\$.branch') IS NULL;"

# in_base PATH TIP REF: whether the changes TIP made since it left REF are all
# in REF, as true, false or null (no common history). They are when every
# file TIP changed has the same content in REF, or in a commit of REF with
# the same patch as the whole branch, as a squash merge leaves. A patch match
# alone is not enough, since patch IDs ignore where a hunk applies. Patches are
# compared verbatim, whitespace included, and without the user's diff colours,
# external diff tools or text conversions.
in_base() {
  local path=$1 tip=$2 ref=$3 mb own ids id commit rc=0
  local files=()
  local diff=(git -C "$path" --literal-pathspecs diff --no-color --no-ext-diff --no-textconv)
  mb=$(git -C "$path" merge-base "$tip" "$ref") || {
    echo null
    return
  }
  # NUL-separated, so names git would quote stay literal.
  mapfile -d '' -t files < <("${diff[@]}" --no-renames --name-only -z "$mb" "$tip")
  wait "$!" || return 1
  if [ "${#files[@]}" -eq 0 ]; then
    echo true
    return
  fi
  "${diff[@]}" --quiet "$ref" "$tip" -- "${files[@]}" || rc=$?
  case $rc in
    0)
      echo true
      return
      ;;
    1) ;;
    *) return 1 ;;
  esac
  own=$("${diff[@]}" "$mb" "$tip" | git patch-id --verbatim) || return 1
  ids=$(git -C "$path" log --no-color --no-ext-diff --no-textconv --first-parent -p \
    --format='commit %H' "$mb..$ref" | git patch-id --verbatim) || return 1
  if [ -n "$own" ]; then
    while read -r id commit; do
      [ "$id" = "${own%% *}" ] || continue
      rc=0
      "${diff[@]}" --quiet "$commit" "$tip" -- "${files[@]}" || rc=$?
      case $rc in
        0)
          echo true
          return
          ;;
        1) ;;
        *) return 1 ;;
      esac
    done <<<"$ids"
  fi
  echo false
}

# tip_facts PATH NAME BASE: commit facts for branch NAME of the worktree at
# PATH (HEAD when NAME is empty) as JSON, read-only. BASE is the branch its
# pull requests target, if known.
tip_facts() {
  local path=$1 name=$2 base=$3
  local tip=HEAD upstream="" short="" track="" remote=origin unpushed=0 ahead=null inbase=null
  if [ -n "$name" ]; then
    tip=refs/heads/$name
    if ! git -C "$path" show-ref --verify --quiet "$tip" &&
      [ "$name" != "$(git -C "$path" symbolic-ref --quiet --short HEAD)" ]; then
      # Gone from the worktree: its commits are unknown.
      jq -n --arg name "$name" '{name: $name, missing: true, unpushed: null, aheadOfBase: null, inBase: null}'
      return
    fi
    IFS='|' read -r upstream short track < <(git -C "$path" for-each-ref \
      --format='%(upstream)|%(upstream:short)|%(upstream:track)' "$tip") || true
  fi
  if [ -n "$upstream" ] && [ "$track" != "[gone]" ]; then
    remote=$(git -C "$path" config --get "branch.$name.remote") || remote=origin
  fi
  if [ -z "$base" ]; then
    base=$(git -C "$path" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD") || base=""
    base=${base#"$remote/"}
  fi
  # A new branch without commits has nothing to count.
  if git -C "$path" rev-parse --verify --quiet "$tip" >/dev/null; then
    if [ -n "$upstream" ] && [ "$track" != "[gone]" ]; then
      unpushed=$(git -C "$path" rev-list --count "$upstream..$tip") || return 1
    else
      # No upstream, or it was deleted: count commits no remote branch has.
      unpushed=$(git -C "$path" rev-list --count "$tip" --not --remotes) || return 1
    fi
    if [ -n "$base" ] && git -C "$path" rev-parse --verify --quiet "refs/remotes/$remote/$base" >/dev/null; then
      ahead=$(git -C "$path" rev-list --count "refs/remotes/$remote/$base..$tip") || return 1
      if [ "$ahead" != 0 ]; then
        inbase=$(in_base "$path" "$tip" "refs/remotes/$remote/$base") || return 1
      fi
    fi
  fi
  jq -n --arg name "$name" --arg upstream "$short" --arg track "$track" --argjson unpushed "$unpushed" \
    --arg base "${base:+$remote/$base}" --argjson ahead "$ahead" --argjson inBase "$inbase" '
    {name: (if $name == "" then null else $name end), missing: false,
     upstream: (if $upstream == "" then null else $upstream end), upstreamGone: ($track == "[gone]"),
     unpushed: $unpushed, base: (if $base == "" then null else $base end), aheadOfBase: $ahead, inBase: $inBase}'
}

# git_facts PATH BRANCH BASE: the worktree's state as JSON, read-only. Commit
# facts cover BRANCH, the thread's own branch, and the branch the worktree has
# checked out if that differs, since either can hold the thread's work.
# Returns non-zero if git cannot read an existing worktree.
git_facts() {
  local path=$1 branch=$2 base=$3
  local head="" changed=0 untracked=0 line status fact tips=()
  if [ -z "$path" ]; then
    echo null
    return
  fi
  if [ ! -e "$path" ]; then
    jq -n --arg path "$path" --arg branch "$branch" \
      '{path: $path, branch: $branch, exists: false}'
    return
  fi
  git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  head=$(git -C "$path" symbolic-ref --quiet --short HEAD) || head=""
  status=$(git -C "$path" status --porcelain=v1 --untracked-files=normal 2>/dev/null) || return 1
  while IFS= read -r line; do
    case $line in
      '') ;;
      '??'*) untracked=$((untracked + 1)) ;;
      *) changed=$((changed + 1)) ;;
    esac
  done <<<"$status"
  if [ -n "$branch" ]; then
    fact=$(tip_facts "$path" "$branch" "$base") || return 1
    tips+=("$fact")
  fi
  if [ -z "$branch" ] || [ "$head" != "$branch" ]; then
    fact=$(tip_facts "$path" "$head" "$base") || return 1
    tips+=("$fact")
  fi
  printf '%s\n' "${tips[@]}" | jq -s --arg path "$path" --arg branch "$branch" --arg head "$head" \
    --argjson changed "$changed" --argjson untracked "$untracked" '
    {path: $path, branch: (if $branch == "" then null else $branch end), exists: true,
     head: (if $head == "" then null else $head end),
     changed: $changed, untracked: $untracked, branches: .}'
}

# Derive the checks and the verdict from one thread's facts. A check passes
# (true), fails (false) or does not apply (null).
# shellcheck disable=SC2016 # a jq program
derive='
def plural($n; $what): "\($n) \($what)\(if $n == 1 then "" else "s" end)";
def name: .name // "HEAD";
. as $t
| ($t.worktree) as $w
| ($w != null and $w.exists and $w.error == null) as $git
| ([$t.prs[] | select(.state == "open")]) as $open
| ([$t.prs[] | select(.state == "merged")] | length > 0) as $merged
| ([$t.waitingOn[] | select(.kind != "command")]) as $holding
| ($t.run.status) as $run
| ($t.idleSince | if . == null then null
   else try ((now - (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) / 60 | floor) catch null end) as $idle
| ($t.settle) as $settle
# Commits on no remote branch are fine once their changes are in the base
# branch, as a squash merge whose branch was deleted leaves them. Every branch
# the thread used must pass; one gone from the worktree is unknown.
| (if $git then [$w.branches[] | select(.missing | not)] else [] end) as $tips
| (if $git then [$w.branches[] | select(.missing) | .name] else [] end) as $missing
| ($tips | map(select(.unpushed > 0 and .inBase != true))) as $unpushedTips
| ($tips | map(select((.aheadOfBase // 0) > 0 and .inBase != true))) as $unmergedTips
| (if ($unpushedTips | length) > 0 then false
   elif ($missing | length) > 0 or ($tips | length) == 0 then null
   else true end) as $pushed
| (if ($unmergedTips | length) > 0 or ($open | length) > 0 then false
   elif ($missing | length) == 0 and ($tips | length) > 0 and all($tips[]; .aheadOfBase != null) then true
   # A merged pull request vouches only for branches no longer in the worktree.
   elif $merged and all($tips[]; .aheadOfBase != null) then true
   else null end) as $landed
| [
    {id: "run", label: "Latest run ended cleanly",
     pass: (if $self == 1 then null elif $run == "completed" then true
            elif $run == "none" or $t.run.active or $run == "queued" then null else false end),
     detail: (if $self == 1 then "this run" elif $run == "none" then "never ran"
              elif $run == "waiting" then "waiting for input" else $run end)},
    {id: "background", label: "No background work left",
     pass: ($t.waitingOn | length == 0),
     detail: ($t.waitingOn | map("\(.kind): \(.description // "no description")") | join("; ") | if . == "" then null else . end)},
    {id: "clean", label: "No uncommitted changes",
     pass: (if $git then $w.changed + $w.untracked == 0 else null end),
     detail: (if $w == null then "no worktree" elif ($w.exists | not) then "worktree missing"
              elif $w.error != null then $w.error
              else "\($w.changed) changed, \($w.untracked) untracked" end)},
    {id: "pushed", label: "Commits pushed", pass: $pushed,
     detail: (if ($git | not) then null
              elif ($unpushedTips | length) > 0 then $unpushedTips
                | map("\(name): \(plural(.unpushed; "commit")) \(if .upstream != null and (.upstreamGone | not) then "not pushed to \(.upstream)"
                                                              elif .upstreamGone then "on no remote branch (upstream gone)"
                                                              else "on no remote branch" end)")
                | join("; ")
              elif ($missing | length) > 0 then $missing | map("\(.): not in the worktree") | join("; ")
              else $tips | map(select(.unpushed > 0) | "\(name): \(plural(.unpushed; "commit")) \(if .upstream != null and (.upstreamGone | not) then "not pushed to \(.upstream)" else "on no remote branch" end), but their changes are in \(.base)")
                | if length == 0 then "all pushed" else join("; ") end end)},
    {id: "landed", label: "Work merged", pass: $landed,
     detail: (if ($unmergedTips | length) > 0 then $unmergedTips | map("\(name): \(plural(.aheadOfBase; "commit")) not in \(.base)") | join("; ")
              elif ($open | length) > 0 then "open pull request"
              elif ($missing | length) == 0 and ($tips | length) > 0 and all($tips[]; .aheadOfBase != null) then
                "changes are in \($tips | map(.base) | unique | join(", "))"
              elif $landed == true then "pull request merged"
              else "no pull request or base branch" end)},
    {id: "prs", label: "No open pull requests",
     pass: ($open | length == 0),
     detail: ($open | map("#\(.number)") | join(", ") | if . == "" then null else . end)},
    {id: "settle", label: "Agent reported Settle: ready",
     pass: (if $self == 1 or $settle == null or $settle.stale then null else $settle.verdict == "ready" end),
     detail: (if $self == 1 then "this reply" elif $settle == null then "no Settle: line"
              elif $settle.stale then "Settle: line predates the latest user message"
              else $settle.line end)}
  ] as $checks
| (if $settle == null or $settle.stale or $settle.verdict == "unclear" then null else $settle.verdict end) as $claim
| ([ (if $git and $w.changed + $w.untracked > 0 then "uncommitted changes" else empty end),
     (if $pushed == false then "unpushed commits" else empty end),
     (if $run == "failed" or $run == "interrupted" or $run == "cancelled" then "run \($run)" else empty end),
     (if $idle != null and $idle >= $stale * 60 then "idle \($idle / 60 | floor)h" else empty end) ]) as $stallReasons
# A settled thread is done once its own current Settle: ready line and every
# fact agree; one that leaves steps for the user says so, and any other needs
# a closer look. A git check may go unanswered only where there is nothing to
# read: no worktree, or a removed one or deleted branch whose work a merged
# pull request vouches for. Steps that could not be read need a look too.
# Waiting and stalled describe live threads only.
| ($checks | map({key: .id, value: .pass}) | from_entries) as $pass
| ($w == null) as $noWorktree
| ($pass.run == true and $pass.background and $pass.prs and $pass.settle == true
   and ($pass.clean == true or $noWorktree or ($w.exists | not))
   and ($pass.pushed == true or $noWorktree or $pass.landed == true)
   and ($pass.landed == true or $noWorktree)
   and ($settle.leftForYouUnread | not)) as $agree
| (if $t.state == "settled" then
     (if $agree then (if $settle.leftForYou != null then "left-for-you" else "done" end)
      else "check" end)
   elif $self == 1 then null
   elif $t.run.active or $run == "queued" or ($holding | length) > 0 then "waiting"
   elif $claim != null then $claim
   elif ($stallReasons | length) > 0 then "stalled"
   else "not-yet" end) as $verdict
| $t + {self: ($self == 1), idleMinutes: $idle, checks: $checks, verdict: $verdict,
    stallReasons: (if $verdict == "stalled" then $stallReasons else [] end)}
'

# The Settle: line must be the last non-empty line of the newest finished
# assistant message, as the skill asks; it is stale once a user message has
# come after it. A --self report leaves it out: this reply will replace it.
# The user's steps are the text and list after the message's last Left for
# you: label outside code blocks, up to the Settle: line, which may carry them
# itself. Steps that cannot be read whole, and any other mention, are unread.
# shellcheck disable=SC2016 # a jq program
settle='
# A line, bullet or heading that starts with the label, colon optional only
# when nothing follows; list items, and lines indented to continue one.
def heading: "^[\\s#*+-]*Left for you[*_]*\\s*(:[*_]*\\s*|$)";
def item: "^\\s*([-*+]|[0-9]+[.)])\\s+";
def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
def none: test("^(nothing|none|n/?a)\\W*$"; "i");
(.lastAssistant | if . == null then null else fromjson end) as $a
| .lastUserAt as $user
| ($a.text // "" | [splits("\n") | select(test("\\S"))]) as $lines
| ($lines | last // "") as $last
| ([foreach $lines[] as $l ({fence: false};
     if ($l | test("^\\s*(```|~~~)")) then {fence: (.fence | not), code: true}
     else {fence, code: .fence} end;
     .code)]) as $code
| ([range(0; $lines | length) | select(($code[.] | not) and ($lines[.] | test(heading; "i")))] | last) as $at
| (if $self == 0 and ($last | test("^\\s*(\\*\\*)?Settle:(\\*\\*)?\\s")) then $last else null end) as $line
| . + {settle: (if $line == null then null else
    ($line | sub("^\\s*(\\*\\*)?Settle:(\\*\\*)?\\s*"; "") | sub("\\s+$"; "")) as $rest
    # Some put them on the Settle: line itself, with or without a label.
    | ($rest | capture("\\bLeft for you[*_]*\\s*:[*_]*\\s*(?<x>\\S.*)"; "i").x // "" | trim) as $inline
    | (if $at == null then {text: "", items: [], whole: true}
      else
        ($lines[$at + 1:-1]) as $section
        | {text: ($lines[$at] | sub(heading; ""; "i") | trim),
           items: (reduce $section[] as $l ([];
             if ($l | test(item)) then . + [$l | sub(item; "") | trim]
             else .[:-1] + [((.[-1] // "") + " " + ($l | trim)) | trim] end)),
           whole: all($section[]; test(item) or test("^\\s+\\S"))}
      end) as $p
    | ([$p.text, $p.items[], $inline | select(. != "" and (none | not))] | join("; ")) as $all
    # Steps that only say "nothing" or "none" are no steps.
    | ([$p.text, $p.items[], $inline | select(. != "")] | length > 0) as $said
    | {line: $rest[0:300],
       verdict: (if ($rest | test("^ready\\b"; "i")) then "ready"
                 elif ($rest | test("^not yet\\b"; "i")) then "not-yet" else "unclear" end),
       # not yet: <what remains>, <owner>
       owner: ($rest | capture(",\\s*(?<o>user|you|agent)\\W*$"; "i").o // null
               | if . == null then null elif ascii_downcase == "agent" then "agent" else "user" end),
       leftForYou: (if $all == "" then null else $all[0:600] end),
       leftForYouUnread: (($p.whole | not) or ($all | length) > 600
         or (($said | not) and ($a.text | test("left for you"; "i")))),
       at: $a.at,
       stale: ($user != null and $user > $a.at)}
    end)}
| del(.lastAssistant)
'

results=()
for thread in "${threads[@]}"; do
  if ! row=$(cat "$common_sql" "$status_sql" | t3_sql "$selected" "$thread" -json); then
    echo "$prog: query failed on $selected" >&2
    exit 3
  fi
  if [ -z "$row" ]; then
    echo "$prog: no thread $thread in $selected" >&2
    exit 2
  fi
  facts=$(jq -c '.[0] | .run |= fromjson | .prs |= fromjson | .waitingOn |= fromjson' <<<"$row")
  if ! jq -e '.lastAssistant == null or (.lastAssistant | fromjson | .text | type == "string")' <<<"$facts" >/dev/null; then
    echo "$prog: assistant message without text in $selected; T3's schema has changed" >&2
    exit 3
  fi
  path=$(jq -r '.worktreePath // ""' <<<"$facts")
  branch=$(jq -r '.branch // ""' <<<"$facts")
  base=$(jq -r '[.prs[] | .baseBranch // empty] | last // ""' <<<"$facts")
  # One unreadable worktree must not hide the other threads' facts.
  if ! worktree=$(git_facts "$path" "$branch" "$base"); then
    worktree=$(jq -n --arg path "$path" --arg branch "$branch" \
      '{path: $path, branch: $branch, exists: true, error: "git could not read the worktree"}')
  fi
  results+=("$(jq -c --argjson worktree "$worktree" --argjson stale "$stale_hours" --argjson self "$self" \
    "$settle | del(.worktreePath, .branch) | .worktree = \$worktree | $derive" <<<"$facts")")
done

printf '%s\n' "${results[@]}" | jq -s --arg db "$selected" \
  '{database: $db, generatedAt: (now | todate), threads: .}'
