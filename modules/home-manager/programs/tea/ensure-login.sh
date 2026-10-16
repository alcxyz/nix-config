# Body of tea-ensure-login (default.nix), which binds tea_url, tea_login,
# tea_ssh_host and tea_config_home (the platform's default config directory,
# relative to HOME) before it. Adds or updates the named login in tea's config
# with the instance URL and SSH host, and leaves its other fields (including
# any token), every other login and the preferences unchanged.

# The file tea reads: its xdg library's config home (~/Library/Application
# Support on macOS), or the legacy ~/.tea/tea.yml while only that exists.
config_dir=${XDG_CONFIG_HOME:-$HOME/$tea_config_home}/tea
config_file=$config_dir/config.yml
if [[ ! -e "$config_file" && -f "$HOME/.tea/tea.yml" ]]; then
  config_dir=$HOME/.tea
  config_file=$config_dir/tea.yml
fi

if [[ -L "$config_file" ]]; then
  echo "tea: $config_file is a link managed elsewhere; not adding the $tea_login login." >&2
  exit 0
fi

if [[ ! -d "$config_dir" ]]; then
  mkdir -p "$config_dir"
  chmod 700 "$config_dir"
fi
current=$(mktemp "$config_dir/.${config_file##*/}.XXXXXX")
updated=$(mktemp "$config_dir/.${config_file##*/}.XXXXXX")
trap 'rm -f -- "$current" "$updated"' EXIT
if [[ -s "$config_file" ]]; then
  cat -- "$config_file" >"$current"
else
  # yq reads no document from an empty file.
  printf 'logins: []\n' >"$current"
fi

# The single-quoted expression contains yq variables, not shell expansion.
# shellcheck disable=SC2016
TEA_LOGIN=$tea_login TEA_URL=$tea_url TEA_SSH_HOST=$tea_ssh_host yq '
  (.logins // []) as $logins
  | {"name": strenv(TEA_LOGIN), "url": strenv(TEA_URL), "ssh_host": strenv(TEA_SSH_HOST)} as $managed
  | if ($logins | map(select(.name == strenv(TEA_LOGIN))) | length) > 0
    then .logins = ($logins | map(select(.name == strenv(TEA_LOGIN)) |= . * $managed))
    else .logins = $logins + [$managed]
    end
' "$current" >"$updated"

if [[ -e "$config_file" ]] && cmp -s -- "$config_file" "$updated"; then
  exit 0
fi
chmod 600 "$updated"
mv -f -- "$updated" "$config_file"
echo "tea: set the $tea_login login in $config_file to $tea_url (SSH host $tea_ssh_host)."
