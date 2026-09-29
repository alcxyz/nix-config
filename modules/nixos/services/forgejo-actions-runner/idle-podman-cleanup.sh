#!/usr/bin/env bash
set -euo pipefail

state_dir=${STATE_DIR:-/run/forgejo-runner-aggregate-pressure}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
curl_bin=${CURL_BIN:-curl}
df_bin=${DF_BIN:-df}
jq_bin=${JQ_BIN:-jq}
docker_socket=${DOCKER_SOCKET:-/run/forgejo-docker/docker.sock}
podman_socket=${PODMAN_SOCKET:-/run/forgejo-podman/podman.sock}
disk_path=${DISK_PATH:-/}
trigger_used_percent=${TRIGGER_USED_PERCENT:-70}
critical_free_bytes=${CRITICAL_FREE_BYTES:-0}
critical_free_percent=${CRITICAL_FREE_PERCENT:-0}
runner_units=(forgejo-actions-runner.service forgejo-podman-runner.service)

[[ $trigger_used_percent =~ ^[1-9][0-9]?$ ]] || exit 1
[[ $critical_free_bytes =~ ^[0-9]+$ && $critical_free_percent =~ ^[0-9]+$ ]] || exit 1
[[ -d $state_dir && ! -L $state_dir ]] || exit 0
exec 9>"$state_dir/lifecycle.lock"
flock -w 5 -x 9 || exit 0

# The guard's registry and transition markers are the authority for this
# aggregate. A configuration switch or unfinished transition must not turn
# into a cleanup opportunity.
[[ -f $state_dir/runner-units && ! -L $state_dir/runner-units ]] || exit 0
[[ $(cat "$state_dir/runner-units") == "$(printf '%s\n' "${runner_units[@]}")" ]] || exit 0
[[ -d $state_dir/runners/${runner_units[1]} && ! -L $state_dir/runners/${runner_units[1]} ]] || exit 0
for path in "$state_dir"/runners/*; do
  [[ -e $path || -L $path ]] || continue
  [[ $path == "$state_dir/runners/${runner_units[1]}" && -d $path && ! -L $path ]] || exit 0
done
for marker in owned pending teardown-required drain-pending resume-pending drain-disowned; do
  [[ ! -e $state_dir/$marker && ! -L $state_dir/$marker ]] || exit 0
  [[ ! -e $state_dir/runners/${runner_units[1]}/$marker && ! -L $state_dir/runners/${runner_units[1]}/$marker ]] || exit 0
done

query_unit() {
  timeout -k 2s 5s "$systemctl_bin" "$@"
}
[[ $(query_unit show --property=FreezerState --value forgejobuilds.slice) == running ]] || exit 0
query_unit is-active --quiet forgejo-runner-io-pressure-guard.service || exit 0
query_unit is-active --quiet forgejo-runner-aggregate-lifecycle.service || exit 0
query_unit is-active --quiet forgejo-runner-docker.service || exit 0
query_unit is-active --quiet forgejo-runner-podman.service || exit 0

for unit in "${runner_units[@]}"; do
  metadata=$(query_unit show --property=ActiveState --property=SubState \
    --property=MainPID --property=ControlPID --property=Job "$unit") || exit 0
  for expected in ActiveState=inactive SubState=dead MainPID=0 ControlPID=0 Job=0; do
    printf '%s\n' "$metadata" | rg --quiet --fixed-strings --line-regexp "$expected" || exit 0
  done
done

[[ -S $docker_socket && -S $podman_socket ]] || exit 0
sample=$($df_bin --block-size=1 --output=size,avail "$disk_path" | awk 'NR == 2 { print $1, $2 }') || exit 0
read -r total available <<< "$sample"
[[ $total =~ ^[1-9][0-9]*$ && $available =~ ^[0-9]+$ ]] || exit 0
((available <= total)) || exit 0
((available >= critical_free_bytes && available * 100 >= total * critical_free_percent)) || exit 0
((available * 100 <= total * (100 - trigger_used_percent))) || exit 0

api() {
  local socket=$1 method=$2 path=$3
  "$curl_bin" --silent --show-error --fail --max-time 5 --connect-timeout 2 \
    --max-filesize 8388608 --unix-socket "$socket" -X "$method" \
    "http://localhost$path"
}
containers_terminal() {
  local socket=$1
  api "$socket" GET '/containers/json?all=1' |
    "$jq_bin" -e 'type == "array" and all(.[]; (.State | type == "string") and (.State == "exited" or .State == "dead"))' >/dev/null
}
safe_to_prune() {
  containers_terminal "$docker_socket" && containers_terminal "$podman_socket"
}

safe_to_prune || exit 0
# Podman's native API excludes running containers and images still referenced
# by containers. This service never
# touches volumes, pods, networks, or the local Podman storage CLI.
"$curl_bin" --silent --show-error --fail --max-time 10 --connect-timeout 2 \
  --max-filesize 8388608 --unix-socket "$podman_socket" -X POST -o /dev/null \
  'http://localhost/libpod/containers/prune'
safe_to_prune || exit 0
"$curl_bin" --silent --show-error --fail --max-time 10 --connect-timeout 2 \
  --max-filesize 8388608 --unix-socket "$podman_socket" -X POST -o /dev/null \
  'http://localhost/libpod/images/prune?filters=%7B%22until%22%3A%5B%22336h%22%5D%2C%22dangling%22%3A%5B%22false%22%5D%7D'
