# shellcheck shell=bash
# Reruns the boot check once when a switch changes the units it ignores. The
# boot check itself never restarts on a switch (restartIfChanged = false), so
# without this a new ignore list would wait for the next reboot. This unit
# restarts whenever its own unit file changes, including on package updates,
# so it compares the list with the one it recorded and reruns the check only
# when the list differs.

result_dir=${NIXFLEET_BOOT_CHECK_RESULT_DIR:-/run/nixfleet-boot-check}
record=${NIXFLEET_BOOT_CHECK_RECHECK_RECORD:?}
unit=${NIXFLEET_BOOT_CHECK_UNIT:-nixfleet-boot-check.service}
wanted="ignored=${NIXFLEET_BOOT_CHECK_IGNORED_UNITS:-}"

save_record() {
  local tmp
  tmp=$(mktemp "$record.XXXXXX")
  printf '%s\n' "$wanted" >"$tmp"
  mv -f "$tmp" "$record"
}

# Early in a boot the check has not run yet; it will read the current list.
if [[ ! -e $result_dir/result ]]; then
  save_record
  echo "boot check has not run in this boot; it will use the current list"
  exit 0
fi

if [[ -e $record ]]; then
  if [[ $(<"$record") == "$wanted" ]]; then
    echo "ignored units unchanged; boot check not rerun"
    exit 0
  fi
elif [[ $(systemctl show "$unit" -p SubState --value) == exited ]] &&
  grep -qx 'status=ok' "$result_dir/result"; then
  # The switch that adds this unit to a running host knows no earlier list.
  # A check that finished and passed stays as it is; one still running
  # (SubState running) may use the old list, so it is restarted below.
  save_record
  echo "boot check passed; recorded the current list without a rerun"
  exit 0
fi

save_record
# A restart also replaces a check still running with the old list.
echo "ignored units changed or the last check did not pass; rerunning the boot check"
systemctl restart --no-block "$unit"
