# Fill the persistent CI Nix store from verified path lists, collect it by age
# and size, and publish a database snapshot for jobs (ADR-0109).
#
# Runs as the credential-free filler user with its own nix.conf. It adds
# only paths a trusted key signed, substituted from the configured caches,
# and github, gitlab and sourcehut flake inputs whose narHash it verified
# in a throwaway store. It never builds: every list entry is a store path to
# substitute, .drv files are dropped, and max-jobs is 0.
#
# Environment: CACHE_ROOT DROP_DIR NIX_PACKAGE MAX_AGE_DAYS SIZE_CAP_BYTES
# MIN_FREE_PERCENT RUN_LIMIT_BYTES STATE_DIRECTORY, and optionally LIST_MAX_BYTES,
# MAX_PATHS, MAX_INPUTS, FETCH_TIMEOUT, and OFFER_FORGE with OFFER_REPOS
# (space-separated owner/repo) and OFFER_MAX_RUNS for verified offers.
export LC_ALL=C
root=$CACHE_ROOT
drop=$DROP_DIR
store="local?root=$root"
db=$root/nix/var/nix/db/db.sqlite
runs=$root/nix/var/nix/gcroots/forgejo-nix-cache
job=$root/job
cap=$SIZE_CAP_BYTES
min_free=$MIN_FREE_PERCENT
run_limit=$RUN_LIMIT_BYTES
# Roots renewed this recently are never evicted to meet the cap.
recent_seconds=86400
list_max_bytes=${LIST_MAX_BYTES:-16777216}
max_paths=${MAX_PATHS:-200000}
# Paths and inputs taken from lists but not yet dealt with, oldest first, in
# the filler's private state directory, out of the jobs' reach.
pending_paths=$STATE_DIRECTORY/pending.paths
pending_inputs=$STATE_DIRECTORY/pending.inputs
max_inputs=${MAX_INPUTS:-500}
fetch_timeout=${FETCH_TIMEOUT:-600}
max_age_seconds=$((MAX_AGE_DAYS * 86400))
# Nix's rules for a store path: a 32-character base-32 hash, then a name of
# at most 211 characters from its set that does not start with a dot.
store_re='^/nix/store/[0-9a-df-np-sv-z]{32}-[A-Za-z0-9+_?=-][A-Za-z0-9+._?=-]{0,210}$'

if [[ $(stat -c %u -- "$root") != "$(id -u)" ]]; then
  printf 'fill_refused reason=owner path=%s\n' "$root" >&2
  exit 1
fi
mkdir -p -- "$runs" "$job"
work=$(mktemp -d "${RUNTIME_DIRECTORY:-/tmp}/fill.XXXXXX")
# Each flake input is fetched into its own throwaway store on the unit's
# private, size-limited /var/tmp, not into the cache, until its narHash is
# verified. The staging and Nix's download caches (XDG_CACHE_HOME, on the
# same tmpfs) are emptied after every input.
fetch=
clear_staging() {
  if [[ -n $fetch ]]; then
    chmod -R u+w -- "$fetch" 2>/dev/null || true
    rm -rf -- "$fetch"
  fi
  fetch=
  rm -rf -- "${XDG_CACHE_HOME:?}"
}
cleanup() {
  clear_staging
  rm -rf -- "$work"
}
trap cleanup EXIT

# The store's size as the sum of its NAR sizes, read from its own database.
store_bytes() {
  if [[ -s $db ]]; then
    sqlite3 -readonly "$db" 'select coalesce(sum(narSize), 0) from ValidPaths'
  else
    echo 0
  fi
}
free_percent() {
  df --output=avail,size -B1 -- "$root" | awk 'NR == 2 { printf "%d", $1 * 100 / $2 }'
}
# The ingestion budget, checked before each closure and input: the store
# under the size cap, at most RUN_LIMIT_BYTES added by this run, and the CI
# filesystem at least MIN_FREE_PERCENT free. A run overshoots the cap and
# its own limit by at most the closure it last admitted.
run_start_bytes=
over_budget() {
  local used free
  used=$(store_bytes)
  free=$(free_percent)
  run_start_bytes=${run_start_bytes:-$used}
  if ((used >= cap)); then
    budget_reason="cap bytes=$used"
    return 0
  fi
  if ((used - run_start_bytes >= run_limit)); then
    budget_reason="run_limit bytes=$((used - run_start_bytes))"
    return 0
  fi
  if ((free < min_free)); then
    budget_reason="disk_free percent=$free"
    return 0
  fi
  return 1
}
# A job container's conmon carries its name. Checked right before every
# addition and every collection step: the lower store must not change under
# a running job's overlay (undefined in overlayfs), and that job copied a
# database snapshot that may name the paths a collection would delete. A
# job that starts right after the check is not covered.
job_running() {
  grep -qsF -f <(printf 'FORGEJO-ACTIONS-TASK-\n') /proc/[0-9]*/cmdline
}
# Whether to stop adding paths for this run: a running job defers it, and
# the budget stops it.
ingest_blocked() {
  if job_running; then
    budget_reason=job_running
    block_kind=ingest_deferred
    return 0
  fi
  if over_budget; then
    block_kind=ingest_stopped
    return 0
  fi
  return 1
}

