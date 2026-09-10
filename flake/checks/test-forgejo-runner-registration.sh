#!/usr/bin/env bash
set -euo pipefail

helper=${1:?registration helper required}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

token=dummyRegistrationToken123
instance=https://forge.example
name=fixture-runner
labels=fixture:docker://fixture,other:host
config=$tmp/config.yaml
runner_file=$tmp/.runner
labels_file=$tmp/.labels
name_file=$tmp/.runner-name
args_file=$tmp/args
stdin_file=$tmp/stdin
called_file=$tmp/called
bash_path=$(command -v bash)
clean_path=$(dirname "$bash_path"):$(dirname "$(command -v env)"):$(dirname "$(command -v grep)")

run_helper() {
  env -i PATH="$clean_path" HOME="$tmp" "$helper" "$@"
}

printf 'fixture\n' > "$config"
printf '%s\n\n' "$token" > "$tmp/token"

cat > "$tmp/mock-runner" <<EOF
#!$bash_path
set -euo pipefail
printf '%s\n' "\$@" > "$args_file"
cat > "$stdin_file"
touch "$runner_file" "$called_file"
if env | grep -Fq '$token'; then
  echo 'registration token leaked through the environment' >&2
  exit 1
fi
EOF
chmod +x "$tmp/mock-runner"

(
  cd "$tmp"
  run_helper "$tmp/mock-runner" "$config" "$runner_file" "$labels_file" "$name_file" \
    "$instance" "$name" "$labels" < "$tmp/token"
)

printf '%s\n' register --config "$config" > "$tmp/args.expected"
printf '%s\n%s\n%s\n%s\n' "$instance" "$token" "$name" "$labels" > "$tmp/stdin.expected"
cmp "$tmp/args.expected" "$args_file"
cmp "$tmp/stdin.expected" "$stdin_file"
if grep -Fq -- "$token" "$args_file" || grep -Fxq -- '--token' "$args_file"; then
  echo 'registration token leaked through runner arguments' >&2
  exit 1
fi
test "$(cat "$labels_file")" = "$labels"
test "$(cat "$name_file")" = "$name"

rm -f "$called_file"
run_helper "$tmp/mock-runner" "$config" "$runner_file" "$labels_file" "$name_file" \
  "$instance" "$name" "$labels" < "$tmp/token"
test ! -e "$called_file"

printf '%s\n' old-label > "$labels_file"
printf '%s\n' old-name > "$name_file"
cat > "$tmp/failing-runner" <<EOF
#!$bash_path
cat >/dev/null
exit 23
EOF
chmod +x "$tmp/failing-runner"

set +e
run_helper "$tmp/failing-runner" "$config" "$runner_file" "$labels_file" "$name_file" \
  "$instance" "$name" "$labels" < "$tmp/token"
status=$?
set -e
if [ "$status" -ne 23 ]; then
  echo "registration helper returned $status instead of runner status 23" >&2
  exit 1
fi
test "$(cat "$labels_file")" = old-label
test "$(cat "$name_file")" = old-name

touch "$runner_file"
rm -f "$called_file"
if run_helper "$tmp/mock-runner" "$config" "$runner_file" "$labels_file" "$name_file" \
  "$instance" $'invalid\nname' "$labels" < "$tmp/token"; then
  echo 'registration helper accepted a multiline setting' >&2
  exit 1
fi
test -e "$runner_file"
test ! -e "$called_file"
test "$(cat "$labels_file")" = old-label
test "$(cat "$name_file")" = old-name

if run_helper "$tmp/mock-runner" "$config" "$runner_file" "$labels_file" "$name_file" \
  "$instance" "$name" "" < "$tmp/token"; then
  echo 'registration helper accepted an empty setting' >&2
  exit 1
fi
test -e "$runner_file"
test ! -e "$called_file"
test "$(cat "$labels_file")" = old-label
test "$(cat "$name_file")" = old-name
