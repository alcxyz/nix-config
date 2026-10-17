#!/usr/bin/env bash
set -euo pipefail

# Runs a standby runner only while the primary host's matching runner is down
# (ADR-0097). The primary host publishes that runner's systemd state; any
# answer other than "active", including no answer, counts as down. The start
# gate refuses the standby unit unless standby-admitted exists, so a guard
# resume after a drain cannot start it behind this controller's back.
# Stopping the controller releases the runner.

state_dir=${STATE_DIR:-/run/forgejo-runner-aggregate-pressure}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
curl_bin=${CURL_BIN:-curl}
runner_unit=${RUNNER_UNIT:?}
status_url=${STATUS_URL:?}
# Bind polls to the authenticated overlay, so a missing route cannot send
# them elsewhere.
status_interface=${STATUS_INTERFACE:-}
poll_seconds=${POLL_SECONDS:-15}
start_after_polls=${START_AFTER_POLLS:-4}
stop_after_polls=${STOP_AFTER_POLLS:-20}
start_retry_polls=${START_RETRY_POLLS:-4}
lock_seconds=${LOCK_SECONDS:-30}
max_iterations=${MAX_ITERATIONS:-0}
# The runner needs these; a start is pointless while one is down. Starts use
# the ignore-requirements job mode, so one that races with a dependency stop
# fails instead of restarting the dependency against its no-restart policy.
dependency_units_text=${DEPENDENCY_UNITS:-forgejo-runner-io-pressure-guard.service forgejo-runner-aggregate-lifecycle.service forgejo-runner-podman.service}

for value in "$poll_seconds" "$start_after_polls" "$stop_after_polls" "$start_retry_polls" "$lock_seconds" "$max_iterations"; do
  [[ $value =~ ^[0-9]+$ ]] || { echo "invalid numeric setting" >&2; exit 1; }
done
((start_after_polls > 0 && stop_after_polls > 0 && start_retry_polls > 0 && lock_seconds > 0)) ||
  { echo "invalid numeric setting" >&2; exit 1; }
