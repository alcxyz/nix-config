#!/usr/bin/env bash
set -eo pipefail

# shellcheck source=/dev/null
source /opt/gow/launch-comp.sh

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