# 1. The cache's own Nix, which jobs run from the lower store.
: >"$work/nix.err"
if nix-store --store "$store" --check-validity "$NIX_PACKAGE" 2>/dev/null ||
  { ! job_running && nix-store --store "$store" --realise "$NIX_PACKAGE" >/dev/null 2>"$work/nix.err"; }; then
  ln -sfn -- "$NIX_PACKAGE" "$root/nix/var/nix/gcroots/job-nix"
  ln -sfn -- "$NIX_PACKAGE" "$job/nix.new"
  mv -T -- "$job/nix.new" "$job/nix"
else
  printf 'nix_unavailable path=%s error=%s\n' "$NIX_PACKAGE" "$(tail -n 1 "$work/nix.err")"
fi

# 2. Take the lists. Only the filler and root can write the drop directory
# (ADR-0109), but each entry is still treated as untrusted: plain names, regular files only, never followed, size-capped,
# and only well-formed store paths are kept. Only *.paths and *.lock are
# read and removed; anything else, such as a list still being written under
# a dot or .tmp name, is left alone and swept by root once it is older than
# a fill.
: >"$work/paths.raw"
mkdir -p -- "$work/locks"
lists=0
locks=0
shopt -s nullglob
for entry in "$drop"/*; do
  name=${entry##*/}
  if [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && ! -L $entry && -f $entry ]]; then
    case $name in
      *.paths)
        if dd if="$entry" iflag=nofollow,nonblock bs="$list_max_bytes" count=1 status=none 2>/dev/null |
          grep -Ex "$store_re" | grep -v '\.drv$' >>"$work/paths.raw"; then :; fi
        lists=$((lists + 1))
        rm -f -- "$entry" 2>/dev/null || true
        ;;
      *.lock)
        dd if="$entry" iflag=nofollow,nonblock bs="$list_max_bytes" count=1 status=none \
          of="$work/locks/$locks.json" 2>/dev/null || true
        locks=$((locks + 1))
        rm -f -- "$entry" 2>/dev/null || true
        ;;
    esac
  fi
done

