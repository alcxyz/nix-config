set -u

prop() {
  busctl get-property org.bluez "$1" org.bluez.Device1 "$2" 2>/dev/null || true
}

while true; do
  busctl tree --list org.bluez \
    | grep -E '^/org/bluez/hci[0-9]+/dev_[^/]+$' \
    | while read -r device; do
      [ "$(prop "$device" Icon)" = 's "input-keyboard"' ] || continue
      [ "$(prop "$device" Paired)" = "b true" ] || continue
      [ "$(prop "$device" Trusted)" = "b true" ] || continue
      [ "$(prop "$device" Connected)" = "b false" ] || continue

      busctl call org.bluez "$device" org.bluez.Device1 Connect >/dev/null 2>&1 || true
    done

  sleep 10
done
