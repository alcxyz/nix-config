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
find "${HOME}" -mindepth 1 -maxdepth 6 \
  \( -name '.parentlock' -o -name 'lock' \) -type l -delete

# Browser UI scale is a property of the viewing client, not of the persistent
# browser profile. Give the client launch hook a short, explicit window to
# select its presentation class before the browser process is created. A
# desktop client that does not provide a request gets the unscaled default.
presentation_dir=/tmp/nixbox-browser-presentation
rm -rf "${presentation_dir}"
install -d -m 0700 "${presentation_dir}"
: >"${presentation_dir}/ready"
presentation_scale="${NIXBOX_PRESENTATION_SCALE:-1.0}"
for _attempt in {1..20}; do
  if [[ -s "${presentation_dir}/requested-scale" ]]; then
    presentation_scale="$(tr -d '[:space:]' <"${presentation_dir}/requested-scale")"
    break
  fi
  sleep 0.1
done
case "${presentation_scale}" in
  1 | 1.0)
    presentation_scale=1.0
    cursor_size=24
    ;;
  1.5)
    cursor_size=36
    ;;
  *)
    echo "Unsupported browser presentation scale: ${presentation_scale}" >&2
    exit 64
    ;;
esac
export NIXBOX_BROWSER_SCALE="${presentation_scale}"
export XCURSOR_SIZE="${cursor_size}"
export HYPRCURSOR_SIZE="${cursor_size}"
printf '%s\n' "${presentation_scale}" >"${presentation_dir}/active-scale"
rm -f "${presentation_dir}/ready" "${presentation_dir}/requested-scale"

# Wolf persists the application home between disposable containers. Refresh
# only our managed bar files so an older home cannot retain the base image's
# permanently docked Waybar configuration.
if [[ -n "${RUN_SWAY:-}" ]]; then
  install -d "${HOME}/.config/waybar"
  install -m 0644 /cfg/waybar/config.jsonc "${HOME}/.config/waybar/config.jsonc"
  install -m 0644 /cfg/waybar/style.css "${HOME}/.config/waybar/style.css"
fi

case "${NIXBOX_BROWSER_FAMILY:-chromium}" in
  chromium)
    browser_flags=(
      "--disable-session-crashed-bubble"
      # Chromium's native Wayland path glitches on proprietary NVIDIA and
      # rejects its attempted Vulkan presentation path, while NVIDIA's VA-API
      # bridge does not support Chromium. Use the stable XWayland/OpenGL path.
      "--disable-features=Vulkan"
      --force-device-scale-factor="${NIXBOX_BROWSER_SCALE:-1.5}"
      "--ignore-gpu-blocklist"
      "--no-default-browser-check"
      "--no-first-run"
      "--ozone-platform=x11"
      "--use-angle=gl"
    )
    ;;
  firefox)
    # Firefox-family browsers use XWayland here so all five test candidates
    # exercise the same proven Wolf compositor and presentation path.
    export GDK_BACKEND=x11
    export GDK_DPI_SCALE="${NIXBOX_BROWSER_SCALE}"
    export MOZ_ENABLE_WAYLAND=0
    browser_flags=("--new-instance")
    ;;
  *)
    echo "Unsupported browser family: ${NIXBOX_BROWSER_FAMILY}" >&2
    exit 64
    ;;
esac

launcher "${NIXBOX_BROWSER_EXECUTABLE}" "${browser_flags[@]}"
