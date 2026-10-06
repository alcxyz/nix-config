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
# A bounded handshake holds the lock until the contender has actually failed.
# It stays outside curl's API timeout and inside cleanup's unchanged lock budget.
# shellcheck disable=SC2016
printf 'if [[ -e %q ]]; then rm -- %q; touch %q; deadline=$((SECONDS + 15)); while [[ ! -e %q ]]; do ((SECONDS < deadline)) || exit 1; sleep 0.02; done; fi\n' \
  "$fixture/delay-docker" "$fixture/delay-docker" "$fixture/cleanup-holds-lock" "$fixture/release-cleanup" >>"$fixture/curl"
printf 'exec env -i PATH=%q %q --disable "$@"\n' "$PATH" "$curl_bin" >>"$fixture/curl"
chmod +x "$fixture/curl"
export CURL_BIN="$fixture/curl" JQ_BIN=jq DOCKER_SOCKET="$fixture/docker.sock"
export PODMAN_SOCKET="$fixture/podman.sock" STORE_PATH="$fixture/graph" DISK_PATH="$fixture"
export TRIGGER_USED_PERCENT=70 CRITICAL_FREE_BYTES=0 CRITICAL_FREE_PERCENT=0
export IMAGE_MIN_AGE=1h STALE_AFTER_SECONDS=10800 LOCK_BUDGET_SECONDS=40
chmod 700 "$STATE_DIR"
printf '%s\n' forgejo-actions-runner.service forgejo-podman-runner.service >"$STATE_DIR/runner-units"
cat >"$SYSTEMCTL_BIN" <<'MOCK'
#!/usr/bin/env bash
set -eu
case "$*" in
  'is-active --quiet '*) exit 0 ;;
  'show --property=FreezerState --value '*) echo running ;;
  'show --property=ExecMainStartTimestampMonotonic --value '*) echo 12345 ;;
  'show --property=ActiveState --property=SubState --property=MainPID --property=ControlPID --property=Job '*)
    printf 'ActiveState=inactive\nSubState=dead\nMainPID=0\nControlPID=0\nJob=\n' ;;
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
api http://localhost/version | jq -e '.Version == "5.8.7"' >/dev/null || {
  echo 'FAIL this fixture requires Podman 5.8.7' >&2
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
assert_complete() {
  assert_output 'pruned leftovers='
  [[ $output != *'skipped reason='* && $output != *'failed step='* ]]
}
assert_output() { [[ $output == *"$1"* ]] || {
  printf 'FAIL expected %s\n' "$1" >&2
  exit 1
}; }
# Unique content produces independent images with genuine old/recent metadata.
mkdir "$fixture/context"
printf 'FROM %s\nCOPY payload /qualification-payload\n' "$base" >"$fixture/context/Containerfile"
for name in old-unused old-referenced old-multitag old-parent recent-unused; do
  printf '%s\n' "$name" >"$fixture/context/payload"
  stamp=1
  [[ $name != recent-unused ]] || stamp=$(date +%s)
  p build --pull=never --timestamp "$stamp" --layers=false --network none -t "localhost/qualification-$name:fixture" "$fixture/context" >"$fixture/build.log" 2>&1
done
# Direct DELETE refuses a referenced image without force. The production
# snapshot also excludes it; no bulk prune (or Buildah cache cleanup) is called.
p create --pull=never --network none --name base-reference "$base" true >/dev/null
p create --pull=never --network none --name image-reference localhost/qualification-old-referenced:fixture true >/dev/null
referenced_id=$(p image inspect --format '{{.Id}}' localhost/qualification-old-referenced:fixture)
api 'http://localhost/images/json?all=true' | jq -e --arg id "sha256:$referenced_id" \
  'any(.[]; .Id == $id and .Containers == 1 and (.RepoTags | type) == "array")' >/dev/null
echo 'PASS compat referenced image shape: Containers=1 and RepoTags=array'
status=$(api -X DELETE --output "$fixture/reference-delete.json" --write-out '%{http_code}' \
  "http://localhost/images/$referenced_id?force=false&noprune=true" 2>/dev/null) || true
