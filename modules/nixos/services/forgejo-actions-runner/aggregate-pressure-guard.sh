#!/usr/bin/env bash
set -euo pipefail

state_dir=${STATE_DIR:-/run/forgejo-runner-aggregate-pressure}
pressure_file=${PRESSURE_FILE:-/proc/pressure/io}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
notify_bin=${SYSTEMD_NOTIFY_BIN:-systemd-notify}
logger_bin=${LOGGER_BIN:-logger}
sample_seconds=${SAMPLE_SECONDS:-5}
high_threshold=${HIGH_THRESHOLD_HUNDREDTHS:-2000}
low_threshold=${LOW_THRESHOLD_HUNDREDTHS:-500}
high_required=${HIGH_SAMPLES_REQUIRED:-5}
low_required=${LOW_SAMPLES_REQUIRED:-13}
max_iterations=${MAX_ITERATIONS:-0}
transition_timeout_seconds=${TRANSITION_TIMEOUT_SECONDS:-120}
unit=forgejobuilds.slice

fail() {
  "$logger_bin" -t forgejo-runner-aggregate-pressure -- "$1"
  "$notify_bin" --status="degraded: $1" || true
  exit 1
}
metadata() { timeout --foreground 5s "$systemctl_bin" "$@"; }
transition() {
  local action=$1
  local actual deadline metadata_timeout remaining
  shift
  deadline=$((SECONDS + transition_timeout_seconds))

  while ((remaining = deadline - SECONDS, remaining > 0)); do
    if SYSTEMD_BUS_TIMEOUT="${remaining}s" timeout --foreground "${remaining}s" "$systemctl_bin" "$action" "$@"; then
      return 0
    fi
    [[ $action == freeze ]] || return 1

    remaining=$((deadline - SECONDS))
    ((remaining > 0)) || return 1
    metadata_timeout=5
    ((remaining < metadata_timeout)) && metadata_timeout=$remaining
    actual=$(timeout --foreground "${metadata_timeout}s" "$systemctl_bin" \
      show --property=FreezerState --value "$unit") || return 1
    [[ $actual == running ]] || return 1

    remaining=$((deadline - SECONDS))
    ((remaining > 1)) || return 1
    sleep 1
  done
  return 1
}
freezer_state() { metadata show --property=FreezerState --value "$unit"; }

mkdir -p "$state_dir"
chmod 0700 "$state_dir"
[[ ! -e $state_dir/pending ]] || fail "ambiguous freeze operation requires operator recovery"

read_pressure() {
  if [[ -n ${PRESSURE_VALUES_FILE:-} ]]; then
    IFS= read -r pressure <&8 || return 1
    [[ $pressure =~ ^[0-9]+$ ]] || return 1
  else
    pressure=$(awk '
      $1 == "full" {
        for (i = 2; i <= NF; i++) {
          if ($i ~ /^avg10=[0-9]+([.][0-9]+)?$/) {
            split($i, part, "="); printf "%.0f\n", part[2] * 100; found = 1
          }
        }
      }
      END { if (!found) exit 1 }
    ' "$pressure_file") || return 1
  fi
}

freeze_owned() {
  local actual
  actual=$(freezer_state) || fail "cannot inspect build aggregate"
  if [[ -e $state_dir/owned ]]; then
    [[ $actual == frozen ]] || fail "owned aggregate was thawed externally"
    return
  fi
  [[ $actual == running ]] || fail "aggregate freeze is not owned by this guard"
  : > "$state_dir/pending"
  transition freeze "$unit" || fail "aggregate freeze failed; ownership requires recovery"
  [[ $(freezer_state) == frozen ]] || fail "aggregate did not freeze; ownership requires recovery"
  : > "$state_dir/owned"
  rm "$state_dir/pending"
}

thaw_owned() {
  [[ -e $state_dir/owned ]] || fail "aggregate thaw lacks ownership"
  [[ $(freezer_state) == frozen ]] || fail "owned aggregate state changed externally"
  : > "$state_dir/pending"
  transition thaw "$unit" || fail "aggregate thaw failed; ownership requires recovery"
  [[ $(freezer_state) == running ]] || fail "aggregate did not thaw; ownership requires recovery"
  rm "$state_dir/owned" "$state_dir/pending"
}

actual=$(freezer_state) || fail "cannot inspect build aggregate at startup"
if [[ -e $state_dir/owned ]]; then
  [[ $actual == frozen ]] || fail "prior freeze ownership no longer matches aggregate"
elif [[ $actual != running ]]; then
  fail "pre-existing aggregate freeze requires operator recovery"
fi
if [[ -n ${PRESSURE_VALUES_FILE:-} ]]; then exec 8<"$PRESSURE_VALUES_FILE"; fi
read_pressure || fail "I/O pressure is unreadable at startup"
"$notify_bin" --ready --status="monitoring dedicated CI aggregate" || true
high=0
low=0
iteration=0
while ((max_iterations == 0 || iteration < max_iterations)); do
  iteration=$((iteration + 1))
  if ((pressure >= high_threshold)); then
    high=$((high + 1)); low=0
  elif ((pressure <= low_threshold)); then
    low=$((low + 1)); high=0
  else
    low=0; high=0
  fi
  if [[ -e $state_dir/owned ]]; then
    freeze_owned
    if ((low >= low_required)); then
      thaw_owned
      low=0
    fi
  elif ((high >= high_required)); then
    freeze_owned
    high=0
  fi
  if ((max_iterations != 0 && iteration >= max_iterations)); then break; fi
  sleep "$sample_seconds"
  if ! read_pressure; then
    freeze_owned
    fail "I/O pressure became unreadable; leaving owned aggregate frozen"
  fi
done
