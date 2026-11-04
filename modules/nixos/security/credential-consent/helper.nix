{
  actionId,
  grepCommand,
  idCommand,
  lib,
  ownerUsers,
  pkcheckCommand,
  pkgs,
  # When set, a remote answer is sought alongside the local prompt:
  # { command, origin, rpId, publicKey, credentialId, timeoutSeconds, spoolDir,
  #   notifyCommand }, with spoolDir null for the user's runtime directory.
  remote ? null,
}: let
  pkcheckArgs = ''
    --action-id ${lib.escapeShellArg actionId} \
      --process "$$,$start_time,$uid" \
      --allow-user-interaction \
      --detail credential.title "$title" \
      --detail credential.reason "$reason" \
      --detail credential.impact "$impact" \
      --detail credential.operation "$operation" \
      --detail credential.requester "$requester" \
      --detail polkit.message "$message"'';

  decide =
    if remote == null
    then ''
      exec ${pkcheckCommand} ${pkcheckArgs} \
        >/dev/null
    ''
    else ''
      # Both ways of answering run from the start and the first answer wins.
      # A way that cannot run is not an answer, so the other stays open: a
      # local "no" for an inactive session, or a remote path that cannot start.
      # Polkit cancels the local prompt when its pkcheck ends.
      cleanup() {
        trap - EXIT TERM INT
        for pid in "''${pending[@]}"; do
          kill "$pid" 2>/dev/null || true
        done
      }
      pending=()
      trap cleanup EXIT
      trap 'exit 143' TERM
      trap 'exit 130' INT

      ${pkcheckCommand} ${pkcheckArgs} \
        </dev/null >/dev/null 2>&1 &
      local_pid=$!
      pending+=("$local_pid")

      spool=${
        if remote.spoolDir == null
        then ''"/run/user/$uid/credential-consent"''
        else lib.escapeShellArg remote.spoolDir
      }
      ${remote.command} wait \
        --spool "$spool" \
        --origin ${lib.escapeShellArg remote.origin} \
        --rp-id ${lib.escapeShellArg remote.rpId} \
        --public-key ${lib.escapeShellArg remote.publicKey} \
        --credential-id ${lib.escapeShellArg remote.credentialId} \
        --timeout ${toString remote.timeoutSeconds}s \
        --title "$title" \
        --reason "$reason" \
        --impact "$impact" \
        --operation "$operation" \
        --requester "$requester" \
        ${lib.optionalString (remote.notifyCommand != null) "--notify ${lib.escapeShellArg remote.notifyCommand}"} \
        </dev/null >/dev/null &
      remote_pid=$!
      pending+=("$remote_pid")

      # Keeps pkcheck from outliving the request if the remote path did not start.
      ${lib.getExe' pkgs.coreutils "sleep"} ${toString remote.timeoutSeconds} >/dev/null 2>&1 &
      timer_pid=$!
      pending+=("$timer_pid")

      while :; do
        finished=""
        status=0
        wait -n -p finished "''${pending[@]}" || status=$?
        remaining=()
        for pid in "''${pending[@]}"; do
          [[ "$pid" == "$finished" ]] || remaining+=("$pid")
        done
        pending=("''${remaining[@]}")

        case "$finished" in
          "$timer_pid")
            exit 4
            ;;
          "$local_pid")
            # 3 is a person dismissing the prompt; other failures are not answers.
            case "$status" in
              0 | 3) exit "$status" ;;
            esac
            ;;
          "$remote_pid")
            # 3 is denied and 4 is the request's end; other failures are not answers.
            case "$status" in
              0 | 3 | 4) exit "$status" ;;
            esac
            ;;
        esac

        # Only the timer left means neither way can answer.
        if (( ''${#pending[@]} == 1 )); then
          exit 1
        fi
      done
    '';
in
  pkgs.writeShellApplication {
    name = "dms-credential-consent";
    text = ''
      usage() {
        echo "Usage: dms-credential-consent --title TITLE --reason REASON --impact IMPACT --operation LABEL" >&2
        exit 2
      }

      title=""
      reason=""
      impact=""
      operation=""
      while (( $# > 0 )); do
        case "$1" in
          --title)
            [[ -n ''${2:-} ]] || usage
            title="$2"
            shift 2
            ;;
          --reason)
            [[ -n ''${2:-} ]] || usage
            reason="$2"
            shift 2
            ;;
          --impact)
            [[ -n ''${2:-} ]] || usage
            impact="$2"
            shift 2
            ;;
          --operation)
            [[ -n ''${2:-} ]] || usage
            operation="$2"
            shift 2
            ;;
          *) usage ;;
        esac
      done

      [[ -n "$title" && -n "$reason" && -n "$impact" && -n "$operation" ]] || usage

      validate_detail() {
        local name="$1"
        local value="$2"
        local limit="$3"

        (( ''${#value} <= limit )) || {
          echo "dms-credential-consent: $name exceeds $limit characters" >&2
          exit 2
        }
        if [[ "$value" == *$'\n'* ]] || printf '%s' "$value" | LC_ALL=C ${grepCommand} -q '[[:cntrl:]]'; then
          echo "dms-credential-consent: $name contains a control character" >&2
          exit 2
        fi
      }

      validate_detail title "$title" 120
      validate_detail reason "$reason" 600
      validate_detail impact "$impact" 600
      validate_detail operation "$operation" 240

      # Identifies the asking thread for the operator; any process can set it, so
      # it proves nothing. Only a plain ID reaches the prompt.
      requester="No T3 thread"
      if [[ -n ''${T3CODE_THREAD_ID:-} ]]; then
        if [[ "$T3CODE_THREAD_ID" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]; then
          requester="Requested by T3 thread $T3CODE_THREAD_ID"
        else
          requester="Requested by a T3 thread with an unreadable ID"
        fi
      fi

      uid="$(${idCommand} -u)"
      (( uid != 0 )) || {
        echo "dms-credential-consent: root must not request interactive credential consent" >&2
        exit 1
      }
      caller="$(${idCommand} -un)"
      caller_is_owner=false
      owner_users=(${lib.escapeShellArgs ownerUsers})
      for owner in "''${owner_users[@]}"; do
        if [[ "$caller" == "$owner" ]]; then
          caller_is_owner=true
          break
        fi
      done
      "$caller_is_owner" || {
        echo "dms-credential-consent: the current user is not an action owner" >&2
        exit 1
      }

      proc_stat="$(<"/proc/$$/stat")"
      proc_tail="''${proc_stat##*) }"
      read -r -a proc_fields <<< "$proc_tail"
      (( ''${#proc_fields[@]} >= 20 )) || {
        echo "dms-credential-consent: cannot determine process start time" >&2
        exit 1
      }
      start_time="''${proc_fields[19]}"

      # Polkit gives an agent only the message, not caller details, and expands
      # $(key) in the message from the details. It does not rescan what it
      # inserts, so text in a value cannot change this template.
      newline=$'\n'
      # shellcheck disable=SC2016
      message='$(credential.title)'"$newline"'$(credential.reason)'"$newline"'$(credential.impact)'"$newline"'Operation: $(credential.operation)'"$newline"'$(credential.requester)'

      ${decide}
    '';
  }
