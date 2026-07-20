#!/usr/bin/env bash
set -eo pipefail

# shellcheck source=/dev/null
source /opt/gow/launch-comp.sh

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
