#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${NIXBOX_KDECONNECT_EXECUTABLE:-}" ]]; then
  export XCURSOR_SIZE="${NIXBOX_CURSOR_SIZE:-48}"
  export XCURSOR_THEME="${NIXBOX_CURSOR_THEME:-Adwaita}"

  install -d -m 0700 "${HOME}/.config/kdeconnect"
  config_file="${HOME}/.config/kdeconnect/config"
  if [[ -e "${config_file}" ]]; then
    if grep -q '^name=' "${config_file}"; then
      sed -i 's/^name=.*/name=Helium/' "${config_file}"
    else
      printf '\nname=Helium\n' >>"${config_file}"
    fi
  else
    printf 'name=Helium\n' >"${config_file}"
    chmod 0600 "${config_file}"
  fi

  /opt/gow/kdeconnect-session.sh &
fi

exec "$@"
