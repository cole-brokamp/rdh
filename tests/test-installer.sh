#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
binary="${1:-$repo_dir/target/debug/rdh}"
[[ "$binary" = /* ]] || binary="$repo_dir/$binary"
[[ -x "$binary" ]] || { echo "Rust CLI is not executable: $binary" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) operating_system="apple-darwin" ;;
  Linux) operating_system="unknown-linux-musl" ;;
  *) echo "unsupported test operating system" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) architecture="aarch64" ;;
  x86_64|amd64) architecture="x86_64" ;;
  *) echo "unsupported test architecture" >&2; exit 1 ;;
esac

target="${architecture}-${operating_system}"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT HUP INT TERM
release_dir="$test_root/release"
install_dir="$test_root/bin"
pull_install_dir="$test_root/pull-bin"
fake_bin="$test_root/fake-bin"
pull_log="$test_root/pull.log"
mkdir -p "$release_dir"
mkdir -p "$fake_bin"

"$repo_dir/scripts/package-release.sh" "$binary" "$target" "$release_dir"
archive="rdh-$target.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then
  hash="$(sha256sum "$release_dir/$archive" | awk '{ print $1 }')"
else
  hash="$(shasum -a 256 "$release_dir/$archive" | awk '{ print $1 }')"
fi
printf '%s  %s\n' "$hash" "$archive" > "$release_dir/SHA256SUMS"

RDH_RELEASE_BASE_URL="file://$release_dir" \
  sh "$repo_dir/install.sh" --install-dir "$install_dir" >/dev/null

[[ -x "$install_dir/rdh" ]]
"$install_dir/rdh" version | rg -Fq "rdh $(tr -d '\r\n' < "$repo_dir/VERSION")"

cat > "$fake_bin/container" <<'FAKE_CONTAINER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "image" && "${2:-}" == "pull" ]]; then
  printf 'container-pull\n' > "$RDH_TEST_PULL_LOG"
fi
FAKE_CONTAINER
chmod +x "$fake_bin/container"

PATH="$fake_bin:$PATH" \
  RDH_TEST_PULL_LOG="$pull_log" \
  RDH_IMAGE="docker://example.invalid/rdh:test" \
  RDH_RUNTIME="container" \
  RDH_RELEASE_BASE_URL="file://$release_dir" \
  sh "$repo_dir/install.sh" --install-dir "$pull_install_dir" --pull >/dev/null

[[ -x "$pull_install_dir/rdh" ]]
rg -Fxq 'container-pull' "$pull_log"
echo "installer checks passed"