# 2b. Verified offers, pulled from the forge (ADR-0109). No job can write
# anywhere the filler reads, so the filler looks runs up itself through the
# forge's anonymous API and takes an offer only from a run it verified: in an
# allowed public repository, finished, and either a push to that
# repository's default branch or a pull request whose head and base are that
# repository, never a fork. The paths come from the run's own job logs, as
# "nix-cache-offer <store path>" lines, and the flake lock from the
# repository at the run's commit, never from anything a job hands over. A run
# is read once; one still running is looked up again at the next fill.
fetch_url() {
  curl -q --silent --fail --proto '=https' --max-redirs 0 --max-time 60 \
    --max-filesize "$list_max_bytes" --output "$2" -- "$1"
}
# The HTTP status of a fetch into OUT, 000 when it did not complete.
fetch_status() {
  curl -q --silent --proto '=https' --max-redirs 0 --max-time 60 \
    --max-filesize "$list_max_bytes" --output "$2" --write-out '%{http_code}' -- "$1" ||
    printf '000'
}
offer_runs=0
offer_refused=0
offer_max_runs=${OFFER_MAX_RUNS:-20}
seen=$STATE_DIRECTORY/offer-runs.seen
touch -- "$seen"
if [[ -n ${OFFER_FORGE:-} && -n ${OFFER_REPOS:-} ]]; then
  for repo in $OFFER_REPOS; do
    if ! [[ $repo =~ ^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}$ ]]; then
      printf 'offer_repo_invalid repo=%s\n' "$repo"
      continue
    fi
    base=$OFFER_FORGE/api/v1/repos/$repo
    if ! fetch_url "$base" "$work/repo.json" ||
      ! default_branch=$(jq -er --arg repo "$repo" '
        select(.full_name == $repo and .private == false)
        | .default_branch | select(type == "string" and test("^[A-Za-z0-9._/-]{1,200}$"))
      ' "$work/repo.json" 2>/dev/null) ||
      ! fetch_url "$base/actions/runs?page=1&limit=$offer_max_runs" "$work/runs.json"; then
      printf 'offer_repo_unavailable repo=%s\n' "$repo"
      continue
    fi
    jq -r '.workflow_runs[]?.id | select(type == "number" and . > 0 and . == floor)' \
      "$work/runs.json" >"$work/run-ids" 2>/dev/null || : >"$work/run-ids"
    while IFS= read -r id; do
      if grep -qxF -- "$repo $id" "$seen"; then
        continue
      fi
      # The run itself, looked up by id, not the listing's copy of it.
      if ! fetch_url "$base/actions/runs/$id" "$work/run.json"; then
        printf 'offer_retry repo=%s run=%s reason=run\n' "$repo" "$id"
        continue
      fi
      verdict=$(jq -r --arg repo "$repo" --arg branch "$default_branch" --argjson id "$id" '
        (.event_payload | if type == "string" then (try fromjson catch null) else . end) as $p
        | if .id != $id or .repository.full_name != $repo then "refused run"
          elif (.status | IN("waiting", "running", "blocked")) then "pending"
          elif (.status | IN("success", "failure") | not) then "done"
          elif (.commit_sha | type != "string" or (test("^[0-9a-f]{40}$") | not)) then "refused commit"
          elif .event == "push" and .trigger_event == "push"
            and $p.ref == "refs/heads/\($branch)" and $p.repository.full_name == $repo
            then "verified \(.commit_sha)"
          elif .event == "pull_request" and .trigger_event == "pull_request"
            and .is_fork_pull_request == false
            and $p.pull_request.head.repo.full_name == $repo
            and $p.pull_request.base.repo.full_name == $repo
            then "verified \(.commit_sha)"
          else "refused event"
          end
      ' "$work/run.json" 2>/dev/null) || verdict="refused malformed"
      case $verdict in
        pending)
          continue
          ;;
        verified\ *)
          commit=${verdict#verified }
          # A run reads "failure" as soon as one job fails, while others may
          # still run and print offers: every job must have finished. A job
          # list that cannot be read is tried again at the next fill.
          if ! fetch_url "$base/actions/runs/$id/jobs" "$work/jobs.json" ||
            ! jq -e 'type == "array" and all(.[];
                (.id | type == "number" and . > 0 and . == floor) and (.status | type == "string"))' \
              "$work/jobs.json" >/dev/null 2>&1; then
            printf 'offer_retry repo=%s run=%s reason=jobs\n' "$repo" "$id"
            continue
          fi
          if jq -e 'any(.[]; .status | IN("success", "failure", "cancelled", "skipped") | not)' \
            "$work/jobs.json" >/dev/null 2>&1; then
            continue
          fi
          # Every job that ran, a cancelled one included, may have printed
          # offers. A cancelled job's log may not exist, so only the logs of
          # jobs that finished hold the run back when they cannot be fetched.
          jq -r '.[] | select(.status | IN("success", "failure", "cancelled")) | "\(.id) \(.status)"' \
            "$work/jobs.json" >"$work/job-ids" 2>/dev/null || : >"$work/job-ids"
          : >"$work/offer.paths"
          complete=1
          while read -r job_id job_status; do
            if fetch_url "$base/actions/jobs/$job_id/logs" "$work/job.log"; then
              sed -nE 's/^[0-9T:.Z-]+ nix-cache-offer (\/nix\/store\/[^ ]+)\r?$/\1/p' "$work/job.log" |
                grep -Ex "$store_re" | grep -v '\.drv$' >>"$work/offer.paths" || true
            elif [[ $job_status != cancelled ]]; then
              complete=0
            fi
          done <"$work/job-ids"
          # A log or lock that could not be fetched leaves the run for the
          # next fill, as long as it stays among the latest runs.
          if ((!complete)); then
            printf 'offer_retry repo=%s run=%s reason=log\n' "$repo" "$id"
            continue
          fi
          if [[ ! -s $work/offer.paths ]]; then
            printf 'offer_none repo=%s run=%s\n' "$repo" "$id"
          else
            # A repository without a flake lock answers 404.
            case $(fetch_status "$OFFER_FORGE/$repo/raw/commit/$commit/flake.lock" "$work/lock.json") in
              200)
                mv -- "$work/lock.json" "$work/locks/$locks.json"
                locks=$((locks + 1))
                ;;
              404) ;;
              *)
                printf 'offer_retry repo=%s run=%s reason=lock\n' "$repo" "$id"
                continue
                ;;
            esac
            cat -- "$work/offer.paths" >>"$work/paths.raw"
            offer_runs=$((offer_runs + 1))
            printf 'offer_taken repo=%s run=%s commit=%s paths=%s\n' "$repo" "$id" "$commit" "$(sort -u "$work/offer.paths" | wc -l)"
          fi
          ;;
        done)
          printf 'offer_skipped repo=%s run=%s\n' "$repo" "$id"
          ;;
        refused\ *)
          offer_refused=$((offer_refused + 1))
          printf 'offer_refused repo=%s run=%s reason=%s\n' "$repo" "$id" "${verdict#refused }"
          ;;
      esac
      printf '%s %s\n' "$repo" "$id" >>"$seen"
    done <"$work/run-ids"
  done
  # Remember the latest runs only.
  tail -n 5000 -- "$seen" >"$seen.new" && mv -- "$seen.new" "$seen"
