#!/usr/bin/env bash

set -euo pipefail

[[ "$#" == 3 ]] || {
  echo "usage: $0 BINARY TARGET DIST-DIRECTORY" >&2
  exit 2
}

binary="$1"
target="$2"
dist_dir="$3"
[[ -x "$binary" ]] || { echo "binary is not executable: $binary" >&2; exit 1; }
[[ "$target" =~ ^(aarch64|x86_64)-(apple-darwin|unknown-linux-musl)$ ]] || {
  echo "unsupported release target: $target" >&2
  exit 1
}

mkdir -p "$dist_dir"
temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "$temporary_dir"' EXIT HUP INT TERM
install -m 0755 "$binary" "$temporary_dir/rdh"
tar -czf "$dist_dir/rdh-$target.tar.gz" -C "$temporary_dir" rdh
