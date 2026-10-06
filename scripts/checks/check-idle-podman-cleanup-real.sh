#!/usr/bin/env bash
# Optional Linux/rootless qualification; never uses the default Podman store.
# Usage: bash scripts/checks/check-idle-podman-cleanup-real.sh [cleanup-helper]
# Requires podman, curl, jq, python3, rg, flock, sha256sum and GNU timeout.
# Downloads a public Alpine rootfs over HTTPS; no registry pulls or credentials.
# Entire run is bounded to five minutes plus at most 45 seconds for teardown.
set -euo pipefail
if [[ ${1:-} != --bounded ]]; then
  exec timeout --signal=TERM --kill-after=45s 300s bash "$0" --bounded "$@"
fi
shift
repo=$(cd "$(dirname "$0")/../.." && pwd)
source_file=${1:-$repo/modules/nixos/services/forgejo-actions-runner/idle-podman-cleanup.sh}
[[ $(id -u) != 0 ]] || {
  echo 'Requires an unprivileged Linux user' >&2
  exit 1
}
for tool in podman curl jq python3 rg flock sha256sum timeout; do command -v "$tool" >/dev/null; done
podman_bin=$(command -v podman)
curl_bin=$(command -v curl)
fixture=$(mktemp -d /tmp/podman-cleanup-real.XXXXXXXX)
api_pid='' docker_pid='' cleanup_pid=''
pause_state=unstarted
# Explicit config/auth paths prevent default storage or connection reuse.
# Registry drop-ins can still be read: never pull, so no auth helpers are used.
# HOME is unset by env -i, never reassigned; XDG paths isolate user configuration.
mkdir -p "$fixture"/{config,data,cache,runtime,tmp,graph,run,hooks,state/runners/forgejo-podman-runner.service}
printf '{"auths":{}}\n' >"$fixture/auth.json"
cat >"$fixture/registries.conf" <<'CONF'
credential-helpers=["containers-auth.json"]
CONF
cat >"$fixture/storage.conf" <<CONF
[storage]
driver="vfs"
graphroot="$fixture/graph"
runroot="$fixture/run"
CONF
cat >"$fixture/containers.conf" <<'CONF'
[engine]
cgroup_manager="cgroupfs"
events_logger="file"
CONF
isolated=(env -i PATH="$PATH"
  XDG_CONFIG_HOME="$fixture/config" XDG_RUNTIME_DIR="$fixture/runtime"
  XDG_DATA_HOME="$fixture/data" XDG_CACHE_HOME="$fixture/cache"
  TMPDIR="$fixture/tmp" CONTAINERS_CONF="$fixture/containers.conf"
  CONTAINERS_STORAGE_CONF="$fixture/storage.conf"
  REGISTRY_AUTH_FILE="$fixture/auth.json"
  "$podman_bin" --remote=false --root "$fixture/graph" --runroot "$fixture/run"
  --registries-conf "$fixture/registries.conf"
  --storage-driver vfs --tmpdir "$fixture/tmp" --hooks-dir "$fixture/hooks")