fi
# Merge into the pending queue, keeping each entry's first arrival, and drop
# the oldest beyond the bound.
merge_pending() {
  local queue=$1 new=$2 bound=$3 kind=$4 total
  touch -- "$queue"
  cat -- "$queue" "$new" | awk '!seen[$0]++' >"$work/merged"
  total=$(wc -l <"$work/merged")
  if ((total > bound)); then
    printf 'pending_dropped %s=%s\n' "$kind" "$((total - bound))"
  fi
  tail -n "$bound" -- "$work/merged" >"$queue.new"
  mv -- "$queue.new" "$queue"
}
# Keep in the queue only the entries listed in FILE.
keep_pending() {
  local queue=$1 keep=$2
  awk 'NR == FNR { keep[$0]; next } $0 in keep' "$keep" "$queue" >"$queue.new"
  mv -- "$queue.new" "$queue"
}
merge_pending "$pending_paths" "$work/paths.raw" "$max_paths" paths
sort -u -- "$pending_paths" >"$work/paths"
requested=$(wc -l <"$work/paths")

# 3. Listed paths already in the store are rooted again, which renews them
# without fetching. Missing ones are substituted one closure at a time
# within the budget, and only while no job runs. A batch whose validity
# check fails is checked path by path; a path whose state stays unknown is
# never counted present. Paths not yet tried, because a job ran or the
# budget was reached, and unknown ones stay queued for the next fill; a path
# that was tried leaves the queue whether or not it could be substituted.
: >"$work/invalid"
: >"$work/unknown"
split -l 500 -- "$work/paths" "$work/batch." 2>/dev/null || true
for batch in "$work"/batch.*; do
  mapfile -t batch_paths <"$batch"
  if ! nix-store --store "$store" --check-validity --print-invalid "${batch_paths[@]}" >>"$work/invalid" 2>/dev/null; then
    while IFS= read -r path; do
      if ! nix-store --store "$store" --check-validity --print-invalid "$path" >>"$work/invalid" 2>/dev/null; then
        printf '%s\n' "$path" >>"$work/unknown"
      fi
    done <"$batch"
  fi
done
sort -u -o "$work/unknown" "$work/unknown"
sort -u "$work/invalid" | comm -23 - "$work/unknown" >"$work/missing"
comm -23 "$work/paths" "$work/missing" | comm -23 - "$work/unknown" >"$work/valid"
renewed=$(wc -l <"$work/valid")
substituted=0
budget_reason=
block_kind=
cp -- "$work/unknown" "$work/still-pending"
while IFS= read -r path; do
  if [[ -z $budget_reason ]] && ingest_blocked; then
    printf '%s reason=%s\n' "$block_kind" "$budget_reason"
  fi
  if [[ -n $budget_reason ]]; then
    printf '%s\n' "$path" >>"$work/still-pending"
    continue
  fi
  if nix-store --store "$store" --realise --max-jobs 0 "$path" >/dev/null 2>>"$work/realise.err"; then
    printf '%s\n' "$path" >>"$work/valid"
    substituted=$((substituted + 1))
  fi
done <"$work/missing"
keep_pending "$pending_paths" "$work/still-pending"

