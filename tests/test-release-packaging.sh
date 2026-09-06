#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
binary="${1:-$repo_dir/target/debug/rdh}"
[[ "$binary" = /* ]] || binary="$repo_dir/$binary"
[[ -x "$binary" ]] || { echo "Rust CLI is not executable: $binary" >&2; exit 1; }

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT HUP INT TERM
fixture_repo="$test_root/repository"
dist_dir="$test_root/dist"
mkdir -p "$fixture_repo/scripts" "$fixture_repo/packaging/homebrew" "$dist_dir"
cp "$repo_dir/scripts/render-homebrew-formula.sh" "$fixture_repo/scripts/"
cp "$repo_dir/packaging/homebrew/rdh.rb.in" "$fixture_repo/packaging/homebrew/"
release_version="$(sed 's/-dev$//' "$repo_dir/VERSION")"
printf '%s\n' "$release_version" > "$fixture_repo/VERSION"

for target in \
  aarch64-apple-darwin \
  x86_64-apple-darwin \
  aarch64-unknown-linux-musl \
  x86_64-unknown-linux-musl; do
  "$repo_dir/scripts/package-release.sh" "$binary" "$target" "$dist_dir"
done

"$fixture_repo/scripts/render-homebrew-formula.sh" "$dist_dir" "$dist_dir/rdh.rb"
ruby -c "$dist_dir/rdh.rb" >/dev/null
if rg -q '@[A-Z0-9_]+@' "$dist_dir/rdh.rb"; then
  echo "the rendered Homebrew formula contains an unresolved placeholder" >&2
  exit 1
fi

rg -Fq "version \"$(cat "$fixture_repo/VERSION")\"" "$dist_dir/rdh.rb"
for archive in "$dist_dir"/*.tar.gz; do
  tar -tzf "$archive" | rg -Fxq rdh
done

printf '%s-dev\n' "$release_version" > "$fixture_repo/VERSION"
if "$fixture_repo/scripts/render-homebrew-formula.sh" "$dist_dir" "$dist_dir/dev.rb" >/dev/null 2>&1; then
  echo "a Homebrew formula was unexpectedly rendered for a development version" >&2
  exit 1
fi

echo "release packaging checks passed"
