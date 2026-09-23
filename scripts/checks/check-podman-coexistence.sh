#!/usr/bin/env bash
# Opt-in Linux host canary. Uses disposable resources, never the Docker socket.
# Container shell expressions must expand inside the container.
# shellcheck disable=SC2016
set -euo pipefail

if [[ $(uname -s) != Linux || $EUID == 0 ]]; then
  echo 'Run as an ordinary user on a Linux host with rootless Podman.' >&2
  exit 2
fi
for tool in podman docker curl timeout; do command -v "$tool" >/dev/null; done
docker compose version >/dev/null
p() { timeout --foreground 120s podman --remote=false "$@"; }
[[ $(p info --format '{{.Host.Security.Rootless}}') == true ]]
gid=$(id -g)

work=$(mktemp -d /tmp/podman-canary.XXXXXXXX)
name="podman-canary-${work##*.}"
name=${name,,}
image="localhost/$name:canary"
socket="$work/api.sock"
state_volume="${name}-state"
base=docker.io/library/busybox@sha256:66a6306db78bf2dbf3487f293aa8d6990d8e506fdffab9cc43fe422becf886e4
api_pid=''
compose_started=false
compose_file="$work/compose.yaml"
# Refuse stale resource collisions before installing the resource-removal trap.
require_absent() {
  local result
  if p "$@" >/dev/null; then
    echo "Refusing existing resource: $*" >&2
    rm -rf -- "$work"
    exit 1
  else
    result=$?
    if ((result != 1)); then
      echo "Cannot establish resource absence: $*" >&2
      rm -rf -- "$work"
      exit "$result"
    fi
  fi
}
require_absent image exists "$image"
require_absent volume exists "$name"
require_absent volume exists "$state_volume"
require_absent network exists "$name"
require_absent network exists "${name}_default"
for container in "$name-server" "$name-storage" "$name-peer" "$name-limits" "$name-bind" "$name-web-1" "$name-backend-1"; do
  require_absent container exists "$container"
done
if ! project_containers=$(p ps --all --filter "label=com.docker.compose.project=$name" --format '{{.ID}}') || [[ -n $project_containers ]]; then
  echo 'Cannot establish that the Compose project is unused.' >&2
  rm -rf -- "$work"
  exit 1
fi
mkdir -p "$work/docker" "$work/bind"
printf '{}\n' >"$work/auth.json"
export REGISTRY_AUTH_FILE="$work/auth.json"

