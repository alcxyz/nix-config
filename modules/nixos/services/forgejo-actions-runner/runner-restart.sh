#!/usr/bin/env bash
set -euo pipefail

# forgejo-runner-restart (ADR-0041, nix-packages ADR-0017): restarts the
# runner units, engine APIs and resource policy that still run an older
# definition, once every runner on the host is idle. These units have
# restartIfChanged = false, so a switch leaves them running; restarting the
# resource policy or an API also restarts the runners that require it, so the
# whole host must be idle, not only the unit.
#
# Idle means: the Podman store reset does not run, no runner is starting or
# stopping, no job container runs on a running engine, and no runner took a
# task within the quiet interval (a job still pulling its image has no
# container yet). The same checks keep the store reset from stopping a busy
# runner (ADR-0105). While the host is busy it waits, up to the wait limit;
# then it gives up and reports busy, so it never cancels a job on purpose. A
# job admitted between the last check and the stop gets the runner's normal
# graceful stop.
#
# Its progress and result go to a world-readable state file that
# nixfleet-runner-status reports: status=waiting|restarting|done|nothing|busy|
# failed, time=<unix seconds>, one unit= line per unit it restarts or would,
# and reason=.

# shellcheck disable=SC1090
source "${STATE_HELPER_FILE:-$(dirname "${BASH_SOURCE[0]}")/runner-state.sh}"

state_file=${STATE_FILE:-/run/nixfleet-runners/restart}
journalctl_bin=${JOURNALCTL_BIN:-journalctl}
curl_bin=${CURL_BIN:-curl}
jq_bin=${JQ_BIN:-jq}
date_bin=${DATE_BIN:-date}
sleep_bin=${SLEEP_BIN:-sleep}
runner_units_text=${RUNNER_UNITS:-}
service_units_text=${SERVICE_UNITS:-}
reset_unit=${RESET_UNIT:-}
docker_api_unit=${DOCKER_API_UNIT:-}
docker_socket=${DOCKER_SOCKET:-/run/forgejo-docker/docker.sock}
podman_api_unit=${PODMAN_API_UNIT:-}
podman_socket=${PODMAN_SOCKET:-/run/forgejo-podman/podman.sock}
wait_seconds=${WAIT_SECONDS:-3600}
quiet_seconds=${QUIET_SECONDS:-300}
poll_seconds=${POLL_SECONDS:-10}
restart_timeout_seconds=${RESTART_TIMEOUT_SECONDS:-4200}

terminal=0
fail() {
  echo "$1" >&2
  exit 1
}

now() { "$date_bin" +%s; }

# A run that ends without a result (an invalid setting, a failed read) says
# so, rather than leaving an earlier run's result or waiting behind. The trap
# is set before the settings are checked.
on_exit() {
  local status=$?
  if ((terminal == 0)); then
    terminal=1
    write_state failed "ended with status $status before a result" || true
  fi
}

flagged=()
write_state() {
  local status=$1 reason=${2:-} tmp unit
  install -d -m 0755 -- "${state_file%/*}"
  tmp=$(mktemp "${state_file%/*}/.restart.XXXXXX")
  {
    printf 'status=%s\ntime=%s\n' "$status" "$(now)"
    for unit in "${flagged[@]}"; do
      printf 'unit=%s\n' "$unit"
    done
    printf 'reason=%s\n' "${reason//$'\n'/ }"
  } >"$tmp"
  chmod 0644 -- "$tmp"
  mv -f -- "$tmp" "$state_file"
  printf 'event=%s units=%s reason=%s\n' "$status" "${flagged[*]:-none}" "${reason:-none}"
  case $status in
    done | nothing | busy | failed) terminal=1 ;;
  esac
}
trap on_exit EXIT

for value in "$wait_seconds" "$quiet_seconds" "$poll_seconds" "$restart_timeout_seconds"; do
  [[ $value =~ ^[0-9]+$ ]] || fail "invalid numeric setting"
