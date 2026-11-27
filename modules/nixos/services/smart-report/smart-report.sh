# Write one smartctl -x report covering every NVMe and SATA drive, named by
# its stable /dev/disk/by-id link. smartctl -x only reads: it starts no
# self-test and changes no setting.
expected="$1"
directory=/var/lib/smart-report
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
report="$directory/$stamp.txt"
partial="$report.partial"

find_drives() {
  local link device
  local -A seen=()
  drives=()
  for link in /dev/disk/by-id/nvme-* /dev/disk/by-id/ata-*; do
    [[ -e $link ]] || continue
    case "$link" in
    *-part[0-9]* | /dev/disk/by-id/nvme-eui.* | /dev/disk/by-id/nvme-nvme.*) continue ;;
    esac
    device="$(readlink -f "$link")"
    [[ -z ${seen[$device]:-} ]] || continue
    seen[$device]=1
    drives+=("$link")
  done
}

# udev may still be creating the by-id links early in boot: wait up to two
# minutes for the expected drives before reporting what is there.
find_drives
for _ in $(seq 24); do
  [[ $expected -gt 0 && ${#drives[@]} -lt $expected ]] || break
  sleep 5
  find_drives
done

{
  printf 'SMART report written %s\n' "$stamp"
  printf 'Drives found: %d' "${#drives[@]}"
  if [[ $expected -gt 0 && ${#drives[@]} -ne $expected ]]; then
    printf ' (WARNING: expected %d)' "$expected"
  fi
  printf '\n'
  for link in "${drives[@]}"; do
    printf '  %s -> %s\n' "${link##*/}" "$(readlink -f "$link")"
  done

  for link in "${drives[@]}"; do
    printf '\n===== %s (%s) =====\n' "${link##*/}" "$(readlink -f "$link")"
    status=0
    smartctl -x "$link" || status=$?
    # smartctl's exit status is a bit mask; see smartctl(8), EXIT STATUS.
    printf '\nsmartctl exit status: %d\n' "$status"
  done
} >"$partial" 2>&1

mv "$partial" "$report"
ln -sfn "$stamp.txt" "$directory/latest.txt"
printf 'Wrote %s\n' "$report"