p() { timeout --kill-after=2s 60s "${isolated[@]}" "$@"; }
cleanup() {
  local status=$? failed=0
  trap - EXIT TERM INT
  # Stop API and concurrent cleanup before deleting containers or store files.
  for pid in "$cleanup_pid" "$api_pid" "$docker_pid"; do
    [[ -z $pid ]] || kill "$pid" 2>/dev/null || true
  done
  local stop_deadline=$((SECONDS + 4))
  for pid in "$cleanup_pid" "$api_pid" "$docker_pid"; do
    [[ -n $pid ]] || continue
    while kill -0 "$pid" 2>/dev/null && ((SECONDS < stop_deadline)); do sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
      failed=1
    fi
  done
  [[ -z $api_pid ]] || wait "$api_pid" 2>/dev/null || true
  [[ -z $docker_pid ]] || wait "$docker_pid" 2>/dev/null || true
  [[ -z $cleanup_pid ]] || wait "$cleanup_pid" 2>/dev/null || true
  # Before the first Podman call there are no subordinate-owned files or pause.
  # Once startup begins, missing/invalid identity must still preserve the fixture.
  if [[ $pause_state == unstarted ]]; then
    timeout --kill-after=1s 5s rm -rf -- "$fixture"
    [[ ! -e $fixture ]] || exit 1
    echo 'PASS early setup temporary directory removed (Podman not started)'
    exit "$status"
  fi
  # Verify the identity recorded at startup before invoking Podman again.
  # No default-runtime migration/reset: those can stop a shared pause process.
  if [[ $pause_state != captured ]] || ! pause_guard verify; then
    echo "FAIL pause identity uncertain; isolated fixture preserved: $fixture" >&2
    exit 1
  fi
  # Only this fixture's store is addressed, including on partial setup failure.
  timeout --kill-after=1s 8s "${isolated[@]}" rm --all --force --time 1 >/dev/null 2>&1 || failed=1
  # Image/volume files can have subordinate UID ownership.
  timeout --kill-after=1s 8s "${isolated[@]}" unshare rm -rf -- "$fixture/graph" "$fixture/run" >/dev/null 2>&1 || failed=1
  if ((failed)) || ! pause_guard stop; then
    echo "FAIL isolated teardown; fixture preserved: $fixture" >&2
    exit 1
  fi
  # No further Podman calls: they could recreate the pause process.
  timeout --kill-after=1s 5s rm -rf -- "$fixture" || failed=1
  [[ ! -e $fixture ]] || failed=1
  if ((failed)); then
    echo 'FAIL isolated teardown' >&2
    exit 1
  fi
  echo 'PASS isolated resources and temporary directory removed'
  exit "$status"
}
# Podman v5.8.4 pkg/rootless/rootless_linux.c do_pause first execs catatonit
# with argv "catatonit -P", falling back to Podman with only argv[0].
# https://github.com/containers/podman/blob/v5.8.4/pkg/rootless/rootless_linux.c
# pause.pid lives under XDG_RUNTIME_DIR/libpod/tmp.
# Namespace agreement with our isolated CLI proves which runtime we may stop;
# a pidfd pins process identity across validation and signalling (no PID reuse).
pause_guard() {
  timeout --kill-after=1s 6s python3 -I - "$1" "$fixture" "$podman_bin" <<'PYPAUSE'
import json, os, pathlib, select, signal, sys
mode, root, binary = sys.argv[1:]
root = pathlib.Path(root)
pidfile = root / 'runtime/libpod/tmp/pause.pid'
record = root / 'pause-identity.json'
try:
    assert pidfile.is_file() and not pidfile.is_symlink()
    pid = int(pidfile.read_text())
    assert pid > 1
    fd = os.pidfd_open(pid)
    proc = pathlib.Path('/proc') / str(pid)
    def identity():
        stat = (proc / 'stat').read_text().rsplit(') ', 1)[1].split()
        return dict(pid=pid, start=stat[19], exe=os.readlink(proc / 'exe'),
                    argv=(proc / 'cmdline').read_bytes().hex(),
                    uid=proc.stat().st_uid,
                    namespaces=[os.readlink(proc / 'ns' / ns) for ns in ('user', 'mnt')])
    current = identity()
    assert current['uid'] == os.getuid()
    expected = (root / 'pause-namespaces').read_text().splitlines()
    assert len(expected) == 4
    if current['argv'] == os.fsencode(binary).hex() + '00':
        assert current['exe'] == expected[2]
    else:
        assert current['argv'] == b'catatonit\0-P\0'.hex()
        # Fixed upstream locations plus the executable found in Podman's wrapped
        # PATH (distribution builds can patch the compiled-in helper location).
        helpers = ['/usr/libexec/podman/catatonit', '/usr/bin/catatonit', expected[3]]
        assert current['exe'] in {os.path.realpath(p) for p in helpers if p}
    expected = expected[:2]
    assert current['namespaces'] == expected
    assert all(ns != os.readlink('/proc/self/ns/' + name)
               for ns, name in zip(expected, ('user', 'mnt')))
    if mode == 'capture':
        record.write_text(json.dumps(current))
    else:
        assert mode in ('verify', 'stop') and current == json.loads(record.read_text())
    if mode == 'stop':
        signal.pidfd_send_signal(fd, signal.SIGTERM)
        poll = select.poll()
        poll.register(fd, select.POLLIN)
        if not poll.poll(2000):
            signal.pidfd_send_signal(fd, signal.SIGKILL)
            assert poll.poll(2000), 'pause process did not exit'
        print('PASS isolated pause identity verified and process exited')
    os.close(fd)
except (OSError, ValueError, AssertionError) as error:
    print('FAIL isolated pause verification: ' + str(error), file=sys.stderr)
    sys.exit(1)
PYPAUSE
}
trap cleanup EXIT
trap 'exit 124' TERM
trap 'exit 130' INT
trap 'printf "FAIL line=%s\n" "$LINENO" >&2' ERR
# Capture before API startup: readiness/info failures then have a verified pause
# to stop. Failure during capture is uncertain and must preserve the fixture.
# The child reports namespaces, the real Podman executable and wrapped helper.
pause_state=uncertain
p unshare python3 -c 'import os, shutil; print(os.readlink("/proc/self/ns/user")); print(os.readlink("/proc/self/ns/mnt")); print(os.readlink("/proc/" + str(os.getppid()) + "/exe")); print(shutil.which("catatonit") or "")' >"$fixture/pause-namespaces"
pause_guard capture
pause_state=captured
export STATE_DIR="$fixture/state" SYSTEMCTL_BIN="$fixture/systemctl" DF_BIN="$fixture/df"
# curl's first option disables curlrc; env -i also excludes proxy credentials.
printf '#!/usr/bin/env bash\n' >"$fixture/curl"
# Delay outside curl's API timeout, only for the lock-contention qualification.
printf 'if [[ -e %q ]]; then rm -- %q; touch %q; sleep 10; fi\n' \
  "$fixture/delay-docker" "$fixture/delay-docker" "$fixture/cleanup-holds-lock" >>"$fixture/curl"
