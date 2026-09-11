#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: publish-wolf-images.sh [--push] MANIFEST CHANNEL REVISION OUTPUT" >&2
  exit 2
}

push=0
if [[ ${1:-} == --push ]]; then
  push=1
  shift
fi
[[ $# == 4 ]] || usage

manifest=$1
channel=$2
revision=$3
output=$4
registry_prefix=${WOLF_REGISTRY_PREFIX:-git.alc.xyz/alcxyz}
timestamp=${WOLF_PUBLISH_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ | tr '[:upper:]' '[:lower:]')}
retry_delay=${WOLF_PUSH_RETRY_DELAY_SECONDS:-5}

[[ -f $manifest ]] || {
  echo "Wolf image manifest does not exist: $manifest" >&2
  exit 1
}
[[ $channel == dev || $channel == main ]] || {
  echo "Wolf image channel must be dev or main" >&2
  exit 1
}
[[ $revision =~ ^[0-9a-f]{40}$ ]] || {
  echo "Wolf image revision must be a full lowercase Git commit" >&2
  exit 1
}
[[ $timestamp =~ ^[0-9]{8}t[0-9]{6}z$ ]] || {
  echo "Wolf image timestamp must use YYYYMMDDtHHMMSSz" >&2
  exit 1
}
[[ $retry_delay =~ ^[0-9]+$ ]] || {
  echo "Wolf image push retry delay must be a nonnegative integer" >&2
  exit 1
}
jq -e '.schemaVersion == 1 and (.products | type == "array" and length > 0)' "$manifest" >/dev/null

result_lines=$(mktemp)
manifest_check=$(mktemp)
push_log=$(mktemp)
trap 'rm -f "$result_lines" "$manifest_check" "$push_log"' EXIT
short_revision=${revision:0:12}

write_output() {
  complete=$1
  jq -s \
    --argjson published "$push" \
    --argjson complete "$complete" \
    --arg channel "$channel" \
    --arg revision "$revision" \
    --arg timestamp "$timestamp" \
    '{schemaVersion: 1, published: ($published == 1), complete: ($complete == 1), channel: $channel, revision: $revision, timestamp: $timestamp, products: .}' \
    "$result_lines" >"$output"
}

push_with_retry() {
  ref=$1
  for attempt in 1 2 3; do
    : >"$push_log"
    if docker push "$ref" | tee "$push_log"; then
      return 0
    fi
    [[ $attempt == 3 ]] && return 1
    sleep $((attempt * retry_delay))
  done
}

write_output 0
while IFS= read -r product; do
  name=$(jq -r '.name' <<<"$product")
  context=$(jq -r '.context' <<<"$product")
  [[ $name =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || {
    echo "Invalid Wolf image product name: $name" >&2
    exit 1
  }
  [[ -d $context ]] || {
    echo "Wolf image context does not exist for $name: $context" >&2
    exit 1
  }

  image="${registry_prefix}/wolf"
  [[ $name == wolf ]] || image="${registry_prefix}/wolf-${name}"
  release_tag="${channel}-${timestamp}-${short_revision}"
  release_ref="${image}:${release_tag}"
  local_ref="localhost/nixbox-wolf-build/${name}:${revision}"
  build_options=(--pull=false --tag "$local_ref")
  while IFS= read -r argument; do
    build_options+=(--build-arg "$argument")
  done < <(jq -r '.buildArgs | to_entries[] | "\(.key)=\(.value)"' <<<"$product")
  while IFS= read -r label; do
    build_options+=(--label "$label")
  done < <(jq -r '.labels | to_entries[] | "\(.key)=\(.value)"' <<<"$product")

  docker build "${build_options[@]}" "$context"
  image_id=$(docker image inspect --format '{{.Id}}' "$local_ref")
  [[ $image_id =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "Docker did not report a content-addressed image ID for $name" >&2
    exit 1
  }

  if ((push)); then
    docker tag "$local_ref" "$release_ref"
    push_with_retry "$release_ref"
    digest=$(sed -n 's/^.*digest: \(sha256:[0-9a-f]\{64\}\).*$/\1/p' "$push_log" | tail -n1)
    [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || {
      echo "Registry did not report a digest for $release_ref" >&2
      exit 1
    }
    docker manifest inspect --verbose "$release_ref" >"$manifest_check"
    jq -e \
      --arg digest "$digest" \
      --arg image_id "$image_id" \
      '.Descriptor.digest == $digest and .SchemaV2Manifest.config.digest == $image_id' \
      "$manifest_check" >/dev/null || {
      echo "Registry manifest does not match the pushed $name image" >&2
      exit 1
    }
    docker manifest inspect "${release_ref}@${digest}" >/dev/null
    jq -cn \
      --arg name "$name" \
      --arg image "$image" \
      --arg tag "$release_tag" \
      --arg digest "$digest" \
      --arg imageId "$image_id" \
      --arg reference "${release_ref}@${digest}" \
      '{name: $name, image: $image, tag: $tag, digest: $digest, imageId: $imageId, reference: $reference}' \
      >>"$result_lines"
  else
    jq -cn \
      --arg name "$name" \
      --arg imageId "$image_id" \
      '{name: $name, imageId: $imageId}' \
      >>"$result_lines"
  fi
  write_output 0
done < <(jq -c '.products[]' "$manifest")

write_output 1
