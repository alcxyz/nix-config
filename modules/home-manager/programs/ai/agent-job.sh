# shellcheck shell=bash
# agent-job: run work that must outlive an agent session as a transient
# systemd user unit (nix-config #612). T3 runs each agent session in its own
# scope, so background commands die with the session; a transient unit does
# not. The unit runs `agent-job run DIR`, which executes the command stored in
# DIR/argv (no systemd escaping of the arguments), and its ExecStopPost runs
# `agent-job record DIR`, which keeps the result after --collect unloads it.
# The unit gets the user manager's environment (the one T3 and its agent
# sessions already run with, holding *_FILE credential pointers rather than
# values) plus the caller's PATH, not the caller's shell additions such as
# direnv. Tools come from that PATH, so the job sees the caller's PATH as is.
# The forge identity of an agent session (programs.ai.agentForge, #722) is
# not in the user manager's environment either, so the caller's
# FORGEJO_API_TOKEN_FILE, FORGEJO_TOKEN_FILE (clearing FORGEJO_TOKEN) and
# GIT_CONFIG_COUNT/KEY_n/VALUE_n are passed too, and so are the GitHub App
# settings GH_APP_ID, GH_APP_KEY_FILE and GH_APP_OWNER (programs.ai.agentGithub),
# when set: a job started by an agent acts as the agent account.

state_root=${AGENT_JOB_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-jobs}

usage() {
  cat >&2 <<'EOF'
usage: agent-job start NAME -- COMMAND [ARG...]
       agent-job wait NAME [SECONDS]   wait until NAME ends; 0 if it succeeded
       agent-job status NAME
       agent-job log NAME [LINES]
       agent-job stop NAME
       agent-job list
       agent-job clean NAME
EOF
  exit 64
}

fail() {
  local code=$1
  shift
  printf 'agent-job: %s\n' "$*" >&2
  exit "$code"
}

job() {
  [[ ${1-} =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || fail 64 "NAME must be lowercase letters, digits and dashes"
  name=$1
  unit=agent-job-$name.service
  dir=$state_root/$name
}

active_state() {
  systemctl --user show -P ActiveState "$unit"
}

running() {
  case $(active_state) in
    active | activating | deactivating | reloading) return 0 ;;
    *) return 1 ;;
  esac
}

field() {
  sed -n "s/^$1=//p" "$dir/$2"
}

# A finished job succeeded only if it exited with status 0. wait reports
# any failure as 1 so the job's own status cannot be mistaken for one of
# agent-job's exit codes; the summary line shows the real status.
succeeded() {
  [[ $(field code result) == exited && $(field status result) == 0 ]]
}

summary() {
  if [[ -f $dir/result ]]; then
    printf '%s: finished at %s (%s %s)\n' "$name" "$(field finished result)" "$(field code result)" "$(field status result)"
  elif running; then
    printf '%s: running since %s\n' "$name" "$(field started info)"
  else
    printf '%s: ended without a recorded result\n' "$name"
  fi
}

existing_job() {
  job "${1-}"
  [[ -d $dir ]] || fail 66 "no job named $name"
}

