#!/usr/bin/env bash
set -euo pipefail

# Reports runner units that have not admitted CI jobs for longer than a bound,
# whatever held them (ADR-0072, #894). Read-only towards the runners and the
# pressure guard: it only queries systemd and reads the guard's markers, and
# writes nothing but its own state directory. Intended holds are excluded: a
# detected game, a standby runner its controller has not admitted, and a
# runner the Podman store reset stopped and will start again (ADR-0105).

state_dir=${STATE_DIR:-/run/forgejo-runner-aggregate-pressure}
monitor_dir=${MONITOR_STATE_DIR:-/run/forgejo-runner-hold-monitor}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
curl_bin=${CURL_BIN:-curl}
uptime_file=${UPTIME_FILE:-/proc/uptime}
guard_unit=${GUARD_UNIT:-forgejo-runner-io-pressure-guard.service}
primary_runner=forgejo-actions-runner.service
runner_units_text=${RUNNER_UNITS:-$primary_runner}
standby_units_text=${STANDBY_UNITS:-}
max_hold_seconds=${MAX_HOLD_SECONDS:-1800}
game_admission=${GAME_ADMISSION_ENABLED:-0}
game_hold_seconds=${GAME_HOLD_SECONDS:-90}
reset_unit=${RESET_UNIT:-forgejo-podman-store-reset.service}
reset_restart_file=${RESET_RESTART_FILE:-/run/forgejo-podman-store-reset/restart}
ping_base_file=${PING_BASE_FILE:?}
slug=${SLUG:?}

runner_markers=(drain-owned drain-pending drain-disowned resume-pending resume-queued
  resume-blocked-reported disk-start-skipped game-start-skipped reset-start-skipped standby-held)
aggregate_markers=(owned pending teardown-required)

for value in "$max_hold_seconds" "$game_hold_seconds"; do
  [[ $value =~ ^[1-9][0-9]*$ ]] || { echo "invalid numeric setting" >&2; exit 1; }
