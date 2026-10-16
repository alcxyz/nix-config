# shellcheck shell=bash
# nixfleet runs this before it reboots an interactive host (nix-packages
# #548). It only reads, and prints one finding per line:
#   busy <reason>   someone uses the host now; nixfleet asks the operator
#   block <reason>  never reboot now; nixfleet refuses
#   note <text>     shown before asking, without effect on the decision
# It exits 0 whenever it could check, whatever it found. It may run as root
# or as the operator. A check it cannot complete becomes a note, except
# where not knowing must count as use: an active desktop session whose lock
# state is unreadable, or a game it cannot rule out, is busy.
# The configuration variables are set by the module before this text.

self_uid=$(id -u)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

emit() {
  printf '%s %s\n' "$1" "$2"
}

cannot() {
  emit note "could not check $1"
}

# Runs a command as USER with that user's runtime directory and session bus,
# bounded in time. Root switches user without PAM, so no session is opened.
# Returns 125 when this caller cannot act as USER.
as_user() {
  local user=$1 entry uid gid home
  shift
  entry=$(getent passwd "$user") || return 125
  IFS=: read -r _ _ uid gid _ home _ <<<"$entry"
  local -a session_env=(
    "HOME=$home"
    "USER=$user"
    "XDG_RUNTIME_DIR=/run/user/$uid"
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus"
  )
  if [[ $self_uid == "$uid" ]]; then
    timeout 5 env "${session_env[@]}" "$@" </dev/null
  elif [[ $self_uid == 0 ]]; then
    timeout 5 setpriv --reuid="$uid" --regid="$gid" --init-groups -- env "${session_env[@]}" "$@" </dev/null
  else
    return 125
  fi
}

# Prints locked, unlocked or unknown for USER's Hyprland. logind's LockedHint
# does not follow hyprlock here, so ask the compositor itself.
hyprland_lock_state() {
  local user=$1 instances signatures signature reply locked count=0
  if ! instances=$(as_user "$user" hyprctl -j instances 2>/dev/null) ||
    ! signatures=$(jq -r '.[].instance' <<<"$instances" 2>/dev/null); then
    echo unknown
    return 0
  fi
  while IFS= read -r signature; do
    [[ -n $signature ]] || continue
    if ! reply=$(as_user "$user" hyprctl -i "$signature" -j locked 2>/dev/null); then
      echo unknown
      return 0
    fi
    locked=$(jq -r '.locked' <<<"$reply" 2>/dev/null) || locked=""
    case $locked in
      true) count=$((count + 1)) ;;
      false)
        echo unlocked
        return 0
        ;;
      *)
        echo unknown
        return 0
        ;;
    esac
  done <<<"$signatures"
  if ((count > 0)); then
    echo locked
  else
    echo unknown
  fi
}

check_desktop_sessions() {
  local ids id props type active class remote name
  local -A reported=()
  if ! ids=$(timeout 5 loginctl list-sessions --no-legend 2>/dev/null); then
    cannot "desktop sessions"
    return 0
  fi
  while read -r id _; do
    [[ -n $id ]] || continue
    props=$(timeout 5 loginctl show-session "$id" -p Type -p Active -p Class -p Remote -p Name 2>/dev/null) || continue
    type=$(sed -n 's/^Type=//p' <<<"$props")
    active=$(sed -n 's/^Active=//p' <<<"$props")
    class=$(sed -n 's/^Class=//p' <<<"$props")
    remote=$(sed -n 's/^Remote=//p' <<<"$props")
    name=$(sed -n 's/^Name=//p' <<<"$props")
    [[ -n $name && ($type == wayland || $type == x11) && $active == yes && $class == user && $remote == no ]] || continue
    [[ -z ${reported[$name]:-} ]] || continue
    reported[$name]=1
    case $(hyprland_lock_state "$name") in
      locked) emit note "desktop session of $name is locked" ;;
      unlocked) emit busy "desktop session of $name is active and unlocked" ;;
      *) emit busy "desktop session of $name is active (lock state unknown)" ;;
    esac
  done <<<"$ids"
}

