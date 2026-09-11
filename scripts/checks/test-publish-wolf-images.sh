#!/usr/bin/env bash
set -euo pipefail

publisher=${1:-scripts/ci/publish-wolf-images.sh}
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/wolf-context" "$test_root/helium-context"

cat >"$test_root/manifest.json" <<EOF
{
  "schemaVersion": 1,
  "products": [
    {
      "name": "wolf",
      "context": "$test_root/wolf-context",
      "buildArgs": {"RUNTIME_IMAGE": "upstream.example/wolf@sha256:base"},
      "labels": {}
    },
    {
      "name": "helium",
      "context": "$test_root/helium-context",
      "buildArgs": {"BASE_APP_IMAGE": "upstream.example/base@sha256:base", "IMAGE_VERSION": "1.2.3"},
      "labels": {"org.nixbox.wolf-browser": "true"}
    }
  ]
}
EOF

printf '#!%s\n' "$BASH" >"$test_root/bin/docker"
cat >>"$test_root/bin/docker" <<'EOF'
set -euo pipefail
printf '%s\n' "$*" >>"$DOCKER_CALLS"
case "$1 ${2:-}" in
  "image inspect") printf 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
  "push "*)
    if [[ ${MOCK_FAIL_FIRST_PUSH:-0} == 1 && ! -e $MOCK_PUSH_FAILED ]]; then
      touch "$MOCK_PUSH_FAILED"
      exit 1
    fi
    printf 'pushed\ndigest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa size: 1234\n'
    ;;
  "manifest inspect")
    printf '{"Descriptor":{"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"SchemaV2Manifest":{"config":{"digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}}\n'
    ;;
esac
EOF
chmod +x "$test_root/bin/docker"

revision=0123456789abcdef0123456789abcdef01234567
export DOCKER_CALLS="$test_root/docker.calls"
export PATH="$test_root/bin:$PATH"
export WOLF_PUBLISH_TIMESTAMP=20260911t120000z
export WOLF_PUSH_RETRY_DELAY_SECONDS=0
export WOLF_REGISTRY_PREFIX=registry.example/owner

bash "$publisher" "$test_root/manifest.json" dev "$revision" "$test_root/local.json"
jq -e '
  .published == false
  and .complete == true
  and .channel == "dev"
  and .revision == "0123456789abcdef0123456789abcdef01234567"
  and (.products | length == 2)
  and .products[0].name == "wolf"
  and .products[1].name == "helium"
' "$test_root/local.json" >/dev/null
rg --fixed-strings --quiet -- '--build-arg RUNTIME_IMAGE=upstream.example/wolf@sha256:base' "$DOCKER_CALLS"
rg --fixed-strings --quiet -- '--label org.nixbox.wolf-browser=true' "$DOCKER_CALLS"
if rg --fixed-strings --quiet 'push ' "$DOCKER_CALLS"; then
  echo "non-publishing build attempted a registry push" >&2
  exit 1
fi

: >"$DOCKER_CALLS"
export MOCK_FAIL_FIRST_PUSH=1
export MOCK_PUSH_FAILED="$test_root/push.failed"
bash "$publisher" --push "$test_root/manifest.json" main "$revision" "$test_root/published.json"
jq -e '
  .published == true
  and .complete == true
  and .channel == "main"
  and (.products | length == 2)
  and .products[0].imageId == "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  and .products[0].reference == "registry.example/owner/wolf:main-20260911t120000z-0123456789ab@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  and .products[1].reference == "registry.example/owner/wolf-helium:main-20260911t120000z-0123456789ab@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
' "$test_root/published.json" >/dev/null
rg --fixed-strings --quiet 'manifest inspect registry.example/owner/wolf:main-20260911t120000z-0123456789ab@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$DOCKER_CALLS"
[[ $(rg --count '^push ' "$DOCKER_CALLS") == 3 ]]

if bash "$publisher" "$test_root/manifest.json" feature "$revision" "$test_root/invalid.json" >/dev/null 2>&1; then
  echo "publisher accepted a non-release channel" >&2
  exit 1
fi
if bash "$publisher" "$test_root/manifest.json" dev deadbeef "$test_root/invalid.json" >/dev/null 2>&1; then
  echo "publisher accepted an abbreviated revision" >&2
  exit 1
fi
