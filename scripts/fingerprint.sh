#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:?usage: fingerprint.sh <target>}"
config="$root/targets.json"

entry="$(jq -cS --arg t "$target" '.targets[$t] // empty' "$config")"
if [ -z "$entry" ]; then
  echo "unknown target: $target (known: $(jq -r '.targets | keys | join(", ")' "$config"))" >&2
  exit 1
fi
field() { jq -r --arg f "$1" '.[$f] // empty' <<<"$entry"; }

manifest="$(mktemp)"
work=""
trap 'rm -rf "$manifest" "$work"' EXIT

recipe="$(jq -cS '{kind, repo, ref, dockerfile, local_dockerfile, inputs, cargo_closure, recipe, source_image}
                  | with_entries(select(.value != null))' <<<"$entry")"
printf 'recipe %s\n' "$recipe" >>"$manifest"

case "$(field kind)" in
  build)
    repo="${FINGERPRINT_REPO:-$(field repo)}"
    ref="$(field ref)"
    if [ -n "${FINGERPRINT_REV:-}" ]; then
      ref="$FINGERPRINT_REV"
      fetch="$FINGERPRINT_REV"
    elif [ "$ref" = semver-tag ]; then
      tags="$(git ls-remote --tags --refs "$repo")"
      ref="$(awk '{sub("refs/tags/", "", $2); print $2}' <<<"$tags" \
               | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
               | sort -V | tail -1 || true)"
      if [ -z "$ref" ]; then
        echo "no vX.Y.Z tags at $repo" >&2
        exit 1
      fi
      fetch="refs/tags/$ref"
    else
      fetch="refs/heads/$ref"
    fi

    work="$(mktemp -d)"
    git init --quiet "$work"
    git -C "$work" fetch --quiet --filter=blob:none --depth 1 "$repo" "$fetch"
    upstream="$(git -C "$work" rev-parse 'FETCH_HEAD^{commit}')"
    git -C "$work" update-ref HEAD "$upstream"

    local_dockerfile="$(field local_dockerfile)"
    if [ -n "$local_dockerfile" ]; then
      dockerfile_hash="$(sha256sum "$root/$local_dockerfile")"
      printf 'dockerfile %s\n' "${dockerfile_hash%% *}" >>"$manifest"
    fi

    inputs=()
    while IFS= read -r p; do inputs+=("$p"); done < <(jq -r '.inputs[]' <<<"$entry")

    crate="$(field cargo_closure)"
    if [ -n "$crate" ]; then
      git -C "$work" sparse-checkout set --no-cone '/Cargo.toml' '/Cargo.lock' '/**/Cargo.toml' >/dev/null
      git -C "$work" checkout --quiet

      closure="$(node "$root/scripts/cargo-closure.mjs" "$work" "$crate")"
      if [ -z "$closure" ]; then
        echo "empty crate closure for $crate" >&2
        exit 1
      fi
      while IFS= read -r p; do inputs+=("$p"); done <<<"$closure"

      lock="$(node "$root/scripts/cargo-closure.mjs" "$work" "$crate" --lock)"
      lock_hash="$(sha256sum <<<"$lock")"
      printf 'lock %s\n' "${lock_hash%% *}" >>"$manifest"
    fi

    while IFS= read -r p; do
      [ -n "$p" ] || continue
      tree="$(git -C "$work" rev-parse --verify --quiet "HEAD:$p" || echo absent)"
      printf 'input %s %s\n' "$p" "$tree" >>"$manifest"
    done < <(printf '%s\n' "${inputs[@]}" | sort -u)
    ;;
  mirror)
    raw_manifest="$(docker buildx imagetools inspect --raw "$(field source_image)")"
    digest="$(printf '%s' "$raw_manifest" | sha256sum)"
    upstream="sha256:${digest%% *}"
    ref=""
    fetch=""
    printf 'digest %s\n' "$upstream" >>"$manifest"
    ;;
  *)
    echo "target $target has unknown kind: $(field kind)" >&2
    exit 1
    ;;
esac

if [ "${FINGERPRINT_DEBUG:-}" = 1 ]; then cat "$manifest" >&2; fi
fingerprint="$(sha256sum "$manifest")"
echo "fingerprint=${fingerprint:0:16}"
echo "upstream=$upstream"
echo "ref=$ref"
echo "fetch=$fetch"