printf 'exec env -i PATH=%q %q --disable "$@"\n' "$PATH" "$curl_bin" >>"$fixture/curl"
chmod +x "$fixture/curl"
export CURL_BIN="$fixture/curl" JQ_BIN=jq DOCKER_SOCKET="$fixture/docker.sock"
export PODMAN_SOCKET="$fixture/podman.sock" STORE_PATH="$fixture/graph" DISK_PATH="$fixture"
export TRIGGER_USED_PERCENT=70 CRITICAL_FREE_BYTES=0 CRITICAL_FREE_PERCENT=0
export IMAGE_MIN_AGE=1h STALE_AFTER_SECONDS=10800 LOCK_BUDGET_SECONDS=40
printf '%s\n' forgejo-actions-runner.service forgejo-podman-runner.service >"$STATE_DIR/runner-units"
cat >"$SYSTEMCTL_BIN" <<'MOCK'
#!/usr/bin/env bash
set -eu
case "$*" in
  'is-active --quiet '*) exit 0 ;;
  'show --property=FreezerState --value '*) echo running ;;
  'show --property=ActiveState --property=SubState --property=MainPID --property=ControlPID --property=Job '*)
    printf 'ActiveState=inactive\nSubState=dead\nMainPID=0\nControlPID=0\nJob=0\n' ;;
  *) exit 2 ;;
esac
MOCK
printf '#!/usr/bin/env bash\nprintf "Size Avail\\n100 20\\n"\n' >"$DF_BIN"
chmod +x "$SYSTEMCTL_BIN" "$DF_BIN"
# Systemd/disk admission and the other engine are synthetic. Unexpected requests
# fail loudly. The curl wrapper's one-shot delay holds the real cleanup lock.
python3 - "$DOCKER_SOCKET" "$fixture" >"$fixture/docker.log" 2>&1 <<'PY' &
import http.server, socketserver, sys
socket_path, root = sys.argv[1:]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/containers/json?all=1':
            self.send_error(404); return
        self.send_response(200); self.send_header('Content-Length', '2')
        self.end_headers(); self.wfile.write(b'[]')
    def log_message(self, *args): pass
class Server(socketserver.UnixStreamServer): pass
Server(socket_path, Handler).serve_forever()
PY
docker_pid=$!
timeout --kill-after=2s 240s "${isolated[@]}" system service --time=240 "unix://$PODMAN_SOCKET" >"$fixture/api.log" 2>&1 &
api_pid=$!
api() { "$CURL_BIN" --silent --show-error --fail --max-time 10 --unix-socket "$PODMAN_SOCKET" "$@"; }
ready=0
for ((i = 0; i < 100; i++)); do
  if [[ -S $DOCKER_SOCKET ]] && api http://localhost/_ping >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
