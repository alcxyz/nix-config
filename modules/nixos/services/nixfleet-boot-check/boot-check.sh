# shellcheck shell=bash
# Checks that a host came up as intended after a boot and records the result
# for nixfleet (nix-packages #548), which reads it after a reboot. The result
# file holds key=value lines: status=running|ok|failed, time=<unix seconds>
# and one reason=<problem> line per problem.

result_dir=${NIXFLEET_BOOT_CHECK_RESULT_DIR:-/run/nixfleet-boot-check}
wait_seconds=${NIXFLEET_BOOT_CHECK_WAIT_SECONDS:-300}
read -r -a ignored_units <<<"${NIXFLEET_BOOT_CHECK_IGNORED_UNITS:-}"
# Each entry is UNIT=HOLD_DIRECTORY; the directory may be empty.
read -r -a runner_entries <<<"${NIXFLEET_BOOT_CHECK_RUNNERS:-}"

reasons=()

write_result() {
  local status=$1 tmp reason
  install -d -m 0755 "$result_dir"
  tmp=$(mktemp "$result_dir/.result.XXXXXX")
  {
    printf 'status=%s\n' "$status"
    printf 'time=%s\n' "$(date +%s)"
    for reason in "${reasons[@]}"; do
      printf 'reason=%s\n' "${reason//$'\n'/ }"
    done
  } >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$result_dir/result"
}

write_result running

# Units are still starting at first; running or degraded both mean the boot
# finished, and a degraded system shows up in the failed units below. A long
# boot-time job (a missed garbage collection or prune timer catching up)
# keeps the state at starting, so after the wait that is no failure either:
# the checks below still find what matters.
state=$(timeout "$wait_seconds" systemctl is-system-running --wait 2>/dev/null) || true
if [[ -z $state ]]; then
  state=$(systemctl is-system-running 2>/dev/null) || true
fi
case $state in
  running | degraded | starting) ;;
  *) reasons+=("system is ${state:-unknown} after waiting ${wait_seconds}s") ;;
esac

booted=$(readlink -f /run/booted-system) || booted=unknown
profile=$(readlink -f /nix/var/nix/profiles/system) || profile=unknown
current=$(readlink -f /run/current-system) || current=unknown
# A switch since boot makes the running system the profile without a boot;
# that happens when the timer first starts during a switch, and is no failed
# boot. Booting another generation leaves the running system behind instead.
if [[ $booted != "$profile" && $current != "$profile" ]]; then
  reasons+=("booted $booted but the system profile is $profile")
fi

if failed=$(systemctl list-units --failed --plain --no-legend 2>/dev/null); then
  while read -r unit _; do
    [[ -n $unit ]] || continue
    for ignored in "${ignored_units[@]}"; do
      [[ $unit != "$ignored" ]] || continue 2
    done
    reasons+=("unit $unit has failed")
  done <<<"$failed"
else
  reasons+=("cannot list failed units")
fi

# A runner is fine when it runs or starts, or when it is held back on
# purpose: the runner hold stopped it, or the start gate skipped its start,
# for a game or low disk space (held), and the hold starts it later. The gate
# also skips a start, without a marker, when its lock times out; then nothing
# restarts the runner, so that skip is a failure.
for entry in "${runner_entries[@]}"; do
  unit=${entry%%=*}
  hold_dir=${entry#*=}
  if ! props=$(systemctl show "$unit" -p ActiveState -p Result 2>/dev/null); then
    reasons+=("cannot inspect runner $unit")
    continue
  fi
  active=$(sed -n 's/^ActiveState=//p' <<<"$props")
  result=$(sed -n 's/^Result=//p' <<<"$props")
  case $active in
    active | activating | reloading) continue ;;
  esac
  held=0
  if [[ -n $hold_dir ]]; then
    # A failed runner is a failure even with a marker: its start failed.
    [[ -e $hold_dir/held && $active != failed ]] && held=1
  fi
  ((held == 1)) && continue
  if [[ $result == exec-condition ]]; then
    reasons+=("runner $unit skipped its start without a hold marker")
  else
    reasons+=("runner $unit is $active ($result)")
  fi
done

if ((${#reasons[@]} > 0)); then
  write_result failed
  printf '%s\n' "${reasons[@]}" >&2
  exit 1
fi
write_result ok
echo "boot check passed"
