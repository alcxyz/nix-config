#!/usr/bin/env bash
# Exercise snapshot-cleanup.sh against stub zfs, findmnt, umount and sleep.
set -euo pipefail

library=${1:?usage: test-snapshot-cleanup.sh SNAPSHOT_CLEANUP_SH}
library=$(realpath "$library")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
bash_path=$(command -v bash)

# Write an executable stub from stdin; the build sandbox has no /usr/bin/env.
stub() {
  {
    printf '#!%s\n' "$bash_path"
    cat
  } >"$work/bin/$1"
  chmod +x "$work/bin/$1"
}

# zfs list prints $work/snapshots (name<TAB>owner property); zfs destroy fails
# while the snapshot's automount is mounted, while its busy counter is
# positive, or always when the counter is "always".
stub zfs <<'EOF'
set -euo pipefail
case "$1" in
  list)
    if [ "$*" = "list -H -t snapshot -o name,snapshot-restic-home:temporary -d 1 tank/home" ]; then
      cat "$STUB_STATE/snapshots"
    elif [ "$*" = "list -H -t snapshot -o name ${*: -1}" ]; then
      ! grep -qxF -- "${*: -1}" "$STUB_STATE/gone"
    else
      echo "unexpected zfs list arguments: $*" >&2
      exit 2
    fi
    ;;
  destroy)
    printf '%s\n' "$2" >>"$STUB_STATE/destroy-calls"
    if grep -qxF -- "/home/.zfs/snapshot/${2#*@}" "$STUB_STATE/mounts"; then
      echo "cannot destroy '$2': snapshot automount is still mounted" >&2
      exit 1
    fi
    busy_file="$STUB_STATE/busy/${2//[\/@]/_}"
    if [ -f "$busy_file" ]; then
      busy=$(cat "$busy_file")
      if [ "$busy" = always ]; then
        echo "cannot destroy '$2': dataset is busy" >&2
        exit 1
      fi
      if [ "$busy" -gt 0 ]; then
        echo $((busy - 1)) >"$busy_file"
        echo "cannot destroy '$2': dataset is busy" >&2
        exit 1
      fi
    fi
    printf '%s\n' "$2" >>"$STUB_STATE/destroyed"
    ;;
  *) exit 2 ;;
esac
EOF
stub findmnt <<'EOF'
[ "$*" = "-rn --mountpoint ${*: -1}" ] || exit 2
grep -qxF -- "${*: -1}" "$STUB_STATE/mounts"
EOF
stub umount <<'EOF'
printf '%s\n' "$1" >>"$STUB_STATE/umounts"
grep -vxF -- "$1" "$STUB_STATE/mounts" >"$STUB_STATE/mounts.new" || true
mv "$STUB_STATE/mounts.new" "$STUB_STATE/mounts"
EOF
stub sleep <<'EOF'
echo "$1" >>"$STUB_STATE/sleeps"
EOF

reset_state() {
  export STUB_STATE="$work/state"
  rm -rf "$STUB_STATE"
  mkdir -p "$STUB_STATE/busy"
  : >"$STUB_STATE/snapshots"
  : >"$STUB_STATE/mounts"
  : >"$STUB_STATE/gone"
}