((ready)) || {
  echo 'FAIL isolated API startup (logs withheld)' >&2
  exit 1
}
api http://localhost/version | jq -r '"Runtime=" + .Version + " Docker-compatible API=" + .ApiVersion'
echo 'Native API exercised: /v5.0.0/libpod'
# Fail closed if the real service does not use the requested isolated store.
api http://localhost/v5.0.0/libpod/info | jq -e \
  --arg graph "$fixture/graph" --arg run "$fixture/run" \
  '.host.security.rootless == true and .store.graphDriverName == "vfs" and
   .store.graphRoot == $graph and .store.runRoot == $run' >/dev/null
echo 'PASS API confirms rootless temporary vfs graphroot/runroot and pause identity'
case $(uname -m) in
  x86_64 | aarch64) arch=$(uname -m) ;;
  *)
    echo 'Unsupported rootfs architecture' >&2
    exit 1
    ;;
esac
rootfs_name="alpine-minirootfs-3.21.8-$arch.tar.gz"
rootfs_url="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/$arch/$rootfs_name"
for suffix in '' .sha256; do
  "$CURL_BIN" --silent --show-error --fail --max-time 30 --connect-timeout 5 \
    --proto '=https' --max-filesize 16777216 --output "$fixture/$rootfs_name$suffix" "$rootfs_url$suffix"
done
(cd "$fixture" && sha256sum --check "$rootfs_name.sha256")
base=localhost/qualification-base:fixture
p import "$fixture/$rootfs_name" "$base" >"$fixture/import.log" 2>&1
run_cleanup() { timeout --kill-after=2s 55s bash "$source_file"; }
assert_absent() {
  local status=0
  p "$@" || status=$?
  [[ $status == 1 ]] || {
    printf 'FAIL expected absent %s (exists exit status=%s)\n' "$*" "$status" >&2
    exit 1
  }
}
assert_output() { [[ $output == *"$1"* ]] || {
  printf 'FAIL expected %s\n' "$1" >&2
  exit 1
}; }
# Unique content produces independent images with genuine old/recent metadata.
mkdir "$fixture/context"
printf 'FROM %s\nCOPY payload /qualification-payload\n' "$base" >"$fixture/context/Containerfile"
for name in old-unused old-referenced recent-unused; do
  printf '%s\n' "$name" >"$fixture/context/payload"
  stamp=1
  [[ $name != recent-unused ]] || stamp=$(date +%s)
  p build --pull=never --timestamp "$stamp" --layers=false --network none -t "localhost/qualification-$name:fixture" "$fixture/context" >"$fixture/build.log" 2>&1
done
# Check referenced-image protection against the exact native prune endpoint.
# Cleanup prunes exited containers first; this separate assertion isolates the
# API invariant while an unstarted container still holds the old image. The
# native all=true parameter is required to include tagged images.
p create --pull=never --network none --name base-reference "$base" true >/dev/null
p create --pull=never --network none --name image-reference localhost/qualification-old-referenced:fixture true >/dev/null
filters=$(jq -rn '{until:["1h"],dangling:["false"]}|tojson|@uri')
api -X POST "http://localhost/v5.0.0/libpod/images/prune?all=true&filters=$filters" >"$fixture/prune.json"
p image exists localhost/qualification-old-referenced:fixture
assert_absent image exists localhost/qualification-old-unused:fixture
p image exists localhost/qualification-recent-unused:fixture
echo 'PASS native image age filtering and referenced-image protection'
p rm image-reference base-reference >/dev/null
# The live-job guard must prevent removal of an otherwise eligible builder.
p run --pull=never -d --stop-signal SIGKILL --network none --cgroups=disabled --name FORGEJO-ACTIONS-TASK-qualification_JOB-test "$base" sleep 180 >/dev/null
p volume create buildx_buildkit_qualification0_state >/dev/null
p run --pull=never -d --stop-signal SIGKILL --network none --cgroups=disabled --name buildx_buildkit_qualification0 \
  -v buildx_buildkit_qualification0_state:/state "$base" sleep 180 >/dev/null
output=$(STALE_AFTER_SECONDS=1 run_cleanup)
assert_output 'skipped reason=containers_live engine=podman'
p container exists buildx_buildkit_qualification0
p container exists FORGEJO-ACTIONS-TASK-qualification_JOB-test
echo 'PASS live job refuses cleanup before builder deletion'
p rm -f --time 1 FORGEJO-ACTIONS-TASK-qualification_JOB-test >/dev/null
# A stopped non-builder holds another Buildx-named volume at deletion time.
p volume create buildx_buildkit_held0_state >/dev/null
p run --pull=never --network none --cgroups=disabled --name volume-reference \
  -v buildx_buildkit_held0_state:/state "$base" true >/dev/null
