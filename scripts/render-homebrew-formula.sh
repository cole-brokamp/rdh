#!/usr/bin/env bash

set -euo pipefail

[[ "$#" == 2 ]] || {
  echo "usage: $0 DIST-DIRECTORY OUTPUT-FORMULA" >&2
  exit 2
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
dist_dir="$1"
output="$2"
version="$(tr -d '\r\n' < "$repo_dir/VERSION")"
[[ ! "$version" =~ -dev$ ]] || { echo "cannot render a formula for a development version" >&2; exit 1; }

checksum() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{ print $1 }'
  else
    shasum -a 256 "$path" | awk '{ print $1 }'
  fi
}

macos_arm_sha="$(checksum "$dist_dir/rdh-aarch64-apple-darwin.tar.gz")"
macos_intel_sha="$(checksum "$dist_dir/rdh-x86_64-apple-darwin.tar.gz")"
linux_arm_sha="$(checksum "$dist_dir/rdh-aarch64-unknown-linux-musl.tar.gz")"
linux_intel_sha="$(checksum "$dist_dir/rdh-x86_64-unknown-linux-musl.tar.gz")"

mkdir -p "$(dirname "$output")"
sed \
  -e "s/@VERSION@/$version/g" \
  -e "s/@MACOS_ARM_SHA256@/$macos_arm_sha/g" \
  -e "s/@MACOS_INTEL_SHA256@/$macos_intel_sha/g" \
  -e "s/@LINUX_ARM_SHA256@/$linux_arm_sha/g" \
  -e "s/@LINUX_INTEL_SHA256@/$linux_intel_sha/g" \
  "$repo_dir/packaging/homebrew/rdh.rb.in" > "$output"
