workspace=9
clients="$(hyprctl clients -j 2>/dev/null)"
jq -e 'type == "array"' <<<"$clients" >/dev/null
provider="$(hyprctl status -j | jq -r '.configProvider // empty')"

focus_workspace() {
  if [[ "$provider" == lua ]]; then
    hyprctl eval \
      "hl.dispatch(hl.dsp.focus({ workspace = $workspace }))" \
      >/dev/null
  else
    hyprctl dispatch workspace "$workspace" >/dev/null
  fi
}

launch_mail() {
  if [[ "$provider" == lua ]]; then
    hyprctl eval \
      "hl.dispatch(hl.dsp.exec_cmd(\"thunderbird\", { workspace = \"$workspace silent\" }))" \
      >/dev/null
  else
    hyprctl dispatch exec "[workspace $workspace silent] thunderbird" \
      >/dev/null
  fi
}

move_window() {
  local address="$1"
  if [[ "$provider" == lua ]]; then
    hyprctl eval \
      "hl.dispatch(hl.dsp.window.move({ workspace = $workspace, window = \"address:$address\", follow = false }))" \
      >/dev/null
  else
    hyprctl dispatch movetoworkspacesilent "$workspace,address:$address" \
      >/dev/null
  fi
}

focus_window() {
  local address="$1"
  if [[ "$provider" == lua ]]; then
    hyprctl eval \
      "hl.dispatch(hl.dsp.focus({ window = \"address:$address\" }))" \
      >/dev/null
  else
    hyprctl dispatch focuswindow "address:$address" >/dev/null
  fi
}

mapfile -t addresses < <(
  jq -r '
    .[]
    | select(
        .mapped == true
        and (.class == "thunderbird" or .initialClass == "thunderbird")
        and (.address | test("^0x[0-9a-fA-F]+$"))
      )
    | .address
  ' <<<"$clients"
)

if ((${#addresses[@]} == 0)); then
  launch_mail
  focus_workspace
  exit 0
fi

for address in "${addresses[@]}"; do
  move_window "$address" || true
done
focus_workspace
focus_window "${addresses[0]}" || true