[[ $runner_unit =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || { echo "invalid runner unit" >&2; exit 1; }
curl_options=(--silent --fail --max-time 5 --noproxy '*')
if [[ -n $status_interface ]]; then
  [[ $status_interface =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "invalid status interface" >&2; exit 1; }
  # "if!" names an interface only; curl fails rather than fall back to
  # resolving the name as a host or address.
  curl_options+=(--interface "if!$status_interface")
fi
runner_state=$state_dir/runners/$runner_unit
read -r -a dependency_units <<< "$dependency_units_text"
for unit in "${dependency_units[@]}"; do
  [[ $unit =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || { echo "invalid dependency unit" >&2; exit 1; }
done

report() {
  printf 'event=%s runner_unit=%s %s\n' "$1" "$runner_unit" "${2:-}" || true
}

primary_active() {
  local answer
  answer=$("$curl_bin" "${curl_options[@]}" "$status_url" 2>/dev/null) || return 1
  [[ $answer == active ]]
}

# The guard creates the runner's state directory and lock file at startup.
runner_state_ready() {
  [[ -d $state_dir && ! -L $state_dir && -d $runner_state && ! -L $runner_state ]]
}

lock_lifecycle() {
  exec 9>"$state_dir/lifecycle.lock"
  if ! flock -w "$lock_seconds" -x 9; then
    exec 9>&-
    return 1
  fi
}

unlock_lifecycle() {
  flock -u 9
  exec 9>&-
}

unit_property() {
  timeout --foreground 5s "$systemctl_bin" show --property="$1" --value "$runner_unit"
}

admit() {
  lock_lifecycle || { report standby_lock_timeout "action=admit"; return 1; }
  if ! runner_state_ready; then
    unlock_lifecycle
    return 1
  fi
  : > "$runner_state/standby-admitted"
  unlock_lifecycle
  report standby_admitted
}

# Withdraw admission and stop the runner under the lifecycle lock, so no guard
# resume or start gate sees a half-finished release. A graceful stop lets
# admitted jobs finish here. The hold marker tells the boot check that the
# stopped runner is held on purpose.
release() {
  local active
  lock_lifecycle || { report standby_lock_timeout "action=release"; return 1; }
  rm -f "$runner_state/standby-admitted"
  : > "$runner_state/standby-held"
  if ! active=$(unit_property ActiveState); then
    unlock_lifecycle
    report standby_release_unconfirmed "reason=unit_unreadable"
    return 1
  fi
  case "$active" in
    active | activating | reloading)
      if ! timeout --foreground 5s "$systemctl_bin" --no-block stop "$runner_unit"; then
        unlock_lifecycle
        report standby_release_unconfirmed "reason=stop_failed active_state=$active"
        return 1
      fi
      ;;
  esac
  unlock_lifecycle
  report standby_released "active_state=$active"
}

# Starts an admitted runner that is down for no reason the guard owns. Drain,
# game and disk holds are resumed by the guard, a drain of any other runner
# holds it too, and a failed unit or dependency is left for the operator, as
# is a disabled or masked unit. To keep an enabled standby stopped, stop this
# controller first.
ensure_started() {
  local active result marker directory unit load_state unit_file_state
  load_state=$(unit_property LoadState) || return 0
  unit_file_state=$(unit_property UnitFileState) || return 0
  [[ $load_state == loaded && ($unit_file_state == enabled || $unit_file_state == enabled-runtime) ]] || return 0
  active=$(unit_property ActiveState) || return 0
  [[ $active == inactive || $active == failed ]] || { blocked_reported=0; return 0; }
  result=$(unit_property Result) || return 0
  if [[ $active == failed || ($result != success && $result != exec-condition) ]]; then
    if ((blocked_reported == 0)); then
      report standby_start_blocked "active_state=$active result=$result"
      blocked_reported=1
    fi
    return 0
  fi
  for marker in drain-owned drain-pending resume-pending drain-disowned game-start-skipped disk-start-skipped; do
    [[ ! -e $runner_state/$marker ]] || return 0
  done
  for directory in "$state_dir" "$state_dir"/runners/*; do
    [[ ! -e $directory/drain-owned ]] || return 0
  done
  for unit in "${dependency_units[@]}"; do
    timeout --foreground 5s "$systemctl_bin" is-active --quiet "$unit" || return 0
  done
  ((last_start == 0 || iteration - last_start >= start_retry_polls)) || return 0
  last_start=$iteration
  if timeout --foreground 5s "$systemctl_bin" --no-block --job-mode=ignore-requirements start "$runner_unit"; then
    report standby_start_queued "result=$result"
  else
    report standby_start_failed "result=$result"
  fi
}

# Without a controller nothing would release the runner when the primary
# returns, so a stop withdraws admission and stops the runner gracefully.
sleep_pid=''
shutdown() {
  local active
  trap - TERM INT
  [[ -z $sleep_pid ]] || kill "$sleep_pid" 2>/dev/null || true
  runner_state_ready || exit 0
  # The start gate reads admission under the lock, so withdrawing it first
  # holds every later start even if the lock stays busy.
  rm -f "$runner_state/standby-admitted"
  : > "$runner_state/standby-held"
  release && exit 0
  # Stop without the lock rather than leave the runner serving with no
  # controller; the gate refuses any start this races with.
  active=$(unit_property ActiveState) || exit 1
  case "$active" in
    active | activating | reloading)
      timeout --foreground 5s "$systemctl_bin" --no-block stop "$runner_unit" || exit 1
      ;;
  esac
  report standby_released "active_state=$active lock=skipped"
  exit 0
}
trap shutdown TERM INT

up=0
down=0
observed=unknown
last_start=0
blocked_reported=0
iteration=0
while ((max_iterations == 0 || iteration < max_iterations)); do
  iteration=$((iteration + 1))
  if primary_active; then
    up=$((up + 1))
    down=0
    [[ $observed == up ]] || report primary_up
    observed=up
  else
    down=$((down + 1))
    up=0
    [[ $observed == down ]] || report primary_down
    observed=down
  fi

  if runner_state_ready; then
    if [[ -e $runner_state/standby-admitted ]]; then
      if ((up >= stop_after_polls)); then
        release || true
      else
        ensure_started
      fi
    elif ((down >= start_after_polls)); then
      if admit; then
        last_start=0
        ensure_started
      fi
    elif ((up >= stop_after_polls)); then
      # Finish a release whose stop request failed after admission was
      # withdrawn; the start gate refuses every other unadmitted start.
      case "$(unit_property ActiveState || true)" in
        active | activating | reloading) release || true ;;
      esac
    fi
  fi

  if ((max_iterations != 0 && iteration >= max_iterations)); then break; fi
  # Wait in the background so a stop signal is handled at once.
  sleep "$poll_seconds" &
  sleep_pid=$!
  wait "$sleep_pid" || true
  sleep_pid=''
done