[[ $status == 409 ]]
p image exists localhost/qualification-old-referenced:fixture
p image exists localhost/qualification-old-unused:fixture
p image exists localhost/qualification-recent-unused:fixture
p tag localhost/qualification-old-multitag:fixture localhost/qualification-old-multitag:second
# Layered child exposes a genuine ParentId; noprune prevents recursion, and
# the selection snapshot preserves a parent even if its child is deleted.
printf 'FROM localhost/qualification-old-parent:fixture\nCOPY payload /child-payload\n' >"$fixture/context/Containerfile"
printf 'child\n' >"$fixture/context/payload"
p build --pull=never --timestamp 1 --layers=true --network none -t localhost/qualification-old-child:fixture "$fixture/context" >"$fixture/build.log" 2>&1
parent_id=$(p image inspect --format '{{.Id}}' localhost/qualification-old-parent:fixture)
api 'http://localhost/images/json?all=true' | jq -e --arg parent "$parent_id" \
  'any(.[]; .ParentId == $parent)' >/dev/null
# Untagged intermediate parents are the recursive-removal positive control:
# a tagged parent would survive even if the server ignored noprune=true.
# v5.8.7 compat/images.go:GetImages normalizes nil RepoTags to [], and
# abi/images_list.go:List supplies Containers from len(img.Containers()).
# compat/images_remove.go:RemoveImage and abi/images.go:Remove pass NoPrune
# through to libimage/image.go:removeRecursive's explicit recursion guard.
for noprune in true false; do
  printf 'FROM %s\nCOPY payload /intermediate-payload\nCOPY leaf /leaf-payload\n' "$base" >"$fixture/context/Containerfile"
  printf 'intermediate-%s\n' "$noprune" >"$fixture/context/payload"
  printf 'leaf-%s\n' "$noprune" >"$fixture/context/leaf"
  tag="localhost/qualification-recursion-$noprune:fixture"
  p build --pull=never --timestamp 1 --layers=true --network none -t "$tag" "$fixture/context" >"$fixture/build.log" 2>&1
  child_id=$(p image inspect --format '{{.Id}}' "$tag")
  api 'http://localhost/images/json?all=true' >"$fixture/images.json"
  intermediate=$(jq -er --arg child "sha256:$child_id" '.[] | select(.Id == $child) | .ParentId | select(length == 64)' "$fixture/images.json")
  jq -e --arg parent "sha256:$intermediate" \
    'any(.[]; .Id == $parent and .RepoTags == [] and .Containers == 0) and
     all(.[]; (.RepoTags | type) == "array" and (.Containers | type) == "number")' "$fixture/images.json" >/dev/null
  if [[ $noprune == true ]]; then
    printf 'PASS compat dangling intermediate shape: '
    jq -c --arg parent "sha256:$intermediate" '.[] | select(.Id == $parent) | {RepoTags, Containers, CreatedType:(.Created|type), ParentIdType:(.ParentId|type)}' "$fixture/images.json"
  fi
  api -X DELETE "http://localhost/images/$child_id?force=false&noprune=$noprune" >"$fixture/recursion-delete.json"
  jq -e --arg child "$child_id" 'any(.[]; .Deleted == $child)' "$fixture/recursion-delete.json" >/dev/null
  assert_absent image exists "$child_id"
  if [[ $noprune == true ]]; then
    p image exists "$intermediate"
    api 'http://localhost/images/json?all=true' | jq -e --arg parent "sha256:$intermediate" \
      'any(.[]; .Id == $parent and .RepoTags == [] and .Containers == 0 and .Dangling == true)' >/dev/null
    jq -e --arg parent "$intermediate" 'all(.[]; .Deleted != $parent)' "$fixture/recursion-delete.json" >/dev/null
    # Fixture-only control removal; avoid mixing it into the helper's selection.
    p rmi --no-prune "$intermediate" >/dev/null
  else
    assert_absent image exists "$intermediate"
    jq -e --arg parent "$intermediate" 'any(.[]; .Deleted == $parent)' "$fixture/recursion-delete.json" >/dev/null
  fi
done
echo 'PASS noprune=true retains dangling intermediate; noprune=false recursively deletes positive control'
# Make the old child the only eligible leaf for the first cleanup pass. This
# proves actual child deletion and same-snapshot parent preservation without
# relying on image ID ordering or the bounded pass reaching every image.
for name in old-unused old-referenced; do
  p tag "localhost/qualification-$name:fixture" "localhost/qualification-$name:protected"