compose() {
  timeout --foreground 90s env -u DOCKER_CONTEXT -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    DOCKER_HOST="unix://$socket" DOCKER_CONFIG="$work/docker" \
    docker compose --project-name "$name" --file "$compose_file" "$@"
}
cleanup() {
  local status=$? cleanup_failed=false
  trap - EXIT
  set +e
  if $compose_started; then compose down --timeout 5 --volumes --remove-orphans || cleanup_failed=true; fi
  for container in "$name-server" "$name-storage" "$name-peer" "$name-limits" "$name-bind"; do
    p rm --force --time 5 --ignore "$container" >/dev/null || cleanup_failed=true
  done
  if [[ -n $api_pid ]]; then
    kill "$api_pid" 2>/dev/null
    if ! timeout 5s tail --pid="$api_pid" -f /dev/null; then
      kill -KILL "$api_pid" 2>/dev/null
    fi
    wait "$api_pid" 2>/dev/null
  fi
  if p network exists "$name"; then p network rm "$name" >/dev/null || cleanup_failed=true; fi
  if p volume exists "$name"; then p volume rm "$name" >/dev/null || cleanup_failed=true; fi
  if p volume exists "$state_volume"; then p volume rm "$state_volume" >/dev/null || cleanup_failed=true; fi
  if p image exists "$image"; then p image rm "$image" >/dev/null || cleanup_failed=true; fi
  if $cleanup_failed; then
    echo "Cleanup incomplete: inspect resources with prefix $name; fixture retained at $work" >&2
    exit 1
  fi
  rm -rf -- "$work"
  echo 'PASS: disposable resources cleaned up (shared base image retained)'
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

p pull "$base"
printf 'Base image: %s\n' "$base"
printf 'FROM %s\nRUN echo built > /built\nCOPY index.html /www/index.html\nCMD ["httpd", "-f", "-p", "8080", "-h", "/www"]\n' "$base" >"$work/Dockerfile"
printf 'podman-canary\n' >"$work/index.html"
p build --network none --no-cache --layers=false --tag "$image" "$work"
echo 'PASS: image build'

printf 'host-input\n' >"$work/bind/input"
p run --rm --name "$name-bind" --userns keep-id --volume "$work/bind:/data" "$image" \
  sh -ec 'test "$(cat /data/input)" = host-input; echo container-output > /data/output'
[[ $(cat "$work/bind/output") == container-output ]]
[[ $(stat -c %u "$work/bind/output") == "$EUID" ]]
echo 'PASS: bind mount and user ownership'

p volume create "$name" >/dev/null
p run --name "$name-storage" --volume "$name:/data" "$image" \
  sh -ec 'if test -f /data/marker; then test "$(cat /data/marker)" = persistent; else echo persistent > /data/marker; fi'
p start --attach "$name-storage"
[[ $(p inspect "$name-storage" --format '{{.State.ExitCode}}') == 0 ]]
p rm "$name-storage" >/dev/null
p run --rm --name "$name-storage" --volume "$name:/data" "$image" \
  sh -ec 'test "$(cat /data/marker)" = persistent'
echo 'PASS: volume survives restart and container replacement'

p run --rm --name "$name-limits" --memory 64m --cpus 0.5 "$image" \
  sh -ec 'test "$(cat /sys/fs/cgroup/memory.max)" = 67108864; read -r quota period < /sys/fs/cgroup/cpu.max; test "$quota" -eq "$((period / 2))"'
echo 'PASS: container CPU and memory cgroup settings (not a stress test)'

p network create "$name" >/dev/null
p run --detach --init --name "$name-server" --network "$name" --network-alias canary \
  --publish 127.0.0.1::8080 --memory 64m --cpus 0.5 "$image" >/dev/null
address=$(p port "$name-server" 8080/tcp)
[[ $(curl --noproxy '*' --fail --silent --show-error --retry 10 --retry-connrefused --retry-delay 1 --max-time 5 "http://$address") == podman-canary ]]
[[ $(p run --rm --name "$name-peer" --network "$name" "$image" wget -qO- http://canary:8080) == podman-canary ]]
p stop --time 5 "$name-server" >/dev/null
p start "$name-server" >/dev/null
address=$(p port "$name-server" 8080/tcp)
[[ $(curl --noproxy '*' --fail --silent --show-error --retry 10 --retry-connrefused --retry-delay 1 --max-time 5 "http://$address") == podman-canary ]]
echo 'PASS: network DNS, loopback publication and service restart'

podman --remote=false system service --time 0 "unix://$socket" >"$work/api.log" 2>&1 &
api_pid=$!
ready=false
for ((attempt = 0; attempt < 50; attempt++)); do
  if curl --noproxy '*' --fail --silent --max-time 1 --unix-socket "$socket" http://localhost/_ping >/dev/null; then
    ready=true
    break
  fi
  sleep 0.1
done
$ready
echo 'PASS: isolated compatibility API'

cat >"$work/compose.yaml" <<EOF
services:
  web:
    image: $image
    init: true
    pull_policy: never
    ports:
      - "127.0.0.1::8080"
    mem_limit: 64m
    cpus: 0.5
EOF
compose_started=true
compose up --detach --wait --wait-timeout 30
address=$(compose port web 8080)
[[ $(curl --noproxy '*' --fail --silent --show-error --retry 10 --retry-connrefused --retry-delay 1 --max-time 5 "http://$address") == podman-canary ]]
compose stop --timeout 5
compose start
address=$(compose port web 8080)
[[ $(curl --noproxy '*' --fail --silent --show-error --retry 10 --retry-connrefused --retry-delay 1 --max-time 5 "http://$address") == podman-canary ]]
compose down --timeout 5

# Qualify a small, synthetic dev-style stack. This remains a representative
# fixture and does not establish compatibility with every project Compose file.
compose_file="$work/dev-stack.yaml"
mkdir -p "$work/stack-bind"
printf 'synthetic-bind-input\n' >"$work/stack-bind/input"
cat >"$compose_file" <<EOF
services:
  backend:
    image: $image
    init: true
    pull_policy: never
    mem_limit: 64m
    cpus: 0.5
    command:
      - sh
      - -ec
      - |
        mkdir -p /state /www
        if test -f /state/counter; then
          count=\$\$(cat /state/counter)
          count=\$\$((count + 1))
        else
          count=1
        fi
        printf '%s\\n' "\$\$count" > /state/counter
        printf 'canary-counter-%s\\n' "\$\$count" > /www/health
        exec httpd -f -p 8081 -h /www
    healthcheck:
      test: ["CMD-SHELL", "test -s /state/counter && wget -qO- http://127.0.0.1:8081/health | grep -q canary-counter"]
      interval: 1s
      timeout: 2s
      retries: 10
      start_period: 1s
    volumes:
      - state:/state
  web:
    image: $image
    init: true
    pull_policy: never
    mem_limit: 64m
    cpus: 0.5
    depends_on:
      backend:
        condition: service_healthy
    command:
      - sh
      - -ec
      - |
        response=\$\$(wget -qO- http://backend:8081/health)
        printf 'dev-stack-ok:%s\\n' "\$\$response" > /www/index.html
        exec httpd -f -p 8080 -h /www
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8080/ | grep -q dev-stack-ok:canary-counter"]
      interval: 1s
      timeout: 2s
      retries: 10
      start_period: 1s
    volumes:
      - state:/state:ro
    ports:
      - "127.0.0.1::8080"
  bind-check:
    image: $image
    pull_policy: never
    profiles: [canary]
    user: "$EUID:$gid"
    userns_mode: keep-id
    command:
      - sh
      - -ec
      - |
        test "\$\$(cat /data/input)" = synthetic-bind-input
        printf 'compose-bind-output\\n' > /data/output
    volumes:
      - $work/stack-bind:/data
volumes:
  state:
    name: $state_volume
EOF
compose up --detach --wait --wait-timeout 30
address=$(compose port web 8080)
[[ $(curl --noproxy '*' --fail --silent --show-error --retry 10 --retry-connrefused --retry-delay 1 --max-time 5 "http://$address") == dev-stack-ok:canary-counter-1 ]]
compose run --rm --no-deps bind-check
[[ $(cat "$work/stack-bind/output") == compose-bind-output ]]
[[ $(stat -c %u "$work/stack-bind/output") == "$EUID" ]]
echo 'PASS: Compose bind mount read/write and explicit user ownership'
compose down --timeout 5
p volume exists "$state_volume"
compose up --detach --wait --wait-timeout 30
address=$(compose port web 8080)
[[ $(curl --noproxy '*' --fail --silent --show-error --retry 10 --retry-connrefused --retry-delay 1 --max-time 5 "http://$address") == dev-stack-ok:canary-counter-2 ]]
echo 'PASS: synthetic Compose stack DNS, health-gated startup, and named-volume persistence across down/up'
