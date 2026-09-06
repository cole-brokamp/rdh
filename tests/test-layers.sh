#!/usr/bin/env bash

set -euo pipefail

image="${1:-rdh:local}"
case "$(uname -m)" in
  arm64|aarch64) native_platform="linux/arm64" ;;
  x86_64|amd64) native_platform="linux/amd64" ;;
  *) echo "unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
esac
platform="${RDH_PLATFORM:-$native_platform}"
architecture="${platform#linux/}"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT HUP INT TERM

archive="$test_root/image.tar"
archive_dir="$test_root/oci"
mkdir -p "$archive_dir"

container image save \
  --platform "$platform" \
  --output "$archive" \
  "$image" >/dev/null
tar -xf "$archive" -C "$archive_dir"

blob_path() {
  printf '%s/blobs/sha256/%s\n' "$archive_dir" "${1#sha256:}"
}

root_digest="$(jq -r '.manifests[0].digest' "$archive_dir/index.json")"
root_descriptor="$(blob_path "$root_digest")"
root_media_type="$(jq -r '.mediaType' "$root_descriptor")"

case "$root_media_type" in
  application/vnd.oci.image.index.v1+json)
    manifest_digest="$(
      jq -r --arg architecture "$architecture" '
        .manifests[] |
        select(.platform.os == "linux" and .platform.architecture == $architecture) |
        .digest
      ' "$root_descriptor"
    )"
    ;;
  application/vnd.oci.image.manifest.v1+json)
    manifest_digest="$root_digest"
    ;;
  *)
    echo "unsupported OCI root media type: $root_media_type" >&2
    exit 1
    ;;
esac

[[ -n "$manifest_digest" ]] || {
  echo "no $platform manifest found" >&2
  exit 1
}

manifest="$(blob_path "$manifest_digest")"
config_digest="$(jq -r '.config.digest' "$manifest")"
config="$(blob_path "$config_digest")"

credential_pattern='renviron-(host|user|password)|export-(host|user|password)|host-secret|user-secret|password-secret|test-password|omop-(host|user|password)-secret|(MBHI|OMOP)_DB_(HOST|NAME|USERNAME|PASSWORD)=[^[:space:]]+'

while IFS= read -r digest; do
  layer="$(blob_path "$digest")"
  layer_names="$test_root/layer-names"

  tar -tzf "$layer" > "$layer_names"
  if rg -q '(^|/)[.]Renviron$' "$layer_names"; then
    echo "a .Renviron file exists in OCI layer $digest" >&2
    exit 1
  fi

  if gzip -cd "$layer" | LC_ALL=C grep -aE "$credential_pattern" > /dev/null; then
    echo "a credential-like test value exists in OCI layer $digest" >&2
    exit 1
  fi
done < <(jq -r '.layers[].digest' "$manifest")

if rg -a -q "$credential_pattern" \
  "$archive_dir/index.json" \
  "$root_descriptor" \
  "$manifest" \
  "$config"; then
  echo "a credential-like test value exists in OCI metadata" >&2
  exit 1
fi

echo "OCI layer checks passed"
