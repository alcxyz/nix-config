#!/usr/bin/env bash
# Sourced by the monitor; record_issue and report belong to its caller.
# shellcheck disable=SC2154
check_storage() {
  name="$1"
  kind="$2"
  target="$3"
  maximum_used="$4"
  minimum_free="$5"
  require_rw="$6"
  health=mounted

  if [ "$kind" = zpool ]; then
    if ! values="$(zpool list -Hp -o capacity,free,health "$target" 2>/dev/null)"; then
      record_issue "$name: ZFS pool is unavailable"
      return
    fi
    read -r used free health <<<"$values"
    if [ "$health" != ONLINE ]; then
      record_issue "$name: ZFS health is $health"
    fi
    if [ "$require_rw" = true ] && [ "$(zpool get -H -o value readonly "$target" 2>/dev/null || echo on)" != off ]; then
      record_issue "$name: ZFS pool is read-only"
    fi
  else
    mount_target="$(findmnt -rn -o TARGET --target "$target" 2>/dev/null || true)"
    if [ "$mount_target" != "$target" ]; then
      record_issue "$name: expected filesystem mount is absent"
      return
    fi
    if ! values="$(df -B1 --output=pcent,avail "$target" 2>/dev/null | tail -n 1)"; then
      record_issue "$name: filesystem capacity is unavailable"
      return
    fi
    read -r used free <<<"$values"
    used="${used%%%}"
    if [ "$require_rw" = true ]; then
      options="$(findmnt -rn -o OPTIONS --target "$target" 2>/dev/null || true)"
      case ",$options," in
        *,rw,*) ;;
        *) record_issue "$name: filesystem is not mounted read-write" ;;
      esac
    fi
  fi

  if [ "$maximum_used" -ge 0 ] && [ "$used" -ge "$maximum_used" ]; then
    record_issue "$name: capacity is ${used}% (threshold ${maximum_used}%)"
  fi
  if [ "$minimum_free" -gt 0 ] && [ "$free" -lt "$minimum_free" ]; then
    record_issue "$name: free bytes $free below threshold $minimum_free"
  fi
  printf '%s: used=%s%% free=%s health=%s\n' "$name" "$used" "$free" "$health" >>"$report"
}
