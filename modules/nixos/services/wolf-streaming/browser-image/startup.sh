#!/usr/bin/env bash
set -eo pipefail

# shellcheck source=/dev/null
source /opt/gow/launch-comp.sh

# Wolf gives each disposable browser container the same persistent home. Keep
# exactly one container attached to that home, then discard Chromium's
# container-local singleton links. Those links point into the previous
# container's /tmp and otherwise make the next launch exit immediately after a
# crash or interrupted stream.
exec 9>"${HOME}/.nixbox-browser-session.lock"
if ! flock -n 9; then
  echo "A browser session is already using this profile" >&2
  exit 75
fi

if [[ -d "${HOME}/.config" ]]; then
  find "${HOME}/.config" -mindepth 1 -maxdepth 5 -name 'Singleton*' -delete
fi

# Wolf persists the application home between disposable containers. Refresh
# only our managed bar files so an older home cannot retain the base image's
# permanently docked Waybar configuration.
if [[ -n "${RUN_SWAY:-}" ]]; then
  install -d "${HOME}/.config/waybar"
  install -m 0644 /cfg/waybar/config.jsonc "${HOME}/.config/waybar/config.jsonc"
  install -m 0644 /cfg/waybar/style.css "${HOME}/.config/waybar/style.css"
fi

browser_flags=(
  "--disable-session-crashed-bubble"
  "--enable-features=VaapiVideoDecoder"
  "--enable-zero-copy"
  --force-device-scale-factor="${NIXBOX_BROWSER_SCALE:-1.5}"
  "--ignore-gpu-blocklist"
  "--no-default-browser-check"
  "--no-first-run"
  "--ozone-platform=wayland"
)

launcher "${NIXBOX_BROWSER_EXECUTABLE}" "${browser_flags[@]}"