# Without root, the user's own non-dumpable processes (its systemd manager,
# ssh-agent) hide their executable, which the detector rightly counts as
# uncertain. A game is an ordinary dumpable process, so leave those out.
# The detector calls it through PGREP_BIN.
# shellcheck disable=SC2329
readable_pgrep() {
  local pids pid status=0
  pids=$(pgrep "$@") || status=$?
  ((status == 0)) || return "$status"
  for pid in $pids; do
    if readlink "/proc/$pid/exe" >/dev/null 2>&1; then
      echo "$pid"
    fi
  done
}

# Reuses the CI runner's game detector. Its state directory is a scratch
# copy, so the check writes nothing of the runner's and ignores the runner's
# admission bypass and cooldown: only a game running now counts.
# shellcheck disable=SC2034
wine_game_running() (
  state_dir=$(mktemp -d -p "$scratch")
  GAME_ADMISSION_ENABLED=1
  GAME_USER=$game_user
  GAME_ARGV0_BASENAMES=$1
  if ((self_uid != 0)); then
    PGREP_BIN=readable_pgrep
  fi
  # shellcheck source=/dev/null
  source "$game_helper"
  game_admission_status
)

check_games() {
  local name status found=0 uncertain=0
  [[ -n $game_user ]] || return 0
  for name in "${game_wine_argv0_basenames[@]}"; do
    if wine_game_running "$name"; then
      emit "$game_verb" "game $name is running"
      found=1
    else
      status=$?
      ((status == 1)) || uncertain=1
    fi
  done
  for name in "${game_process_names[@]}"; do
    if timeout 5 pgrep -u "$game_user" -x "$name" >/dev/null 2>&1; then
      emit "$game_verb" "game $name is running"
      found=1
    else
      status=$?
      ((status == 1)) || uncertain=1
    fi
  done
  if ((uncertain == 1 && found == 0)); then
    emit busy "cannot tell whether a game runs"
  fi
}

# Prints active when any of USER's units runs, inactive when none does, and
# fails when the user manager cannot be asked. Without a runtime directory
# the user has no manager, so nothing runs.
user_units_state() {
  local user=$1 uid states status=0
  shift
  uid=$(id -u "$user" 2>/dev/null) || return 1
  if [[ ! -d /run/user/$uid ]]; then
    echo inactive
    return 0
  fi
  states=$(as_user "$user" systemctl --user is-active "$@" 2>/dev/null) || status=$?
  if ((status == 124 || status == 125)) || [[ -z $states ]]; then
    return 1
  fi
  if grep -Eqx 'active|activating|reloading|deactivating' <<<"$states"; then
    echo active
  else
    echo inactive
  fi
}

