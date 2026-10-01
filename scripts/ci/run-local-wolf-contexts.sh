#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --pack-context ]]; then
  [[ $# == 3 ]] || exit 2
  tar --zstd --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    --hard-dereference -cf "$3" -C "$2" context manifest.json
  exit
fi

# Succeeds when two product manifests describe identical image inputs: every
# product field (context, build arguments, labels), independent of order.
same_products() {
  local new old
  new=$(jq -cS '[.products[]] | sort_by(.name)' "$1") || return 2
  [[ -f $2 ]] || return 1
  old=$(jq -cS '[.products[]] | sort_by(.name)' "$2") || return 1
  [[ -n $new && $new == "$old" ]]
}

if [[ ${1:-} == --same-products ]]; then
  [[ $# == 3 ]] || exit 2
  same_products "$2" "$3"
  exit
fi

for variable in CONFIG_REMOTE CONFIG_BRANCH FORGEJO_URL FORGEJO_OWNER FORGEJO_REPO \
  FORGEJO_API_TOKEN_FILE DOCKER_CONFIG_FILE WOLF_CONTEXT_STATE_DIRECTORY; do
  [[ -n ${!variable:-} ]] || {
    echo "${variable} is required" >&2
    exit 2
  }
done
[[ $CONFIG_BRANCH == dev ]] || {
  echo 'Only committed dev is enabled for native Wolf builds.' >&2
  exit 2
}

work=$(mktemp -d)
cleanup() {
  if [[ -d $work/stage ]]; then
    chmod -R u+w -- "$work/stage" || true
  fi
  rm -rf -- "$work"
}
trap cleanup EXIT
exec 9>"${XDG_RUNTIME_DIR:-$work}/nix-package-promotion.lock"
if ! flock -n 9; then
  echo 'Another local native build is running.'
  exit 0
fi

checkout="$work/nix-config"
git init --quiet "$checkout"
git -C "$checkout" remote add origin "$CONFIG_REMOTE"
git -C "$checkout" fetch --quiet --no-tags origin "refs/heads/$CONFIG_BRANCH"
revision=$(git -C "$checkout" rev-parse FETCH_HEAD)
git -C "$checkout" switch --quiet --detach "$revision"
[[ $revision =~ ^[0-9a-f]{40}$ ]] || exit 1

remote_head() {
  git ls-remote "$CONFIG_REMOTE" "refs/heads/$CONFIG_BRANCH" | awk 'NR == 1 {print $1}'
}
[[ $(remote_head) == "$revision" ]] || {
  echo 'Wolf source advanced; deferring.' >&2
  exit 75
}

mkdir -p "$WOLF_CONTEXT_STATE_DIRECTORY"
checkpoint="$WOLF_CONTEXT_STATE_DIRECTORY/$CONFIG_BRANCH.revision"
if [[ -f $checkpoint ]]; then
  previous=$(<"$checkpoint")
  if [[ $previous =~ ^[0-9a-f]{40}$ ]] && git -C "$checkout" cat-file -e "$previous^{commit}"; then
    git -C "$checkout" diff --name-only "$previous" "$revision" >"$work/changed"
    if ! rg -q '^(\.forgejo/workflows/publish-wolf-images\.yml|flake\.lock|flake/per-system\.nix|modules/nixos/services/wolf-streaming/(browser-image|wolf-image)/.+|modules/nixos/services/wolf-streaming/(image-products|images)\.nix|scripts/ci/(publish-wolf-images|wolf-context-package|run-local-wolf-contexts)\.(sh|py))$' "$work/changed"; then
      python3 "$checkout/scripts/ci/wolf-context-package.py" prune \
        --url "$FORGEJO_URL" --owner "$FORGEJO_OWNER" --channel "$CONFIG_BRANCH" \
        --sha "$revision" --docker-config "$DOCKER_CONFIG_FILE"
      echo 'Wolf image inputs have not changed.'
      exit 0
    fi
  fi
fi

package=(--url "$FORGEJO_URL" --owner "$FORGEJO_OWNER" --channel "$CONFIG_BRANCH"
  --sha "$revision" --docker-config "$DOCKER_CONFIG_FILE")
client="$checkout/scripts/ci/wolf-context-package.py"
state=$(python3 "$client" exists "${package[@]}")
if [[ $state == missing ]]; then
  (cd "$checkout" && nix build --no-update-lock-file --out-link "$work/product" .#wolf-deployed-image-products)
  [[ -z $(git -C "$checkout" status --porcelain) ]] || {
    echo 'Wolf build changed the committed tree.' >&2
    exit 1
  }
  manifest="$work/product/manifest.json"
  jq -e '.schemaVersion == 1 and ([.products[].name] | sort) == ["brave","helium","wolf","zen"]' "$manifest" >/dev/null

  # flake.lock bumps (for example unrelated nix-packages updates) usually leave
  # every image input unchanged. Skip when the products match the last
  # successfully dispatched set and the publish recipe itself did not change.
  dispatched="$WOLF_CONTEXT_STATE_DIRECTORY/$CONFIG_BRANCH.dispatched.json"
  # A search error counts as a recipe change, so the run publishes.
  recipe_changed=yes
  if [[ -f $work/changed ]]; then
    if rg -q '^(\.forgejo/workflows/publish-wolf-images\.yml|scripts/ci/(publish-wolf-images|wolf-context-package|run-local-wolf-contexts)\.(sh|py))$' "$work/changed"; then
      recipe_changed=yes
    elif [[ $? == 1 ]]; then
      recipe_changed=no
    fi
  fi
  if [[ $recipe_changed == no ]] && same_products "$manifest" "$dispatched"; then
    [[ $(remote_head) == "$revision" ]] || {
      echo 'Wolf source advanced during build; deferring.' >&2
      exit 75
    }
    echo 'Wolf image inputs match the last dispatched products; recording the revision without publishing.'
    printf '%s\n' "$revision" >"$checkpoint.new"
    mv -f -- "$checkpoint.new" "$checkpoint"
    exit 0
  fi

  mkdir "$work/archives"
  products='{}'
  for name in wolf helium brave zen; do
    context=$(jq -er --arg name "$name" '.products[] | select(.name == $name) | .context' "$manifest")
    [[ $context == /nix/store/* && -d $context ]] || {
      echo "Invalid Nix context for $name" >&2
      exit 1
    }
    mkdir "$work/stage"
    cp -a --reflink=auto -- "$context" "$work/stage/context"
    if [[ -n $(fd -H -I -t l . "$work/stage/context") ]]; then
      echo "Wolf context contains a link: $name" >&2
      exit 1
    fi
    jq --arg name "$name" --arg channel "$CONFIG_BRANCH" --arg revision "$revision" \
      '{schemaVersion, channel: $channel, revision: $revision, products: [.products[] | select(.name == $name) | .context = "context"]}' \
      "$manifest" >"$work/stage/manifest.json"
    bash "$checkout/scripts/ci/run-local-wolf-contexts.sh" --pack-context \
      "$work/stage" "$work/archives/$name.tar.zst"
    chmod -R u+w -- "$work/stage"
    rm -rf -- "$work/stage"
    hash=$(sha256sum "$work/archives/$name.tar.zst" | cut -d' ' -f1)
    products=$(jq -cn --argjson old "$products" --arg name "$name" --arg hash "$hash" '$old + {($name): $hash}')
  done
  jq -n --arg channel "$CONFIG_BRANCH" --arg revision "$revision" --argjson products "$products" \
    '{schemaVersion: 1, channel: $channel, revision: $revision, products: $products}' \
    >"$work/archives/complete.json"

  [[ $(remote_head) == "$revision" ]] || {
    echo 'Wolf source advanced during build; deferring.' >&2
    exit 75
  }
  python3 "$client" upload "${package[@]}" --directory "$work/archives" --receipt "$work/archives/complete.json"
  # Bind the uploaded products to their revision for the dispatch record.
  jq --arg revision "$revision" '{revision: $revision, products}' "$manifest" \
    >"$WOLF_CONTEXT_STATE_DIRECTORY/$CONFIG_BRANCH.uploaded.json.new"
  mv -f -- "$WOLF_CONTEXT_STATE_DIRECTORY/$CONFIG_BRANCH.uploaded.json.new" \
    "$WOLF_CONTEXT_STATE_DIRECTORY/$CONFIG_BRANCH.uploaded.json"
  nix-store --realise "$(readlink -f "$work/product")" \
    --add-root "$WOLF_CONTEXT_STATE_DIRECTORY/$CONFIG_BRANCH" --indirect >/dev/null
fi

[[ $(remote_head) == "$revision" ]] || {
  echo 'Wolf source advanced before dispatch; deferring.' >&2
  exit 75
}
python3 "$client" dispatch --url "$FORGEJO_URL" --owner "$FORGEJO_OWNER" \
  --channel "$CONFIG_BRANCH" --sha "$revision" --repo "$FORGEJO_REPO" \
  --api-token-file "$FORGEJO_API_TOKEN_FILE"
# Record what was dispatched, but only when the uploaded products provably
# belong to this revision; otherwise drop the record so the next run publishes.
# A dispatch only starts CI: if that publish job fails, rerun it (or wait for
# the next real input change), since identical inputs are not re-dispatched.
uploaded="$WOLF_CONTEXT_STATE_DIRECTORY/$CONFIG_BRANCH.uploaded.json"
if [[ -f $uploaded && $(jq -r '.revision // empty' "$uploaded" 2>/dev/null) == "$revision" ]]; then
  jq '{products}' "$uploaded" >"$WOLF_CONTEXT_STATE_DIRECTORY/$CONFIG_BRANCH.dispatched.json.new"
  mv -f -- "$WOLF_CONTEXT_STATE_DIRECTORY/$CONFIG_BRANCH.dispatched.json.new" \
    "$WOLF_CONTEXT_STATE_DIRECTORY/$CONFIG_BRANCH.dispatched.json"
else
  rm -f -- "$WOLF_CONTEXT_STATE_DIRECTORY/$CONFIG_BRANCH.dispatched.json"
fi
printf '%s\n' "$revision" >"$checkpoint.new"
mv -f -- "$checkpoint.new" "$checkpoint"
python3 "$client" prune "${package[@]}"