# 4. Flake inputs: only github, gitlab and sourcehut, on their canonical
# public hosts, pinned to a commit and a narHash. No host override, URL,
# submodules or other type: those could reach other hosts through the URL,
# a redirect or a submodule. An input already in the store (its path
# follows from the narHash) is rooted again without fetching; a missing one
# is fetched into a throwaway store, checked against its pin there, and
# only then copied in. Refused inputs, inputs present or tried, and inputs
# whose fetch or pin check failed leave the queue; inputs not yet tried stay.
: >"$work/inputs.raw"
for lock in "$work"/locks/*.json; do
  jq -c '
    (.nodes // {}) | to_entries[] | .value.locked? // empty | select(type == "object")
    | .type as $type
    | {
        allowed: ((.type | IN("github", "gitlab", "sourcehut"))
          and ((keys - ["type", "owner", "repo", "rev", "ref", "narHash", "lastModified"]) == [])
          and (.owner | if type == "string" then test(if $type == "sourcehut" then "^~?[A-Za-z0-9._%-]{1,100}$" else "^[A-Za-z0-9._%-]{1,100}$" end) else false end)
          and (.repo | if type == "string" then test("^[A-Za-z0-9._%-]{1,100}$") else false end)
          and (.rev | if type == "string" then test("^[0-9a-f]{40}$") else false end)
          and (.narHash | if type == "string" then test("^sha256-[A-Za-z0-9+/]{43}=$") else false end)),
        input: {type, owner, repo, rev, narHash}
      }
  ' "$lock" >>"$work/inputs.raw" 2>/dev/null || true
done
sort -u "$work/inputs.raw" >"$work/inputs.new"
inputs_refused=$(jq -s 'map(select(.allowed != true)) | length' "$work/inputs.new")
jq -c 'select(.allowed == true) | .input' "$work/inputs.new" >"$work/inputs.allowed"
merge_pending "$pending_inputs" "$work/inputs.allowed" "$max_inputs" inputs
inputs=0
inputs_present=0
inputs_failed=0
: >"$work/inputs.still-pending"
while IFS= read -r input; do
  printf '%s\n' "$input" >"$work/input.json"
  pin=$(jq -r .narHash "$work/input.json")
  expected=$(nix-store --store "$store" --print-fixed-path --recursive sha256 \
    "$(nix hash convert --hash-algo sha256 --to nix32 "$pin")" source 2>/dev/null) || expected=
  if [[ $expected =~ $store_re ]] && nix-store --store "$store" --check-validity "$expected" 2>/dev/null; then
    printf '%s\n' "$expected" >>"$work/valid"
    inputs_present=$((inputs_present + 1))
    continue
  fi
  if [[ -z $budget_reason ]] && ingest_blocked; then
    printf '%s reason=%s\n' "$block_kind" "$budget_reason"
  fi
  if [[ -n $budget_reason ]]; then
    printf '%s\n' "$input" >>"$work/inputs.still-pending"
    continue
  fi
  fetch=$(mktemp -d /var/tmp/fetch.XXXXXX)
  out=
  if out=$(INPUT_JSON="$work/input.json" timeout "$fetch_timeout" nix --store "local?root=$fetch" eval --impure --raw \
    --expr '(builtins.fetchTree (builtins.fromJSON (builtins.readFile (builtins.getEnv "INPUT_JSON")))).outPath' \
    2>>"$work/fetch.err") && [[ $out == "$expected" ]] &&
    actual=$(nix path-info --store "local?root=$fetch" --json --json-format 1 "$out" 2>/dev/null |
      jq -r 'if type == "array" then .[0].narHash else .[].narHash end') &&
    [[ $(nix hash convert --to sri "$actual" 2>/dev/null) == "$pin" ]] &&
    nix copy --no-check-sigs --from "local?root=$fetch" --to "$store" "$out" 2>>"$work/fetch.err"; then
    printf '%s\n' "$out" >>"$work/valid"
    inputs=$((inputs + 1))
  else
    inputs_failed=$((inputs_failed + 1))
  fi
  clear_staging
done <"$pending_inputs"
keep_pending "$pending_inputs" "$work/inputs.still-pending"
staging_left=$(du -sb /var/tmp 2>/dev/null | cut -f1)

# 5. One GC root directory per run, named by its time, holding every path it
# added or renewed.
if [[ -s $work/valid ]]; then
  run_dir=$runs/$(date +%s)
  mkdir -p -- "$run_dir"
  sort -u "$work/valid" | xargs ln -sf -t "$run_dir" --
fi
printf 'fill lists=%s locks=%s requested=%s renewed=%s substituted=%s skipped=%s inputs=%s inputs_present=%s inputs_failed=%s inputs_refused=%s staging_left=%s pending_paths=%s pending_inputs=%s offers=%s offers_refused=%s\n' \
  "$lists" "$locks" "$requested" "$renewed" "$substituted" "$((requested - renewed - substituted))" \
  "$inputs" "$inputs_present" "$inputs_failed" "$inputs_refused" "$staging_left" \
  "$(wc -l <"$pending_paths")" "$(wc -l <"$pending_inputs")" "$offer_runs" "$offer_refused"

# 6. Collect: drop roots older than the age limit, then the oldest roots
# until the store is under the cap, but never roots renewed within the last
# day: a hostile list cannot evict what jobs use now, and ingestion stays
# stopped at the cap instead. Each deletion waits for no job container to
# run right before it; a job that starts during a collection can still lose
# a path its snapshot names.
now=$(date +%s)
expired=0
for dir in "$runs"/*; do
  stamp=${dir##*/}
  if [[ $stamp =~ ^[0-9]+$ ]] && ((now - stamp > max_age_seconds)); then
    rm -rf -- "$dir"
    expired=$((expired + 1))
  fi