count() {
  if [ -f "$1" ]; then
    wc -l <"$1"
  else
    echo 0
  fi
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run() {
  PATH="$work/bin:$PATH" bash -euo pipefail -c '
    snapshot_dataset=tank/home
    snapshot_mountpoint=/home
    destroy_attempts=3
    destroy_retry_delay=1
    source "$1"
    shift
    "$@"
  ' run "$library" "$@"
}

leftover=restic-20260918T055000Z-4242
other_leftover=restic-20260919T055000Z-77

# A busy snapshot is retried and destroyed once ZFS releases it.
reset_state
echo 2 >"$STUB_STATE/busy/tank_home_$leftover"
run destroy_snapshot "$leftover" 2>/dev/null || fail "busy snapshot was not destroyed after retries"
[ "$(count "$STUB_STATE/destroy-calls")" -eq 3 ] || fail "expected three destroy attempts"
[ "$(count "$STUB_STATE/sleeps")" -eq 2 ] || fail "expected two retry delays"
grep -qxF "tank/home@$leftover" "$STUB_STATE/destroyed" || fail "snapshot was not destroyed"

# A snapshot that stays busy fails after the configured attempts and names it.
reset_state
echo always >"$STUB_STATE/busy/tank_home_$leftover"
if run destroy_snapshot "$leftover" 2>"$work/stderr"; then
  fail "persistently busy snapshot reported success"
fi
[ "$(count "$STUB_STATE/destroy-calls")" -eq 3 ] || fail "expected three destroy attempts before failing"
[ "$(count "$STUB_STATE/sleeps")" -eq 2 ] || fail "expected no delay after the final attempt"
grep -qF "tank/home@$leftover" "$work/stderr" || fail "failure did not name the snapshot"

# A snapshot that disappeared meanwhile counts as cleaned up.
reset_state
echo always >"$STUB_STATE/busy/tank_home_$leftover"
echo "tank/home@$leftover" >"$STUB_STATE/gone"
run destroy_snapshot "$leftover" 2>/dev/null || fail "missing snapshot was reported as a failure"
[ "$(count "$STUB_STATE/destroy-calls")" -eq 1 ] || fail "missing snapshot was retried"

# A mounted .zfs automount is unmounted before destroying.
reset_state
echo "/home/.zfs/snapshot/$leftover" >"$STUB_STATE/mounts"
run destroy_snapshot "$leftover" 2>/dev/null || fail "automounted snapshot was not destroyed"
grep -qxF "/home/.zfs/snapshot/$leftover" "$STUB_STATE/umounts" || fail "automount was not unmounted"
[ "$(count "$STUB_STATE/destroy-calls")" -eq 1 ] || fail "automount was not unmounted before the first destroy"

# Names outside the service pattern are refused outright.
reset_state
if run destroy_snapshot "manual-keep" 2>/dev/null; then
  fail "destroyed a snapshot outside the service pattern"
fi
[ "$(count "$STUB_STATE/destroy-calls")" -eq 0 ] || fail "zfs destroy ran for a foreign snapshot"

# The sweep removes only this service's leftovers on the source dataset:
# both the name pattern and the ownership property must match.
reset_state
tab=$'\t'
cat >"$STUB_STATE/snapshots" <<EOF
tank/home@$leftover${tab}true
tank/home@autosnap_2026-09-18_00:00:00_daily${tab}-
tank/home@restic-manual${tab}true
tank/home@restic-20260918T055000Z-4242-keep${tab}true
tank/home@restic-20260920T055000Z-99${tab}-
tank/home@restic-20260921T055000Z-98${tab}false
tank/home@$other_leftover${tab}true
tank/other@restic-20260918T055000Z-1${tab}true
EOF
run sweep_leftover_snapshots 2>/dev/null || fail "sweep reported failure"
printf '%s\n' "tank/home@$leftover" "tank/home@$other_leftover" >"$work/expected"
diff -u "$work/expected" "$STUB_STATE/destroy-calls" || fail "sweep touched unexpected snapshots"

# A stuck leftover fails the sweep without stopping the others.
reset_state
printf '%s\ttrue\n' "tank/home@$leftover" "tank/home@$other_leftover" >"$STUB_STATE/snapshots"
echo always >"$STUB_STATE/busy/tank_home_$leftover"
if run sweep_leftover_snapshots 2>/dev/null; then
  fail "sweep hid a snapshot it could not destroy"
fi
grep -qxF "tank/home@$other_leftover" "$STUB_STATE/destroyed" || fail "sweep stopped at the first failure"

# An empty snapshot list is a successful no-op.
reset_state
run sweep_leftover_snapshots || fail "empty sweep failed"
[ "$(count "$STUB_STATE/destroy-calls")" -eq 0 ] || fail "empty sweep destroyed something"

echo "snapshot cleanup contract passed"
