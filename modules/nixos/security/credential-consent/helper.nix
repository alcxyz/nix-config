{
  actionId,
  grepCommand,
  idCommand,
  lib,
  ownerUsers,
  pkcheckCommand,
  pkgs,
}:
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

    exec ${pkcheckCommand} \
      --action-id ${lib.escapeShellArg actionId} \
      --process "$$,$start_time,$uid" \
      --allow-user-interaction \
      --detail credential.title "$title" \
      --detail credential.reason "$reason" \
      --detail credential.impact "$impact" \
      --detail credential.operation "$operation" \
      >/dev/null
  '';
}