done
dropped=0
collected=0
if job_running; then
  printf 'gc_deferred reason=job_running\n'
else
  nix-store --store "$store" --gc >/dev/null 2>&1 || true
  collected=1
  while used=$(store_bytes) && ((used > cap)); do
    oldest=
    recent=0
    for dir in "$runs"/*; do
      stamp=${dir##*/}
      [[ $stamp =~ ^[0-9]+$ ]] || continue
      if ((now - stamp < recent_seconds)); then
        recent=$((recent + 1))
        continue
      fi
      if [[ -z $oldest ]] || ((stamp < oldest)); then
        oldest=$stamp
      fi
    done
    if [[ -z $oldest ]]; then
      if ((recent > 0)); then
        printf 'cap_held bytes=%s cap=%s recent_roots=%s\n' "$used" "$cap" "$recent"
      else
        printf 'cap_unreachable bytes=%s cap=%s\n' "$used" "$cap"
      fi
      break
    fi
    if job_running; then
      printf 'gc_deferred reason=job_running\n'
      break
    fi
    rm -rf -- "${runs:?}/$oldest"
    dropped=$((dropped + 1))
    nix-store --store "$store" --gc >/dev/null 2>&1 || true
  done
fi
printf 'gc collected=%s expired=%s dropped=%s bytes=%s cap=%s\n' "$collected" "$expired" "$dropped" "$(store_bytes)" "$cap"

# 7. Publish a database snapshot when the set of valid paths changed and
# every valid path is rooted, so jobs never see a path that is not kept,
# such as part of a failed substitution or a root expired while collection
# waited. Jobs copy it into their own /nix/var/nix/db; the lower database
# is never opened by a job. The previous snapshot stays for jobs still
# copying it.
if dead_paths=$(nix-store --store "$store" --gc --print-dead 2>/dev/null); then
  dead=$(grep -c . <<<"$dead_paths" || true)
else
  dead=unknown
fi
nix path-info --store "$store" --all 2>/dev/null | sort | sha256sum | cut -d' ' -f1 >"$work/paths.sha256"
if [[ $dead == unknown ]]; then
  printf 'snapshot deferred reason=dead_unknown\n'
elif ((dead > 0)); then
  printf 'snapshot deferred reason=unrooted paths=%s\n' "$dead"
elif [[ ! -e $job/db/paths.sha256 ]] || ! cmp -s "$work/paths.sha256" "$job/db/paths.sha256"; then
  generation=db.$(date +%s%N)
  mkdir -- "$job/$generation"
  sqlite3 "$db" "VACUUM INTO '$job/$generation/db.sqlite'"
  cp -- "$root/nix/var/nix/db/schema" "$job/$generation/schema"
  cp -- "$work/paths.sha256" "$job/$generation/paths.sha256"
  ln -sfn -- "$generation" "$job/db.new"
  mv -T -- "$job/db.new" "$job/db"
  mapfile -t generations < <(printf '%s\n' "$job"/db.[0-9]* | sort)
  if ((${#generations[@]} > 2)); then
    for old in "${generations[@]:0:${#generations[@]}-2}"; do
      rm -rf -- "$old"
    done
  fi
  printf 'snapshot published generation=%s bytes=%s\n' "$generation" "$(stat -c %s -- "$job/$generation/db.sqlite")"
fi