done
read -r -a runner_units <<<"$runner_units_text"
read -r -a service_units <<<"$service_units_text"
((${#runner_units[@]} > 0)) || fail "runner unit list is empty"
for unit in "${runner_units[@]}" "${service_units[@]}"; do
  valid_unit "$unit" || fail "invalid unit name"
done
for unit in "$reset_unit" "$docker_api_unit" "$podman_api_unit"; do
  [[ -z $unit ]] || valid_unit "$unit" || fail "invalid unit name"
done

# Sets flagged to the tracked units that need a restart.
find_flagged() {
  local unit
  flagged=()
  for unit in "${runner_units[@]}" "${service_units[@]}"; do
    unit_state "$unit" || fail "cannot read unit $unit"
    if restart_needed "$unit"; then
      flagged+=("$unit")
    fi
  done
}

# Succeeds when the engine of an API that runs has a job container, or cannot
# be read; sets busy_reason.
engine_busy() {
  local api=$1 socket=$2 state containers status=0
  [[ -n $api ]] || return 1
  state=$(query show --property=ActiveState --value "$api") || {
    busy_reason="engine_unreadable unit=$api"
    return 0
  }
  # An engine that does not run runs no job, and querying a socket-activated
  # API would start it.
  [[ $state == active ]] || return 1
  containers=$("$curl_bin" --silent --show-error --fail --max-time 10 --connect-timeout 2 \
    --unix-socket "$socket" http://localhost/containers/json) || {
    busy_reason="engine_api_unavailable unit=$api"
    return 0
  }
  "$jq_bin" -e 'if type != "array" then error("not a container list") else
    any(.[]; (.Names // []) | any(.[]; type == "string" and
      (ltrimstr("/") | startswith("FORGEJO-ACTIONS-TASK-")))) end' <<<"$containers" >/dev/null 2>&1 ||
    status=$?
  case $status in
    0) busy_reason="job_running unit=$api" ;;
    1) return 1 ;;
    *) busy_reason="engine_api_invalid unit=$api" ;;
  esac
  return 0
}

# Succeeds when the runner took a task within the quiet interval, or its
# journal is unreadable. forgejo-runner logs every task it takes as
# `task <id> repo is ...`.
recent_job() {
  local since lines
  since=$(($(now) - quiet_seconds))
  lines=$("$journalctl_bin" --unit="$1" --since="@$since" --output=cat --no-pager --quiet 2>/dev/null) || return 0
  grep -Eq 'msg="task [0-9]+ repo is ' <<<"$lines"
}

# Succeeds while the host is busy; sets busy_reason.
host_busy() {
  local unit state
  busy_reason=""
  if [[ -n $reset_unit ]]; then
    state=$(query show --property=ActiveState --value "$reset_unit") || state=unknown
    case $state in
      activating | deactivating | unknown)
        busy_reason="store_reset_running"
        return 0
        ;;
    esac
  fi
  for unit in "${runner_units[@]}"; do
    unit_state "$unit" || {
      busy_reason="runner_unreadable unit=$unit"
      return 0
    }
    # A runner waiting to restart after a failure (auto-restart) runs no
    # job, and its next start takes the deployed definition anyway.
    case $active:$sub in
      activating:auto-restart) ;;
      activating:* | deactivating:*)
        busy_reason="runner_transition unit=$unit state=$active:$sub"
        return 0
        ;;
    esac
  done
  if engine_busy "$docker_api_unit" "$docker_socket" || engine_busy "$podman_api_unit" "$podman_socket"; then
    return 0
  fi
  for unit in "${runner_units[@]}"; do
    unit_state "$unit" || continue
    [[ $active == active ]] || continue
    if recent_job "$unit"; then
      busy_reason="recent_job unit=$unit"
      return 0
    fi
  done
  return 1
}

deadline=$(($(now) + wait_seconds))
last_reason=""
while :; do
  find_flagged
  if ((${#flagged[@]} == 0)); then
    write_state nothing
    exit 0
  fi
  host_busy || break
  if (($(now) >= deadline)); then
    write_state busy "$busy_reason"
    exit 0
  fi
  if [[ $busy_reason != "$last_reason" ]]; then
    write_state waiting "$busy_reason"
    last_reason=$busy_reason
  fi
  "$sleep_bin" "$poll_seconds"
done

write_state restarting
status=0
timeout -k 5s "${restart_timeout_seconds}s" "$systemctl_bin" restart "${flagged[@]}" || status=$?
restarted=("${flagged[@]}")
if ((status != 0)); then
  write_state failed "systemctl restart exited with status $status"
  exit 1
fi
# A restarted unit that runs must have recorded its new start. One whose
# start gate refused the start (a hold began) does not run, and the runner
# hold starts it later with the deployed definition.
find_flagged
if ((${#flagged[@]} > 0)); then
  write_state failed "still not running the deployed definition after the restart"
  exit 1
fi
flagged=("${restarted[@]}")
write_state "done"