done
[[ $game_admission == 0 || $game_admission == 1 ]] || { echo "invalid game setting" >&2; exit 1; }
[[ $slug =~ ^[a-z0-9-]+$ ]] || { echo "invalid slug" >&2; exit 1; }
read -r -a runner_units <<< "$runner_units_text"
read -r -a standby_units <<< "$standby_units_text"
((${#runner_units[@]} > 0)) || { echo "runner unit list is empty" >&2; exit 1; }
for unit in "${runner_units[@]}" "${standby_units[@]}" "$guard_unit" "$reset_unit"; do
  [[ $unit =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || { echo "invalid unit name" >&2; exit 1; }
done

install -d -m 0700 "$monitor_dir" "$monitor_dir/held"
report=$monitor_dir/report
: > "$report"
issues=0

record_issue() {
  printf '%s\n' "$1" >> "$report"
  issues=$((issues + 1))
}

send_ping() {
  local suffix=$1 base url
  base="$(tr -d '\r\n' < "$ping_base_file")"
  if [[ -z $base ]]; then
    echo "healthcheck ping base is empty" >&2
    return 1
  fi
  url="$base/$slug$suffix?create=1"
  {
    printf 'url = "%s"\n' "$url"
    printf 'data-binary = "@%s"\n' "$report"
  } | "$curl_bin" --config - --silent --show-error --fail --max-time 10 > /dev/null
}

IFS=' ' read -r uptime _ < "$uptime_file" || { echo "cannot read uptime" >&2; exit 1; }
[[ $uptime =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "invalid uptime" >&2; exit 1; }
now=${uptime%%.*}

# The guard records the uptime of every sample that sees a game; a recent
# record is a game hold. A bypass or an ended game lets the record age out.
game_held=0
if [[ $game_admission == 1 && -f $state_dir/game-last-seen && ! -L $state_dir/game-last-seen ]]; then
  if IFS= read -r last_seen < "$state_dir/game-last-seen" && [[ $last_seen =~ ^[0-9]+$ ]] &&
    ((last_seen <= now && now - last_seen <= game_hold_seconds)); then
    game_held=1
  fi
fi

guard_state=$(timeout 10s "$systemctl_bin" show --property=ActiveState --value "$guard_unit" 2> /dev/null) ||
  guard_state=unknown

# The reset lists the runners it stopped until it has started them again. A
# list is trusted only while the reset is still running.
reset_held=()
if [[ -f $reset_restart_file && ! -L $reset_restart_file ]]; then
  reset_state=$(timeout 10s "$systemctl_bin" show --property=ActiveState --value "$reset_unit" 2> /dev/null) ||
    reset_state=unknown
  if [[ $reset_state == activating || $reset_state == deactivating ]]; then
    # The reset may remove its list between the check and the read.
    mapfile -t reset_held < "$reset_restart_file" 2> /dev/null || reset_held=()
  fi
fi

aggregate_found=()
for marker in "${aggregate_markers[@]}"; do
  [[ ! -e $state_dir/$marker && ! -L $state_dir/$marker ]] || aggregate_found+=("$marker")
done

contains() {
  local item=$1 candidate
  shift
  for candidate in "$@"; do
    [[ $candidate != "$item" ]] || return 0
  done
  return 1
}

minutes() { printf '%dm' $((($1 + 59) / 60)); }

check_runner() {
  local unit=$1 runner_state held_file since duration properties key value markers marker
  local load_state=unknown unit_file_state=unknown active_state=unknown sub_state=unknown result=unknown
  held_file=$monitor_dir/held/$unit
  if [[ $unit == "$primary_runner" ]]; then
    runner_state=$state_dir
  else
    runner_state=$state_dir/runners/$unit
  fi

  if ! properties=$(timeout 10s "$systemctl_bin" show --property=LoadState --property=UnitFileState \
    --property=ActiveState --property=SubState --property=Result "$unit"); then
    record_issue "$unit: systemd state is unreadable"
    return
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      LoadState) load_state=$value ;;
      UnitFileState) unit_file_state=$value ;;
      ActiveState) active_state=$value ;;
      SubState) sub_state=$value ;;
      Result) result=$value ;;
    esac
  done <<< "$properties"

  if [[ $active_state == active || $active_state == reloading ]]; then
    rm -f "$held_file"
    printf '%s: admitting\n' "$unit" >> "$report"
    return
  fi
  # Automation never masks or disables a runner, so only a loaded, enabled
  # unit can be on an intended hold.
  if [[ $load_state == loaded && ($unit_file_state == enabled || $unit_file_state == enabled-runtime) ]]; then
    if ((game_held == 1)); then
      rm -f "$held_file"
      printf '%s: held for a detected game\n' "$unit" >> "$report"
      return
    fi
    if contains "$unit" "${standby_units[@]}" && [[ ! -e $runner_state/standby-admitted ]]; then
      rm -f "$held_file"
      printf '%s: standby, not admitted\n' "$unit" >> "$report"
      return
    fi
    if contains "$unit" "${reset_held[@]}"; then
      rm -f "$held_file"
      printf '%s: stopped for a Podman store reset\n' "$unit" >> "$report"
      return
    fi
  fi

  if [[ -f $held_file ]] && IFS= read -r since < "$held_file" && [[ $since =~ ^[0-9]+$ ]] && ((since <= now)); then
    :
  else
    since=$now
    printf '%s\n' "$since" > "$held_file"
  fi
  duration=$((now - since))

  markers=("${aggregate_found[@]}")
  for marker in "${runner_markers[@]}"; do
    [[ ! -e $runner_state/$marker ]] || markers+=("$marker")
  done
  local IFS=,
  local cause="active_state=$active_state sub_state=$sub_state result=$result load_state=$load_state unit_file_state=$unit_file_state markers=${markers[*]:-none} guard=$guard_state"
  if ((duration >= max_hold_seconds)); then
    record_issue "$unit: held for $(minutes "$duration") (bound $(minutes "$max_hold_seconds")): $cause"
  else
    printf '%s: held for %s, under bound: %s\n' "$unit" "$(minutes "$duration")" "$cause" >> "$report"
  fi
}

send_ping /start || true
for unit in "${runner_units[@]}"; do
  check_runner "$unit"
done
# Forget units that are no longer configured.
for path in "$monitor_dir"/held/*; do
  [[ -e $path ]] || continue
  contains "${path##*/}" "${runner_units[@]}" || rm -f "$path"
done

if ((issues > 0)); then
  send_ping /fail || true
  cat "$report" >&2
  exit 1
fi
send_ping ""
cat "$report"