done
# Buildah CacheParent is TMPDIR/buildah-cache-<rootless uid>; CleanCacheMount
# recursively removes that whole directory. TMPDIR is fixture-owned even for
# the API, so this sentinel exercises the actual cache cleanup target safely.
# See Podman v5.8.7 vendor/github.com/containers/buildah/{internal,pkg}/volumes.
cache_mounts="$fixture/tmp/buildah-cache-$(id -u)"
p unshare mkdir -p "$cache_mounts"
# The unshared child receives the fixture directory as its first argument.
# shellcheck disable=SC2016
p unshare sh -c 'printf "fixture-cache\n" > "$1/sentinel"' sh "$cache_mounts"
p volume create qualification-unrelated >/dev/null
echo 'PASS individual image DELETE reference protection; parent/multitag/cache preservation fixtures created'
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
assert_complete
assert_output 'image_min_age=1h images=1 reclaimed_bytes='
assert_absent image exists localhost/qualification-old-child:fixture
p image exists localhost/qualification-old-parent:fixture
p unshare test -f "$cache_mounts/sentinel"
p volume exists qualification-unrelated
[[ ! -e $STATE_DIR/cleanup-in-flight ]]
echo 'PASS first cleanup retains parent, multitag image, Buildah cache sentinel and unrelated volume'
assert_absent container exists buildx_buildkit_qualification0
assert_absent container exists nested-database
assert_absent volume exists buildx_buildkit_qualification0_state
p volume exists buildx_buildkit_held0_state
p image exists localhost/qualification-recent-unused:fixture
for name in old-unused old-referenced; do
  p untag "localhost/qualification-$name:fixture" "localhost/qualification-$name:protected"
done
# Bounded work may leave older eligible images for a later pass. Every pass
# must either finish its image phase or explicitly stop at the image budget;
# a snapshot/schema skip cannot be counted as partial progress.
for ((pass = 0; pass < 4; pass++)); do
  if ! p image exists localhost/qualification-old-referenced:fixture && ! p image exists localhost/qualification-old-unused:fixture && ! p image exists localhost/qualification-old-parent:fixture; then break; fi
  output=$(run_cleanup)
  [[ $output == *'pruned leftovers='* || $output == *'skipped reason=lock_budget_exhausted step=remove_image'* ]]
  [[ $output != *'engine_api_invalid'* && ! -e $STATE_DIR/cleanup-in-flight ]]
done
assert_absent image exists localhost/qualification-old-referenced:fixture
assert_absent image exists localhost/qualification-old-unused:fixture
p image exists localhost/qualification-old-multitag:fixture
p image exists localhost/qualification-old-multitag:second
# Once its child was deleted, the tagged parent became eligible and was
# removed by a later snapshot, rather than recursively in its child's DELETE.
assert_absent image exists localhost/qualification-old-parent:fixture
p unshare test -f "$cache_mounts/sentinel"
p volume exists qualification-unrelated
echo 'PASS bounded individual deletes remove old unused tagged images'
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
# Earlier passes may have removed the formerly held volume after its container
# was pruned. Recreate a known removable volume for this independent lock trial.
p volume create buildx_buildkit_held0_state >/dev/null
# One controlled eligible image makes full image completion fit after the
# synthetic lock delay, without changing any production client/lock budget.
printf 'FROM %s\nCOPY payload /lock-payload\n' "$base" >"$fixture/context/Containerfile"
printf 'lock-leaf\n' >"$fixture/context/payload"
p build --pull=never --timestamp 1 --layers=false --network none -t localhost/qualification-lock-leaf:fixture "$fixture/context" >"$fixture/build.log" 2>&1
# The five-second contender must time out before we release the handshake.
# Its fifteen-second ceiling preserves the helper's real forty-second budget
# and leaves enough time for one image DELETE and the normal API requests.
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
[[ $status == 1 ]] || {
  printf 'FAIL runner exclusion status=%s\n' "$status" >&2
  exit 1
}
# Trace only this synthetic gate: prove exclusion happened at lock acquisition.
rg -q '^\+ flock -w [1-5] -x 9$' "$fixture/gate-held.log"
if flock -n "$STATE_DIR/lifecycle.lock" true; then
  echo 'FAIL cleanup released lock before gate exclusion assertion' >&2
  exit 1
fi
touch "$fixture/release-cleanup"
wait "$cleanup_pid"
cleanup_pid=''
output=$(cat "$fixture/cleanup.log")
assert_output 'removed_builder_volume name=buildx_buildkit_held0_state'
assert_complete
assert_output 'image_min_age=1h images=1 reclaimed_bytes='
assert_absent image exists localhost/qualification-lock-leaf:fixture
[[ ! -e $STATE_DIR/cleanup-in-flight ]]
assert_absent volume exists buildx_buildkit_held0_state
p image exists localhost/qualification-recent-unused:fixture
run_gate >"$fixture/gate-after.log" 2>&1
echo 'PASS actual runner gate admitted before/after and excluded at flock during cleanup'
echo 'PASS lock-test cleanup completed image phase, deleted eligible leaf and removed previously held builder volume'
echo 'Qualification complete (synthetic admission/systemd/other engine; isolated vfs, no production lifecycle qualification)'
