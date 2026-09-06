#!/bin/sh

set -eu

repository="cole-brokamp/rdh"
install_dir="${RDH_INSTALL_DIR:-$HOME/.local/bin}"
requested_version=""
pull_mode="ask"

usage() {
  printf '%s\n' \
    'Install a released rdh CLI binary.' \
    '' \
    'Usage: install.sh [--version VERSION] [--install-dir DIRECTORY] [--pull|--no-pull]' \
    '' \
    'Options:' \
    '  --version VERSION       Install a specific release.' \
    '  --install-dir DIRECTORY Choose the executable destination.' \
    '  --pull                  Pull the linked image after installation.' \
    '  --no-pull               Do not offer to pull the linked image.' \
    '' \
    'Environment:' \
    '  RDH_INSTALL_DIR       Default installation directory.' \
    '  RDH_RELEASE_BASE_URL  Override the release download URL.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || { printf '%s\n' 'missing value after --version' >&2; exit 2; }
      requested_version="$2"
      shift 2
      ;;
    --install-dir)
      [ "$#" -ge 2 ] || { printf '%s\n' 'missing value after --install-dir' >&2; exit 2; }
      install_dir="$2"
      shift 2
      ;;
    --pull)
      pull_mode="yes"
      shift
      ;;
    --no-pull)
      pull_mode="no"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$(uname -s)" in
  Darwin) operating_system="apple-darwin" ;;
  Linux) operating_system="unknown-linux-musl" ;;
  *) printf 'unsupported operating system: %s\n' "$(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  arm64|aarch64) architecture="aarch64" ;;
  x86_64|amd64) architecture="x86_64" ;;
  *) printf 'unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

target="${architecture}-${operating_system}"
archive="rdh-${target}.tar.gz"

if [ -n "${RDH_RELEASE_BASE_URL:-}" ]; then
  base_url="$RDH_RELEASE_BASE_URL"
elif [ -n "$requested_version" ]; then
  base_url="https://github.com/${repository}/releases/download/v${requested_version}"
else
  base_url="https://github.com/${repository}/releases/latest/download"
fi

temporary_dir="$(mktemp -d 2>/dev/null || mktemp -d -t rdh)"
cleanup() {
  rm -rf -- "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

download() {
  source_url="$1"
  destination="$2"
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --silent --show-error "$source_url" --output "$destination"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$source_url" -O "$destination"
  else
    printf '%s\n' 'curl or wget is required to download rdh' >&2
    exit 1
  fi
}

download "$base_url/$archive" "$temporary_dir/$archive"
download "$base_url/SHA256SUMS" "$temporary_dir/SHA256SUMS"

expected="$(awk -v archive="$archive" '$2 == archive { print $1 }' "$temporary_dir/SHA256SUMS")"
[ -n "$expected" ] || { printf 'no checksum found for %s\n' "$archive" >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$temporary_dir/$archive" | awk '{ print $1 }')"
elif command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "$temporary_dir/$archive" | awk '{ print $1 }')"
else
  printf '%s\n' 'sha256sum or shasum is required to verify rdh' >&2
  exit 1
fi

[ "$actual" = "$expected" ] || { printf 'checksum verification failed for %s\n' "$archive" >&2; exit 1; }

tar -xzf "$temporary_dir/$archive" -C "$temporary_dir"
[ -x "$temporary_dir/rdh" ] || { printf '%s\n' 'release archive does not contain rdh' >&2; exit 1; }
install -d "$install_dir"
install -m 0755 "$temporary_dir/rdh" "$install_dir/rdh"

printf 'installed %s\n' "$install_dir/rdh"
"$install_dir/rdh" version

pull_image() {
  "$install_dir/rdh" pull
}

print_pull_hint() {
  printf 'run %s pull to download the container image before first use\n' "$install_dir/rdh"
}

case "$pull_mode" in
  yes)
    pull_image
    ;;
  no)
    print_pull_hint
    ;;
  ask)
    response=""
    if [ -t 1 ] && [ -c /dev/tty ]; then
      printf 'Pull the container image now? This can take several minutes. [y/N] ' > /dev/tty
      if IFS= read -r response < /dev/tty; then
        case "$response" in
          y|Y|yes|Yes|YES)
            pull_image
            exit 0
            ;;
        esac
      fi
    fi
    print_pull_hint
    ;;
esac