# Couch streams run as user units, but a direct-display stream runs Moonlight
# straight under greetd, outside those units and any desktop session, so a
# running Moonlight process of the user counts too. The process name of the
# wrapped binary is cut to 15 characters.
check_moonlight() {
  local state status=0
  [[ -n $moonlight_user ]] || return 0
  timeout 5 pgrep -u "$moonlight_user" -x 'moonlight|\.moonlight-wrap' >/dev/null 2>&1 || status=$?
  case $status in
    0)
      emit busy "Moonlight stream is running"
      return 0
      ;;
    1) ;;
    *) cannot "Moonlight processes" ;;
  esac
  ((${#moonlight_units[@]} > 0)) || return 0
  if ! state=$(user_units_state "$moonlight_user" "${moonlight_units[@]}"); then
    cannot "Moonlight streams"
    return 0
  fi
  if [[ $state == active ]]; then
    emit busy "Moonlight stream is running"
  fi
}

# Sunshine binds its video port only while a client streams.
check_stream_server() {
  local port sockets
  for port in "${stream_udp_ports[@]}"; do
    if ! sockets=$(timeout 5 ss -Hanu "( sport = :$port )" 2>/dev/null); then
      cannot "game streams"
      return 0
    fi
    if [[ -n $sockets ]]; then
      emit busy "game stream from $host_name is active"
      return 0
    fi
  done
}

check_busy_units() {
  local states unit i
  local -a states_list
  ((${#busy_units[@]} > 0)) || return 0
  # is-active fails when any unit is inactive; its output still lists all.
  states=$(timeout 5 systemctl is-active "${busy_units[@]}" 2>/dev/null) || true
  mapfile -t states_list <<<"$states"
  if [[ -z $states ]] || ((${#states_list[@]} != ${#busy_units[@]})); then
    cannot "backup units"
    return 0
  fi
  for i in "${!busy_units[@]}"; do
    unit=${busy_units[$i]}
    case ${states_list[$i]} in
      active | activating | reloading | deactivating) emit busy "backup ${unit%.service} is running" ;;
    esac
  done
}

check_agent_jobs() {
  local units unit name status=0
  units=$(as_user "$operator_user" systemctl --user list-units --plain --no-legend \
    --state=active,activating 'agent-job-*.service' 2>/dev/null) || status=$?
  if ((status != 0)); then
    cannot "agent jobs"
    return 0
  fi
  while read -r unit _; do
    [[ -n $unit ]] || continue
    name=${unit#agent-job-}
    emit note "agent job ${name%.service} is running"
  done <<<"$units"
}

check_t3code() {
  local i state status
  for i in "${!t3code_names[@]}"; do
    if ! state=$(user_units_state "$operator_user" "${t3code_units[$i]}"); then
      cannot "T3 Code ${t3code_names[$i]}"
      continue
    fi
    [[ $state == active ]] || continue
    # The idle check finds the state directory the running process uses, so
    # a changed configuration cannot hide a live instance. Overrides from
    # the caller's environment must not narrow or bypass it.
    status=0
    as_user "$operator_user" env \
      -u T3CODE_STATE_DATABASE -u T3CODE_ALLOW_ACTIVE_RESTART -u T3CODE_PROC_ROOT \
      T3CODE_INSTANCE_UNIT="${t3code_units[$i]}" \
      T3CODE_SETTLE_SECONDS=0 \
      "$t3code_idle_check" >/dev/null 2>&1 || status=$?
    case $status in
      0) ;;
      75) emit busy "T3 Code ${t3code_names[$i]} has a running turn" ;;
      *) cannot "T3 Code ${t3code_names[$i]}" ;;
    esac
  done
}

check_tmux() {
  local sessions session status=0
  sessions=$(as_user "$operator_user" tmux list-sessions -F '#{session_name}' 2>"$scratch/tmux.err") || status=$?
  if ((status != 0)); then
    # No server is the common idle case, not a failed check.
    if ! grep -Eq 'no server running|error connecting to' "$scratch/tmux.err"; then
      cannot "tmux sessions"
    fi
    return 0
  fi
  while IFS= read -r session; do
    if [[ -n $session ]]; then
      emit note "tmux session $session"
    fi
  done <<<"$sessions"
}

# Remote builds and cache reads arrive over SSH as a Nix daemon or store
# server per client.
check_remote_nix_clients() {
  local status=0
  timeout 5 pgrep -f '^(nix-daemon --stdio|nix-store --serve)' >/dev/null 2>&1 || status=$?
  case $status in
    0) emit note "a remote Nix client is connected to $host_name" ;;
    1) ;;
    *) cannot "remote Nix clients" ;;
  esac
}

# Each check reports what it cannot check itself, so a failed check never
# hides the others.
if ((desktop_sessions == 1)); then
  check_desktop_sessions
fi
check_games
check_moonlight
check_stream_server
check_busy_units
if [[ -n $operator_user ]]; then
  if ((operator_agent_jobs == 1)); then
    check_agent_jobs
  fi
  check_t3code
  if ((operator_tmux == 1)); then
    check_tmux
  fi
fi
if ((remote_nix_clients == 1)); then
  check_remote_nix_clients
fi
for note in "${static_notes[@]}"; do
  emit note "$note"
done
exit 0