status=$("$CURL_BIN" --silent --show-error --max-time 10 --unix-socket "$PODMAN_SOCKET" \
  -X DELETE --output /dev/null --write-out '%{http_code}' \
  http://localhost/v5.0.0/libpod/volumes/buildx_buildkit_held0_state)
[[ $status == 409 ]]
p run --pull=never -d --stop-signal SIGKILL --network none --cgroups=disabled --name nested-database "$base" sleep 180 >/dev/null
sleep 2
output=$(STALE_AFTER_SECONDS=1 run_cleanup)
assert_output 'removed_leftover kind=builder name=buildx_buildkit_qualification0'
assert_output 'removed_leftover kind=stale name=nested-database'
assert_output 'removed_builder_volume name=buildx_buildkit_qualification0_state'
assert_output 'kept_builder_volume name=buildx_buildkit_held0_state reason=in_use'
assert_output 'failed_builder_volumes=0'
assert_absent container exists buildx_buildkit_qualification0
assert_absent container exists nested-database
assert_absent volume exists buildx_buildkit_qualification0_state
p volume exists buildx_buildkit_held0_state
p image exists localhost/qualification-recent-unused:fixture
# This run pruned the old image after its referencing container was removed.
assert_absent image exists localhost/qualification-old-referenced:fixture
echo 'PASS actual cleanup removes old unused tagged image'
echo 'PASS actual cleanup: builder/state removal, HTTP 409 preservation, stale nested removal, recent image retention'
run_gate() {
  env -i PATH="$PATH" STATE_DIR="$STATE_DIR" SYSTEMCTL_BIN="$SYSTEMCTL_BIN" \
    GAME_HELPER_FILE="$repo/modules/nixos/services/forgejo-actions-runner/game-admission.sh" \
    DISK_HELPER_FILE="$repo/modules/nixos/services/forgejo-actions-runner/disk-space-admission.sh" \
    GAME_ADMISSION_ENABLED=0 DISK_SPACE_ENABLED=0 \
    RUNNER_UNIT=forgejo-actions-runner.service GATE_TIMEOUT_SECONDS=5 \
    RUNNER_UNITS='forgejo-actions-runner.service forgejo-podman-runner.service' \
    timeout --kill-after=2s 10s bash -x "$repo/modules/nixos/services/forgejo-actions-runner/runner-start-gate.sh"
}
# Five seconds allows admission before flock; a ten-second wrapper delay
# leaves a five-second scheduling margin while staying within cleanup's budget.
# The synthetic wrapper delay does not consume curl's five-second API timeout.
run_gate >"$fixture/gate-before.log" 2>&1
touch "$fixture/delay-docker"
# Track timeout directly so teardown terminates the helper's process group.
timeout --kill-after=2s 55s bash "$source_file" >"$fixture/cleanup.log" &
cleanup_pid=$!
locked=0
for ((i = 0; i < 100; i++)); do
  if [[ -e $fixture/cleanup-holds-lock ]]; then
    locked=1
    break
  fi
  sleep 0.02
done
((locked))
status=0
run_gate >"$fixture/gate-held.log" 2>&1 || status=$?
[[ $status == 1 ]]
# Trace only this synthetic gate: prove exclusion happened at lock acquisition.
rg -q '^\+ flock -w [1-5] -x 9$' "$fixture/gate-held.log"
if flock -n "$STATE_DIR/lifecycle.lock" true; then
  echo 'FAIL cleanup released lock before gate exclusion assertion' >&2
  exit 1
fi
wait "$cleanup_pid"
cleanup_pid=''
output=$(cat "$fixture/cleanup.log")
assert_output 'pruned leftovers=0 builder_volumes=1 failed_builder_volumes=0'
[[ $output != *'skipped reason='* ]]
assert_absent volume exists buildx_buildkit_held0_state
p image exists localhost/qualification-recent-unused:fixture
run_gate >"$fixture/gate-after.log" 2>&1
echo 'PASS actual runner gate admitted before/after and excluded at flock during cleanup'
echo 'PASS lock-test cleanup completed and removed previously held builder volume'
echo 'Qualification complete (synthetic admission/systemd/other engine; isolated vfs, no production lifecycle qualification)'