cmd=${1-}
(($# > 0)) && shift
case $cmd in
  start)
    job "${1-}"
    shift
    [[ ${1-} == -- ]] || usage
    shift
    (($# > 0)) || usage
    environment=(--setenv=PATH="$PATH")
    if [[ -n ${FORGEJO_API_TOKEN_FILE-} ]]; then
      environment+=(--setenv=FORGEJO_API_TOKEN_FILE="$FORGEJO_API_TOKEN_FILE")
    fi
    for app_setting in GH_APP_ID GH_APP_KEY_FILE GH_APP_OWNER; do
      if [[ -n ${!app_setting-} ]]; then
        environment+=(--setenv="$app_setting=${!app_setting}")
      fi
    done
    # forge-mirror prefers FORGEJO_TOKEN, which the user manager may hold;
    # it treats an empty one as unset and reads the file.
    if [[ -n ${FORGEJO_TOKEN_FILE-} ]]; then
      environment+=(--setenv=FORGEJO_TOKEN_FILE="$FORGEJO_TOKEN_FILE" --setenv=FORGEJO_TOKEN=)
    fi
    if [[ -n ${GIT_CONFIG_COUNT-} ]]; then
      [[ $GIT_CONFIG_COUNT =~ ^[0-9]+$ ]] || fail 64 "GIT_CONFIG_COUNT must be a number"
      environment+=(--setenv=GIT_CONFIG_COUNT="$GIT_CONFIG_COUNT")
      for ((i = 0; i < GIT_CONFIG_COUNT; i++)); do
        key=GIT_CONFIG_KEY_$i value=GIT_CONFIG_VALUE_$i
        environment+=(--setenv="$key=${!key-}" --setenv="$value=${!value-}")
      done
    fi
    [[ $dir =~ ^[A-Za-z0-9/._-]+$ ]] || fail 64 "state directory $dir must not need quoting"
    running && fail 73 "$name is already running"
    mkdir -p "$state_root"
    # mkdir without -p claims the name atomically against a concurrent start.
    mkdir "$dir" 2>/dev/null || fail 73 "$name already exists; read it, then run: agent-job clean $name"
    self=$(readlink -f "${BASH_SOURCE[0]}")
    # ExecStopPost runs this store path when the job ends, possibly after a
    # switch and garbage collection; root it until the job is cleaned.
    if [[ $self == /nix/store/*/bin/agent-job ]]; then
      if ! nix-store --add-root "$dir/agent-job" --realise "${self%/bin/agent-job}" >/dev/null; then
        rm -rf -- "$dir"
        fail 69 "could not add a garbage-collector root for $self"
      fi
    fi
    printf '%s\0' "$@" >"$dir/argv"
    printf -v shown '%q ' "$@"
    {
      printf 'started=%s\n' "$(date -Is)"
      printf 'cwd=%s\n' "$PWD"
      printf 'command=%s\n' "${shown% }"
    } >"$dir/info"
    if ! systemd-run --user --quiet --collect --same-dir \
      --unit="$unit" \
      "${environment[@]}" \
      -p StandardOutput=append:"$dir/log" \
      -p StandardError=append:"$dir/log" \
      -p ExecStopPost="$self record $dir" \
      -- "$self" run "$dir"; then
      rm -rf -- "$dir"
      fail 69 "systemd-run could not start $unit"
    fi
    printf 'started %s\nlog: %s\nwait: agent-job wait %s\n' "$unit" "$dir/log" "$name"
    ;;
  run)
    mapfile -d '' -t argv <"${1:?}/argv"
    exec "${argv[@]}"
    ;;
  record)
    # The Nix wrapper sets record_path to coreutils from agent-job's own
    # closure, which the job's root keeps; the caller's PATH may not survive.
    PATH=${record_path:-$PATH}
    {
      printf 'finished=%s\n' "$(date -Is)"
      printf 'code=%s\n' "${EXIT_CODE:-unknown}"
      printf 'status=%s\n' "${EXIT_STATUS:-unknown}"
    } >"${1:?}/result.tmp"
    mv -f -- "$1/result.tmp" "$1/result"
    ;;
  wait)
    existing_job "${1-}"
    interval=${2:-10}
    [[ $interval =~ ^[1-9][0-9]*$ ]] || usage
    until [[ -f $dir/result ]]; do
      if ! running; then
        # The result is written while the unit deactivates; look once more.
        sleep 1
        [[ -f $dir/result ]] && break
        summary
        fail 70 "no result recorded; see agent-job log $name"
      fi
      sleep "$interval"
    done
    summary
    tail -n 20 -- "$dir/log" 2>/dev/null || true
    succeeded || exit 1
    ;;
  status)
    existing_job "${1-}"
    summary
    printf 'cwd: %s\ncommand: %s\nlog: %s\n' "$(field cwd info)" "$(field command info)" "$dir/log"
    ;;
  log)
    existing_job "${1-}"
    lines=${2:-50}
    [[ $lines =~ ^[0-9]+$ ]] || usage
    tail -n "$lines" -- "$dir/log" 2>/dev/null || true
    ;;
  stop)
    existing_job "${1-}"
    running || fail 1 "$name is not running"
    systemctl --user stop "$unit"
    summary
    ;;
  list)
    [[ -d $state_root ]] || exit 0
    for d in "$state_root"/*/; do
      d=$(basename "$d")
      [[ $d =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || continue
      job "$d"
      summary
    done
    ;;
  clean)
    existing_job "${1-}"
    running && fail 73 "$name is still running; stop it first"
    rm -rf -- "$dir"
    ;;
  *) usage ;;
esac
