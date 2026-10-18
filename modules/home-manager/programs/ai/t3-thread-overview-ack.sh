# shellcheck shell=bash
# Record recently settled T3 threads the user accepts as done, so the thread
# overview stops flagging them (ADR-0091). Nothing in T3 changes: settled is
# already T3's done state, and only the overview's readers kept guessing.
#
# Entries map a thread ID to the settle time the user saw. t3-thread-inventory
# marks a settled thread `acknowledged` only while that time still matches, so
# a thread reopened and settled again is judged afresh.

# The Nix wrapper sets ack_file_default, and t3-thread-id.sh's t3_valid_id,
# before this text.
: "${ack_file_default:?}"
prog=t3-thread-overview-ack
ack_file=${T3_OVERVIEW_ACK_FILE:-$ack_file_default}

usage() {
  cat >&2 <<'USAGE'
Usage: t3-thread-overview-ack ID@SETTLED_AT...  accept settled threads as done
       t3-thread-overview-ack --forget ID...    judge them again
       t3-thread-overview-ack --list            print the recorded entries
The overview page builds the first form from the threads you tick.
USAGE
}

read_acks() {
  if [ ! -s "$ack_file" ]; then
    echo '{}'
  elif ! jq -cse 'if length == 1 and (.[0] | type == "object" and all(.[]; type == "string"))
    then .[0] else error("bad") end' "$ack_file" 2>/dev/null; then
    echo "$prog: $ack_file is not an acknowledgement file; fix or remove it" >&2
    exit 65
  fi
}

# update FILTER ARG...: apply FILTER to the recorded entries, with ARG... as
# raw input lines, under a lock so concurrent calls do not lose entries. The
# arguments go in on stdin, never as jq options.
update() {
  local filter=$1 acks new tmp
  shift
  mkdir -p -- "$(dirname -- "$ack_file")"
  exec 9>"$ack_file.lock"
  flock 9
  acks=$(read_acks)
  new=$(printf '%s\n' "$@" | jq -cRn --argjson acks "$acks" "$filter")
  tmp=$(mktemp "$ack_file.XXXXXX")
  printf '%s\n' "$new" >"$tmp"
  mv -f -- "$tmp" "$ack_file"
  exec 9>&-
}

case ${1:-} in
  "")
    usage
    exit 64
    ;;
  -h | --help)
    usage
    ;;
  --list)
    if [ "$#" -ne 1 ]; then
      usage
      exit 64
    fi
    read_acks | jq .
    ;;
  --forget)
    shift
    if [ "$#" -eq 0 ]; then
      usage
      exit 64
    fi
    for id; do
      if ! t3_valid_id "$id"; then
        echo "$prog: unexpected characters in $id" >&2
        exit 64
      fi
    done
    # shellcheck disable=SC2016 # a jq filter, not shell
    update '[inputs] as $ids | $acks | with_entries(select(.key | IN($ids[]) | not))' "$@"
    ;;
  *)
    for arg; do
      id=${arg%@*}
      at=${arg#*@}
      if [[ $arg != *@* ]] || ! t3_valid_id "$id" || ! [[ $at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$ ]]; then
        echo "$prog: expected ID@SETTLED_AT, got $arg" >&2
        exit 64
      fi
    done
    # shellcheck disable=SC2016 # a jq filter, not shell
    update 'reduce (inputs | capture("^(?<id>.*)@(?<at>[^@]*)$")) as $a ($acks; .[$a.id] = $a.at)' "$@"
    echo "$prog: recorded $# thread(s) as done in $ack_file" >&2
    ;;
esac
